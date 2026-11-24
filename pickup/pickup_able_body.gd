class_name PickupAbleBody3D
extends RigidBody3D

var highlight_material : Material = preload("res://shaders/highlight_material.tres")
var picked_up_by : Area3D
var closest_areas : Array

var original_parent : Node3D
var tween : Tween


# Called when this object becomes the closest body in an area
func add_is_closest(area : Area3D) -> void:
	if not closest_areas.has(area):
		closest_areas.push_back(area)

	_update_highlight()


# Called when this object becomes the closest body in an area
func remove_is_closest(area : Area3D) -> void:
	if closest_areas.has(area):
		closest_areas.erase(area)

	_update_highlight()


# Returns whether we have been picked up.
func is_picked_up() -> bool:
	# If we have a valid picked up by object,
	# we've been picked up
	if picked_up_by:
		return true

	return false


# Pick this object up.
func pick_up(pick_up_by) -> void:
	# Already picked up? Can't pick up twice.
	if picked_up_by:
		if picked_up_by == pick_up_by:
			return

		let_go()

	# Remember some state we want to reapply on release.
	original_parent = get_parent()
	var current_transform = global_transform

	# Remove us from our old parent.
	original_parent.remove_child(self)

	# Process our pickup.
	picked_up_by = pick_up_by
	picked_up_by.add_child(self)
	global_transform = current_transform
	freeze = true

	# Kill any existing tween and create a new one.
	if tween:
		tween.kill()
	tween = create_tween()

	# Snap the object to this transform, expressed in the space of the
	# PickupHandler that picks it up. Because the object becomes a child of
	# the handler (itself a child of the XRController3D), it then follows the
	# position AND the orientation of the hand automatically.
	# By default (identity) the object's origin goes to the hand.
	var snap_to : Transform3D

	# If the object has a "GripPoint" marker (e.g. on a sword handle), we want
	# that point, with its orientation, to end up exactly in the hand.
	# Call G the marker's transform relative to the object. Once snapped we
	# want  object_transform * G = identity  (grip exactly on the hand), so
	# object_transform = G^-1.
	var grip : Node3D = get_node_or_null(^"GripPoint")
	if grip:
		var grip_in_body : Transform3D = global_transform.affine_inverse() * grip.global_transform

		# Fallback: align the grip with the controller pose. This depends on
		# how the XR runtime defines the palm/grip pose, which differs between
		# headsets (and sometimes between hands), so it's only a fallback.
		snap_to = grip_in_body.affine_inverse()

		# Preferred: build the grip from the real hand joints (hand tracking),
		# which is the same on every headset and for both hands.
		var hand_grip = _get_hand_grip_transform(pick_up_by)
		if hand_grip != null:
			# Where the whole object must be (world space) so that its grip
			# point matches hand_grip, then converted into the handler's space.
			var body_global : Transform3D = hand_grip * grip_in_body.affine_inverse()
			snap_to = pick_up_by.global_transform.affine_inverse() * body_global

	# Now tween
	tween.tween_property(self, ^"transform", snap_to, 0.1)


# Returns where a held grip should be (world space), computed from the hand
# tracking joints of the hand holding pick_up_by, or null if there is no hand
# tracking data. The returned transform follows the GripPoint convention:
#   -Z = direction the blade points: along the knuckles, from the little
#        finger towards the index (out of the thumb side of the fist)
#   +Y = direction the sharp edge faces: the way the knuckles point
#   origin = centre of the fist
func _get_hand_grip_transform(pick_up_by : Node3D):
	# Find the XRController3D above the handler, and the XROrigin3D above it.
	var node : Node = pick_up_by
	while node and not node is XRController3D:
		node = node.get_parent()
	if not node:
		return null
	var controller : XRController3D = node
	var origin := controller.get_parent() as Node3D
	if not origin:
		return null

	var tracker_name : StringName
	if controller.tracker == &"left_hand":
		tracker_name = &"/user/hand_tracker/left"
	elif controller.tracker == &"right_hand":
		tracker_name = &"/user/hand_tracker/right"
	else:
		return null

	var hand_tracker : XRHandTracker = XRServer.get_tracker(tracker_name)
	if not hand_tracker or not hand_tracker.has_tracking_data:
		return null

	var needed := [
		XRHandTracker.HAND_JOINT_WRIST, XRHandTracker.HAND_JOINT_PALM,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
	]
	# Joint positions are in XROrigin3D space: convert them to world space.
	var p := {}
	for joint in needed:
		if not (hand_tracker.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
			return null
		p[joint] = origin.global_transform * hand_tracker.get_hand_joint_transform(joint).origin

	# Blade direction: along the knuckles, little finger -> index.
	var blade : Vector3 = (p[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL] \
		- p[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]).normalized()

	# Edge direction: wrist -> knuckles, made perpendicular to the blade.
	var edge : Vector3 = p[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL] \
		- p[XRHandTracker.HAND_JOINT_WRIST]
	edge = (edge - blade * edge.dot(blade)).normalized()

	# Build an orthonormal, right-handed basis (x = y cross z).
	var z_axis : Vector3 = -blade
	var y_axis : Vector3 = edge
	var x_axis : Vector3 = y_axis.cross(z_axis).normalized()

	# Centre of the fist: between the palm and the curled fingers.
	var fingers : Vector3 = (p[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE] \
		+ p[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE] \
		+ p[XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE] \
		+ p[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE]) / 4.0
	var centre : Vector3 = (p[XRHandTracker.HAND_JOINT_PALM] + fingers) * 0.5

	return Transform3D(Basis(x_axis, y_axis, z_axis), centre)


# Let this object go.
func let_go() -> void:
	# Ignore if we haven't been picked up.
	if not picked_up_by:
		return

	# Cancel any ongoing tween
	if tween:
		tween.kill()
		tween = null

	# Remember our current transform.
	var current_transform = global_transform

	# Remove us from what picked us up.
	picked_up_by.remove_child(self)
	picked_up_by = null

	# Reset some state.
	original_parent.add_child(self)
	global_transform = current_transform
	freeze = false


# Update our highlight to show that we can be picked up
func _update_highlight() -> void:
	if not picked_up_by and not closest_areas.is_empty():
		# add highlight
		for child in get_children():
			if child is MeshInstance3D:
				var mesh_instance : MeshInstance3D = child
				mesh_instance.material_overlay = highlight_material
	else:
		# remove highlight
		for child in get_children():
			if child is MeshInstance3D:
				var mesh_instance : MeshInstance3D = child
				mesh_instance.material_overlay = null
