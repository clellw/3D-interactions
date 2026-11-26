@tool
class_name PickupHandler3D
extends Area3D

# This area3D class detects all physics bodies based on
# PickupAbleBody3D within range and handles the logic
# for selecting the closest one and allowing pickup
# of that object.

# Scene instantiated when the fist gesture is made with nothing in range.
@export var magic_body_scene : PackedScene = preload("res://objects/sword.tscn")

# Detect range specifies within what radius we detect
# objects we can pick up.
@export var detect_range : float = 0.3:
	set(value):
		detect_range = value
		if is_inside_tree():
			_update_detect_range()
			_update_closest_body()

# Pickup Action specifies the action in the OpenXR
# action map that triggers our pickup function.
@export var pickup_action : String = "pickup"

# A finger counts as curled when its straightness is below this value.
# Straightness = (distance from finger base to tip) / (finger length measured
# bone by bone): ~1.0 for a straight finger, ~0.4 for a fully curled one.
# All 4 fingers (index, middle, ring, pinky) must be curled to spawn the sword.
@export_range(0.3, 1.0) var fist_curl_threshold : float = 0.6

# Release by opening the hand (hand tracking): while holding, we remember how
# closed the hand got (lowest average finger straightness). As soon as the
# fingers open by more than this amount compared to that, we let go, without
# waiting for the headset's "pickup" value to drop, which can lag behind.
# Relative, so holding a box with a loosely closed hand doesn't drop it.
@export_range(0.05, 0.6) var release_open_delta : float = 0.2

var closest_body : PickupAbleBody3D
var picked_up_body: PickupAbleBody3D
var was_pickup_pressed : bool = false
# Pickup pressed with nothing in range: we spawn as soon as the fist is full.
var waiting_for_fist : bool = false
# Most closed the hand has been while holding the current object.
var _held_min_straightness : float = 1.0
var _held_min_for : PickupAbleBody3D = null

const FINGER_CHAINS := [
	[ XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	  XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
	  XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP ],
	[ XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
	  XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
	  XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP ],
	[ XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	  XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
	  XRHandTracker.HAND_JOINT_RING_FINGER_TIP ],
	[ XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	  XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
	  XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP ],
]

# Creates a new pickable body at our position and returns it.
func _spawn_magic_body() -> PickupAbleBody3D:
	if not magic_body_scene:
		return null

	var body := magic_body_scene.instantiate() as PickupAbleBody3D
	if not body:
		push_warning("PickupHandler: magic_body_scene must use PickupAbleBody3D")
		return null

	# It needs a parent first, because pick_up() remembers it
	# as the original parent and re-attaches the body there on release.
	get_tree().current_scene.add_child(body)
	body.global_transform = global_transform
	return body

# Update our detection range.
func _update_detect_range() -> void:
	var shape : SphereShape3D = $CollisionShape3D.shape
	if shape:
		shape.radius = detect_range


# Update our closest body.
func _update_closest_body() -> void:
	# Do not do this when we're in the editor.
	if Engine.is_editor_hint():
		return

	# Do not check this if we've picked something up.
	if picked_up_body:
		if closest_body:
			closest_body.remove_is_closest(self)
			closest_body = null

		return

	# Find the body that is currently the closest.
	var new_closest_body : PickupAbleBody3D
	var closest_distance : float = 1000000.0

	for body in get_overlapping_bodies():
		if body is PickupAbleBody3D and not body.is_picked_up():
			var distance_squared = (body.global_position - global_position).length_squared()
			if distance_squared < closest_distance:
				new_closest_body = body
				closest_distance = distance_squared

	# Unchanged? Just exit
	if closest_body == new_closest_body:
		return

	# We had a closest body
	if closest_body:
		closest_body.remove_is_closest(self)

	closest_body = new_closest_body
	if closest_body:
		closest_body.add_is_closest(self)


# Get our controller that we are a child of
func _get_parent_controller() -> XRController3D:
	var parent : Node = get_parent()
	while parent:
		if parent is XRController3D:
			return parent

		parent = parent.get_parent()

	return null


# Straightness of the index, middle, ring and pinky fingers of our hand,
# from the hand tracking joints. Straightness = (distance from finger base to
# tip) / (finger length measured bone by bone): ~1.0 straight, ~0.4 curled.
# Returns null if there is no hand tracking data (e.g. holding controllers),
# and an empty array if some joints aren't visible this frame.
func _finger_straightness():
	var controller : XRController3D = _get_parent_controller()
	if not controller:
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

	var result : Array[float] = []
	for chain in FINGER_CHAINS:
		var path_length : float = 0.0
		var previous : Vector3
		for i in chain.size():
			var joint : XRHandTracker.HandJoint = chain[i]
			if not (hand_tracker.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
				return []
			var joint_pos : Vector3 = hand_tracker.get_hand_joint_transform(joint).origin
			if i > 0:
				path_length += previous.distance_to(joint_pos)
			previous = joint_pos

		var base : Vector3 = hand_tracker.get_hand_joint_transform(chain[0]).origin
		result.append(base.distance_to(previous) / max(path_length, 0.0001))
	return result


# True if the hand holding this handler is making a full fist (index, middle,
# ring and pinky all curled), based on hand tracking joints.
# Without hand tracking data (e.g. holding controllers) there are no finger
# joints to check, so we return true and the pickup action alone decides.
func _is_full_fist() -> bool:
	var straightness = _finger_straightness()
	if straightness == null:
		return true
	if straightness.is_empty():
		return false # can't see all fingers: don't spawn yet
	for value in straightness:
		if value > fist_curl_threshold:
			return false # this finger isn't curled enough
	return true


# True when the fingers have clearly opened since the object was grabbed
# (see release_open_delta). Always false without hand tracking.
func _hand_opened_while_holding() -> bool:
	if _held_min_for != picked_up_body:
		# New object: start tracking from scratch.
		_held_min_for = picked_up_body
		_held_min_straightness = 1.0

	var straightness = _finger_straightness()
	if straightness == null or straightness.is_empty():
		return false

	var average : float = (straightness[0] + straightness[1] + straightness[2] + straightness[3]) / 4.0
	_held_min_straightness = min(_held_min_straightness, average)
	return average - _held_min_straightness > release_open_delta


# 0 = left hand, 1 = right hand, -1 = unknown (from our parent controller).
func get_hand_index() -> int:
	var controller : XRController3D = _get_parent_controller()
	if not controller:
		return -1
	if controller.tracker == &"left_hand":
		return 0
	if controller.tracker == &"right_hand":
		return 1
	return -1


# True if the finger snap detector of our hand currently has a fireball
# (see gestures/finger_snap_detector.gd).
func _hand_has_orb() -> bool:
	# A big fireball being held (FireballClap): closing the hand to raise the
	# index must not spawn the sword either.
	for clap in get_tree().get_nodes_in_group(&"fireball_claps"):
		if clap.is_busy():
			return true

	var hand_index : int = get_hand_index()
	for detector in get_tree().get_nodes_in_group(&"finger_snap_detectors"):
		if detector.hand == hand_index and detector.has_active_orb():
			return true
	return false


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if not Engine.is_editor_hint():
		# Lets the finger snap detectors find us.
		add_to_group(&"pickup_handlers")
	_update_detect_range()
	_update_closest_body()


# Called every physics frame
func _physics_process(delta) -> void:
	if Engine.is_editor_hint():
		return
	# As we move our hands we need to check if the closest body
	# has changed.
	_update_closest_body()

	# Check if our pickup action is true
	var pickup_pressed = false
	var controller : XRController3D = _get_parent_controller()
	if controller:
		# While OpenXR can return this as a boolean, there is a lot of
		# difference in handling thresholds between platforms.
		# So we implement our own logic here.
		var pickup_value : float = controller.get_float(pickup_action)
		var threshold : float = 0.4 if was_pickup_pressed else 0.6
		pickup_pressed = pickup_value > threshold

	# Do we need to let go? Either the headset says the grip is released, or
	# (with hand tracking) we saw the fingers open, which is usually faster.
	if picked_up_body:
		var hand_opened : bool = _hand_opened_while_holding()
		if not pickup_pressed or hand_opened:
			if hand_opened and pickup_pressed:
				print("Released by opening the hand (before the headset's pickup action)")
			picked_up_body.let_go()
			picked_up_body = null

	# Do we need to pick something up?
	if not picked_up_body and pickup_pressed:
		if not was_pickup_pressed:
			# Just pressed: grab what is in range, or wait for a full fist
			# to spawn the sword.
			if closest_body:
				picked_up_body = closest_body
				picked_up_body.pick_up(self)
			else:
				# Not while a fireball is on this hand: closing the fist then
				# crushes the fireball instead of spawning the sword.
				waiting_for_fist = not _hand_has_orb()

		# The headset may report "pickup" as soon as one finger curls, so we
		# only spawn once all four fingers are actually curled. This is checked
		# every frame while pickup is held, so closing the fist slowly works.
		# A fireball appeared on this hand meanwhile (snap): don't spawn.
		if waiting_for_fist and _hand_has_orb():
			waiting_for_fist = false

		if waiting_for_fist and _is_full_fist():
			waiting_for_fist = false
			var body : PickupAbleBody3D = _spawn_magic_body()
			if body:
				picked_up_body = body
				picked_up_body.pick_up(self)

	if not pickup_pressed:
		waiting_for_fist = false

	# Remember our state for the next frame
	was_pickup_pressed = pickup_pressed
