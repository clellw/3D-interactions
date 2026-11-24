class_name FingerSnapDetector
extends Node3D

## Detects a finger snap (thumb + middle finger) from OpenXR hand tracking data.
##
## IMPORTANT: this node must be a direct child of XROrigin3D with an identity
## transform. Hand joint positions are given in XROrigin3D space, so being a
## child of XROrigin3D lets us use to_global() to get world positions.
##
## How a snap is recognised (a small state machine):
##
##   IDLE      --(thumb tip touches middle tip)-->                 ARMED
##   ARMED     --(they separate FAST and the middle finger ends
##                curled against the palm)-->                     SNAP! -> COOLDOWN
##   ARMED     --(separation too slow / finger opens instead)-->   IDLE   (it was just a pinch)
##   COOLDOWN  --(short delay elapsed and fingers apart)-->        IDLE
##
## The "curled against the palm" check is what separates a snap from simply
## releasing a pinch: when you snap, the middle finger slams down onto the
## base of the thumb / palm. When you release a pinch, it opens away.

## Emitted when a snap is detected. global_pos is where the thumb tip was.
signal finger_snapped(hand: int, global_pos: Vector3)

enum SnapState { IDLE, ARMED, COOLDOWN }

## Which hand this detector watches.
@export_enum("Left", "Right") var hand : int = 0

## Optional label that displays live values, useful to tune the thresholds.
@export var debug_label : Label3D

## Spawn a HandOrb when a snap is detected (see hand_orb.gd).
## Only one orb per hand: a new one can be spawned once the previous one has
## been absorbed (fist) or fired (finger gun).
@export var spawn_orb : bool = true

@export_group("Thresholds (meters / seconds)")
## Thumb tip and middle tip closer than this = "touching" (arms the snap).
@export var touch_distance : float = 0.02
## Thumb tip and middle tip further than this = "released".
@export var release_distance : float = 0.035
## Middle tip closer than this to the palm centre = finger is curled.
@export var curl_distance : float = 0.065
## The release must happen within this time after the last "touching" frame.
## Hand tracking is smoothed and the fingers occlude each other during a snap,
## so this can't be too small.
@export var max_release_time : float = 0.2
## The fingers must have been touching at least this long (filters noise).
@export var min_armed_time : float = 0.05
## Time after a snap during which no new snap can be detected.
@export var cooldown_time : float = 0.4

var state : SnapState = SnapState.IDLE
var snap_count : int = 0

var _armed_since : float = 0.0
var _last_touch_time : float = 0.0
var _cooldown_until : float = 0.0
var _last_snap_release_ms : int = -1
var _flash_until : float = 0.0
var _orb : HandOrb = null

# Last known values, for the debug label.
var _thumb_middle_dist : float = 0.0
var _middle_palm_dist : float = 0.0


func _process(_delta : float) -> void:
	var now : float = Time.get_ticks_msec() / 1000.0

	# 1. Get the hand tracker (the same one XRHandModifier3D uses).
	var tracker_name : StringName = &"/user/hand_tracker/left" if hand == 0 \
		else &"/user/hand_tracker/right"
	var hand_tracker : XRHandTracker = XRServer.get_tracker(tracker_name)

	if not hand_tracker or not hand_tracker.has_tracking_data:
		# No optical hand tracking (e.g. controllers in hand): nothing to detect.
		state = SnapState.IDLE
		_update_label(now, "No hand tracking data\n(put the controllers down)")
		return

	# 2. Read the joints we need.
	var thumb_tip = _get_joint_position(hand_tracker, XRHandTracker.HAND_JOINT_THUMB_TIP)
	var middle_tip = _get_joint_position(hand_tracker, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP)
	var palm = _get_joint_position(hand_tracker, XRHandTracker.HAND_JOINT_PALM)

	if thumb_tip == null or middle_tip == null or palm == null:
		# Joints hidden this frame (very common during a snap, the fingers hide
		# each other). We keep the current state: if tracking comes back quickly
		# the timing check below still works.
		_update_label(now, "Joints not visible this frame")
		return

	# 3. Compute the two measurements the gesture is based on.
	_thumb_middle_dist = thumb_tip.distance_to(middle_tip)
	_middle_palm_dist = middle_tip.distance_to(palm)

	# 4. Run the state machine.
	match state:
		SnapState.IDLE:
			if _thumb_middle_dist < touch_distance:
				state = SnapState.ARMED
				_armed_since = now
				_last_touch_time = now

		SnapState.ARMED:
			if _thumb_middle_dist < touch_distance:
				# Still pressing thumb and middle together.
				_last_touch_time = now
			else:
				var time_since_touch : float = now - _last_touch_time
				var held_time : float = _last_touch_time - _armed_since

				if time_since_touch > max_release_time:
					# Too slow: this was a normal pinch being released.
					state = SnapState.IDLE
				elif _thumb_middle_dist > release_distance \
						and _middle_palm_dist < curl_distance \
						and held_time >= min_armed_time:
					# Fast release + middle finger curled onto the palm = snap!
					_last_snap_release_ms = int(time_since_touch * 1000.0)
					_on_snap(now, thumb_tip)

		SnapState.COOLDOWN:
			if now > _cooldown_until and _thumb_middle_dist > release_distance:
				state = SnapState.IDLE

	_update_label(now, "")


## Returns the joint position (XROrigin3D space), or null if it isn't valid.
func _get_joint_position(hand_tracker : XRHandTracker, joint : XRHandTracker.HandJoint):
	var flags : int = hand_tracker.get_hand_joint_flags(joint)
	if not (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
		return null
	return hand_tracker.get_hand_joint_transform(joint).origin


func _on_snap(now : float, thumb_tip : Vector3) -> void:
	state = SnapState.COOLDOWN
	_cooldown_until = now + cooldown_time
	snap_count += 1
	_flash_until = now + 0.3

	var global_pos : Vector3 = to_global(thumb_tip)
	print("Finger snap detected on ", "left" if hand == 0 else "right",
		" hand (release took ", _last_snap_release_ms, " ms)")

	if spawn_orb and not has_orb_on_hand() and not _is_hand_holding_something():
		_spawn_orb()

	finger_snapped.emit(hand, global_pos)


func _ready() -> void:
	# Lets the PickupHandler3D nodes find us (see pickup_handler.gd).
	add_to_group(&"finger_snap_detectors")


## True while this hand has an orb that hasn't been fired yet: on the hand, or
## being crushed in the fist. Used by PickupHandler3D so that closing the fist
## on a fireball crushes it instead of also spawning the sword.
func has_active_orb() -> bool:
	return is_instance_valid(_orb) and _orb.mode != HandOrb.Mode.FLYING


## True if this hand currently holds an object (e.g. the sword): a snap made
## while holding it must not create a fireball. The PickupHandler3D nodes
## register in the "pickup_handlers" group; without any, this is always false.
func _is_hand_holding_something() -> bool:
	for handler in get_tree().get_nodes_in_group(&"pickup_handlers"):
		if handler.get_hand_index() == hand and handler.picked_up_body:
			return true
	return false


## True while this hand still holds an orb (not yet fired or absorbed).
func has_orb_on_hand() -> bool:
	return is_instance_valid(_orb) and _orb.is_attached_to_hand()


func _spawn_orb() -> void:
	_orb = HandOrb.new()
	_orb.hand = hand
	# Joint positions are in XROrigin3D space; this node is a child of
	# XROrigin3D with an identity transform, so the orb uses it to convert
	# joint positions to world positions.
	_orb.tracking_space = self
	# The orb lives in the world, not under the hand: it moves on its own.
	get_tree().current_scene.add_child(_orb)


func _update_label(now : float, message : String) -> void:
	if not debug_label:
		return

	var text : String = ("Left" if hand == 0 else "Right") + " hand - finger snap\n"
	if message != "":
		text += message + "\n"
	text += "State: %s\n" % SnapState.keys()[state]
	text += "thumb <-> middle: %.1f cm (touch < %.1f, release > %.1f)\n" % [
		_thumb_middle_dist * 100.0, touch_distance * 100.0, release_distance * 100.0]
	text += "middle <-> palm: %.1f cm (curled < %.1f)\n" % [
		_middle_palm_dist * 100.0, curl_distance * 100.0]
	if _last_snap_release_ms >= 0:
		text += "Last snap release: %d ms\n" % _last_snap_release_ms
	text += "Snaps: %d" % snap_count
	if has_orb_on_hand():
		text += "\n" + _orb.debug_text

	debug_label.text = text
	debug_label.modulate = Color(1.0, 0.85, 0.2) if now < _flash_until else Color.WHITE
