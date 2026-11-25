class_name PickupAbleBody3D
extends RigidBody3D

var highlight_material : Material = preload("res://shaders/highlight_material.tres")
var picked_up_by : Area3D
var closest_areas : Array

var original_parent : Node3D
var tween : Tween

# ---- Throwing ----------------------------------------------------------------
# While held, the object is frozen and simply follows the hand, so the physics
# engine doesn't know how fast it moves. We record where it was during the
# last frames, and when it is released we give it that speed and spin, so it
# can be thrown (and caught again, e.g. to juggle).

## Multiplies the throw speed (1 = exactly the hand speed). A little more
## than 1 feels better in VR since there's no weight in your hand.
@export var throw_strength : float = 1.2
## Multiplies the spin given when throwing.
@export var throw_spin_strength : float = 1.0
## The hand speed is measured over stretches of this duration (seconds).
## Longer = smoother but less precise. Hand tracking jitters, so not too short.
@export var throw_sample_time : float = 0.06
## When releasing, we look back this far for the FASTEST stretch of movement.
## The release is detected a little after the throw itself, when the hand is
## already slowing down; using the peak speed compensates for that delay.
@export var throw_search_time : float = 0.2
## Maximum throw speed in m/s (avoids crazy throws from a tracking glitch).
@export var max_throw_speed : float = 15.0

var _motion_samples : Array = []   # [ [time, global transform], ... ] while held
var _centre_local : Vector3        # approximate centre of mass, local space


func _ready() -> void:
	# We track the speed of the centre of mass (not of the origin, which for
	# the sword is at the bottom of the handle) so throws behave correctly
	# when spinning. If the scene sets a custom centre of mass, use it...
	if center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM:
		_centre_local = center_of_mass
		return

	# ...otherwise approximate it: average position of our collision shapes.
	var count : int = 0
	for child in get_children():
		if child is CollisionShape3D:
			_centre_local += child.position
			count += 1
	if count > 0:
		_centre_local /= count


func _physics_process(_delta : float) -> void:
	if not picked_up_by:
		return
	var now : float = Time.get_ticks_msec() / 1000.0
	_motion_samples.append([ now, global_transform ])
	# Keep a little more than the window we need.
	while _motion_samples.size() > 2 and now - _motion_samples[0][0] > throw_search_time + throw_sample_time + 0.05:
		_motion_samples.pop_front()


## Velocity of the hand at the fastest moment of the last throw_search_time.
## Returns [ linear velocity, angular velocity ].
func _compute_throw_velocity() -> Array:
	var result : Array = [ Vector3.ZERO, Vector3.ZERO ]
	if _motion_samples.size() < 2:
		return result

	var newest_time : float = _motion_samples[-1][0]
	var best_speed : float = -1.0

	# Try every sample of the search window as the END of a stretch lasting
	# about throw_sample_time, and keep the stretch with the highest speed.
	for end_index in range(_motion_samples.size() - 1, 0, -1):
		var end_sample : Array = _motion_samples[end_index]
		if newest_time - end_sample[0] > throw_search_time:
			break

		# Latest sample at least throw_sample_time before the end.
		var start_index : int = end_index - 1
		while start_index > 0 and end_sample[0] - _motion_samples[start_index][0] < throw_sample_time:
			start_index -= 1
		var start_sample : Array = _motion_samples[start_index]

		var velocity : Array = _velocity_between(start_sample, end_sample)
		var speed : float = velocity[0].length()
		if speed > best_speed:
			best_speed = speed
			result = velocity

	var linear : Vector3 = result[0] * throw_strength
	if linear.length() > max_throw_speed:
		linear = linear.normalized() * max_throw_speed
	return [ linear, result[1] * throw_spin_strength ]


## Linear velocity of the centre of mass and angular velocity between two
## recorded samples ([time, global transform]).
func _velocity_between(old_sample : Array, new_sample : Array) -> Array:
	var dt : float = new_sample[0] - old_sample[0]
	if dt < 0.005:
		return [ Vector3.ZERO, Vector3.ZERO ]

	var t_old : Transform3D = old_sample[1]
	var t_new : Transform3D = new_sample[1]

	# Linear: how far the centre of mass moved, divided by the time.
	var linear : Vector3 = ((t_new * _centre_local) - (t_old * _centre_local)) / dt

	# Angular: the rotation between the two orientations, as axis * angle,
	# divided by the time = angular velocity in rad/s.
	var delta_rotation : Quaternion = (t_new.basis.orthonormalized() \
		* t_old.basis.orthonormalized().inverse()).get_rotation_quaternion()
	var angular : Vector3 = Vector3.ZERO
	var angle : float = delta_rotation.get_angle()
	if angle > 0.0001:
		# get_angle() is in [0, 2*PI]: take the short way round.
		if angle > PI:
			angle -= TAU
		angular = delta_rotation.get_axis().normalized() * angle / dt

	return [ linear, angular ]


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
	_motion_samples.clear()
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

	# Remember our current transform, and how the hand was moving.
	var current_transform = global_transform
	var throw : Array = _compute_throw_velocity()
	_motion_samples.clear()

	# Remove us from what picked us up.
	picked_up_by.remove_child(self)
	picked_up_by = null

	# Reset some state.
	original_parent.add_child(self)
	global_transform = current_transform
	freeze = false

	# Throw: give the body the speed and spin of the hand.
	sleeping = false
	linear_velocity = throw[0]
	angular_velocity = throw[1]
	if throw[0].length() > 0.5:
		print("Thrown %s at %.1f m/s, spinning at %.1f rad/s" % [ name, throw[0].length(), throw[1].length() ])


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
