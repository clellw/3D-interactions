class_name FireballClap
extends Node3D

## Two-handed spell: clap two small fireballs together to create a big one.
##
## Must be a direct child of XROrigin3D with an identity transform (hand joint
## positions are in XROrigin3D space; to_global() converts them to world).
##
##   IDLE     --(a fireball in each hand, both hands flat)-->           READY
##   READY    --(palms facing each other come together fast)-->         clap!
##            clap: both small fireballs fly into the clap point and merge,
##            a big burst of fire + a ring shockwave, a BigFireball appears.
##   HOLDING  : the big ball stays between the palms and grows as the hands
##              move apart (min_radius .. max_radius).
##            --(both hands pushed forward together, quickly)-->  launch
##            --(index raised on one hand, other fingers curled)--> FINGER
##            --(hands too far apart, or one hand lost too long)--> fizzle
##   FINGER   : "Death Ball" style. The ball hovers above the raised index and
##              slowly keeps growing (up to finger_max_radius).
##            --(index lowered: pointing roughly horizontal or down)-->
##              thrown where the finger points
##            --(finger pose lost for a moment)--> back to HOLDING
##
## While a big fireball exists (HOLDING / FINGER), is_busy() is true: the
## pickup handlers don't spawn the sword and the snap detectors don't create
## small fireballs, since closing the hand to raise the index would trigger
## them otherwise.
##
## Clap detection, each frame in READY:
##   - both small fireballs are in their FLAT pose (HandOrb.is_flat()),
##   - the palms are closer than clap_distance,
##   - the palms face each other (their normals point at each other),
##   - and the distance between them shrank fast (closing speed), so simply
##     resting the hands close together doesn't trigger it.

signal clapped(global_pos : Vector3)

enum State { IDLE, READY, HOLDING, FINGER, COOLDOWN }

@export_group("Clap")
## Palms closer than this (meters) = clap.
@export var clap_distance : float = 0.09
## How much the palms must face each other: dot product of the two palm
## normals must be below this (-1 = perfectly facing, 0 = perpendicular).
@export var clap_facing : float = -0.5
## The palms must be closing at least this fast (m/s).
@export var clap_min_speed : float = 0.4

@export_group("Big fireball")
## Radius of the big ball when the hands are close / far apart.
@export var min_radius : float = 0.03
@export var max_radius : float = 0.12
## Hand distance (meters) giving min_radius / max_radius.
@export var min_hands_distance : float = 0.12
@export var max_hands_distance : float = 0.5
## Pulling the hands further apart than this makes the ball fizzle out.
@export var fizzle_distance : float = 0.9
## If a hand isn't tracked for this long while holding, the ball fizzles.
@export var lost_hand_timeout : float = 1.0

@export_group("Launch")
## Each hand must move at least this fast (m/s)...
@export var launch_min_speed : float = 1.0
## ...both in roughly the same direction (dot of directions above this)...
@export var launch_same_direction : float = 0.6
## ...and away from the player (dot with the head's forward above this),
## so lowering both hands doesn't launch it.
@export var launch_forward : float = 0.3
## The ball must have been held at least this long before it can be launched
## (the hands bounce apart right after the clap).
@export var launch_min_hold_time : float = 0.4

@export_group("Finger throw (Death Ball)")
## Finger straightness (see HandOrb): index above this = extended...
@export var finger_extended : float = 0.85
## ...middle, ring and pinky below this = curled.
@export var finger_curled : float = 0.6
## To take the ball, the index must point up: dot(index direction, up) above
## this (1 = straight up, 0.7 = within ~45 degrees).
@export var finger_up_dot : float = 0.7
## The raised-index pose must be held this long to take the ball (seconds).
@export var finger_confirm_time : float = 0.15
## Gap between the fingertip and the bottom of the ball (meters).
@export var finger_hover_height : float = 0.03
## While hovering over the finger the ball keeps growing at this speed (m/s
## of radius), up to finger_max_radius. Set the speed to 0 to disable.
@export var finger_grow_speed : float = 0.03
@export var finger_max_radius : float = 0.2
## The ball is thrown when the finger is lowered below this: dot(index
## direction, up) (0.2 = pointing about 12 degrees above horizontal or lower).
@export var finger_throw_up_dot : float = 0.2
## Minimum time over the finger before it can be thrown (seconds).
@export var finger_min_hold_time : float = 0.3
## Throw speed (m/s). Slower than the push throw: heavy, menacing.
@export var finger_throw_speed : float = 3.0
## If the finger pose is lost this long, the ball goes back between the hands.
@export var finger_pose_lost_timeout : float = 0.4

var state : State = State.IDLE

var _time : float = 0.0
var _state_since : float = 0.0
var _big : BigFireball = null
var _last_both_tracked : float = 0.0
# Recent history: [time, left palm, right palm, palm distance].
var _history : Array = []
# Finger throw.
var _finger_hand : int = -1            # hand holding the ball on its index
var _raise_since : Array = [ -1.0, -1.0 ] # when each hand started raising its index
var _finger_lost_since : float = -1.0
var _finger_radius : float = 0.0


func _ready() -> void:
	# Lets the pickup handlers and snap detectors ask is_busy().
	add_to_group(&"fireball_claps")


## True while a big fireball is being held (between the hands or on a finger).
func is_busy() -> bool:
	return state == State.HOLDING or state == State.FINGER


func _process(delta : float) -> void:
	_time += delta

	var left = _read_hand(0)
	var right = _read_hand(1)
	var both_tracked : bool = left != null and right != null
	if both_tracked:
		_last_both_tracked = _time
		_history.append([ _time, left.position, right.position, left.position.distance_to(right.position) ])
	while _history.size() > 2 and _time - _history[0][0] > 0.3:
		_history.pop_front()

	match state:
		State.IDLE:
			if _both_orbs_flat():
				_set_state(State.READY)

		State.READY:
			if not _both_orbs_flat():
				_set_state(State.IDLE)
			elif both_tracked and _is_clap(left, right):
				_clap(left, right)

		State.HOLDING:
			_update_holding(left, right, both_tracked)

		State.FINGER:
			_update_finger(left if _finger_hand == 0 else right, delta)

		State.COOLDOWN:
			if _time - _state_since > 0.5:
				_set_state(State.IDLE)


func _set_state(new_state : State) -> void:
	state = new_state
	_state_since = _time


# ---- Clap -------------------------------------------------------------------

func _both_orbs_flat() -> bool:
	return _get_orb(0) != null and _get_orb(0).is_flat() \
		and _get_orb(1) != null and _get_orb(1).is_flat()


func _is_clap(left : Dictionary, right : Dictionary) -> bool:
	var distance : float = left.position.distance_to(right.position)
	if distance > clap_distance:
		return false
	if left.normal.dot(right.normal) > clap_facing:
		return false
	# Closing speed over the last ~0.15 s.
	var old = _history_sample(0.15)
	if old == null:
		return false
	var dt : float = _time - old[0]
	var closing_speed : float = (old[3] - distance) / max(dt, 0.001)
	return closing_speed > clap_min_speed


func _clap(left : Dictionary, right : Dictionary) -> void:
	var point : Vector3 = (left.position + right.position) * 0.5
	print("Clap! Creating a big fireball")

	# The two small fireballs fly into the clap point and merge.
	for hand in 2:
		var orb : HandOrb = _get_orb(hand)
		if orb:
			orb.merge_into(point)

	_spawn_clap_effect(point, (right.position - left.position).normalized())

	_big = BigFireball.new()
	get_tree().current_scene.add_child(_big)
	_big.global_position = point
	_big.hold(point, min_radius)

	_set_state(State.HOLDING)
	clapped.emit(point)


## The "it worked!" effect: a burst of fire, a flat ring of flames expanding
## between the hands like a shockwave, sparks and a strong flash.
func _spawn_clap_effect(point : Vector3, clap_axis : Vector3) -> void:
	var parent : Node = get_tree().current_scene
	var frame := Transform3D(Basis(), point)

	var blast := FireFX.burst(parent, frame, 100, 0.6, 0.09, 0.6, 1.6, 180.0,
		Vector3(0.0, 1.0, 0.0), 3.5, FireFX.flame_ramp())
	FireFX.flash(blast, 4.0, 2.0, 0.5)

	FireFX.burst(parent, frame, 40, 1.0, 0.01, 1.0, 2.5, 180.0,
		Vector3(0.0, -2.0, 0.0), 1.0, FireFX.ember_ramp())

	# Shockwave: particles born on a small ring around the clap axis, pushed
	# outwards by a strong radial acceleration, so they form an expanding
	# flat disc of fire perpendicular to the hands.
	var ring := CPUParticles3D.new()
	ring.one_shot = true
	ring.explosiveness = 1.0
	ring.amount = 80
	ring.lifetime = 0.45
	ring.local_coords = false
	ring.mesh = FireFX.particle_mesh(0.07)
	ring.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	ring.emission_ring_axis = clap_axis
	ring.emission_ring_radius = 0.04
	ring.emission_ring_inner_radius = 0.03
	ring.emission_ring_height = 0.0
	ring.initial_velocity_min = 0.0
	ring.initial_velocity_max = 0.0
	ring.radial_accel_min = 10.0
	ring.radial_accel_max = 14.0
	ring.damping_min = 2.0
	ring.damping_max = 3.0
	ring.gravity = Vector3.ZERO
	ring.scale_amount_curve = FireFX.curve([ Vector2(0.0, 0.6), Vector2(0.3, 1.0), Vector2(1.0, 0.2) ])
	ring.color_ramp = FireFX.flame_ramp()
	parent.add_child(ring)
	ring.global_position = point
	ring.emitting = true
	get_tree().create_timer(1.0).timeout.connect(ring.queue_free)


# ---- Holding / launching ----------------------------------------------------

func _update_holding(left, right, both_tracked : bool) -> void:
	if not is_instance_valid(_big) or not _big.is_held():
		_big = null
		_set_state(State.COOLDOWN)
		return

	# Raised index on one hand: the ball goes onto that finger.
	var raised : int = _check_finger_raise(left, right)
	if raised != -1:
		_finger_hand = raised
		_finger_radius = _big.radius
		_finger_lost_since = -1.0
		_set_state(State.FINGER)
		return

	if not both_tracked:
		# Keep the ball where it is for a moment; fizzle if a hand stays lost.
		if _time - _last_both_tracked > lost_hand_timeout:
			_big.fizzle()
			_big = null
			_set_state(State.COOLDOWN)
		return

	var distance : float = left.position.distance_to(right.position)
	if distance > fizzle_distance:
		_big.fizzle()
		_big = null
		_set_state(State.COOLDOWN)
		return

	# Between the palms, bigger as they move apart.
	var t : float = clamp(inverse_lerp(min_hands_distance, max_hands_distance, distance), 0.0, 1.0)
	_big.hold((left.position + right.position) * 0.5, lerp(min_radius, max_radius, t))

	if _time - _state_since > launch_min_hold_time:
		var direction = _launch_direction()
		if direction != null:
			_big.launch(direction)
			_big = null
			_set_state(State.COOLDOWN)


# ---- Finger throw (Death Ball) ----------------------------------------------

## Index straight, the three other fingers curled (thumb is free).
func _is_index_extended(hand_data : Dictionary) -> bool:
	var s : Array = hand_data.straightness
	return s[0] > finger_extended and s[1] < finger_curled \
		and s[2] < finger_curled and s[3] < finger_curled


## Returns the hand (0 / 1) that has held a raised index long enough, or -1.
func _check_finger_raise(left, right) -> int:
	var hands : Array = [ left, right ]
	for hand in 2:
		var data = hands[hand]
		var raised : bool = data != null and _is_index_extended(data) \
			and data.index_direction.dot(Vector3.UP) > finger_up_dot
		if not raised:
			_raise_since[hand] = -1.0
		elif _raise_since[hand] < 0.0:
			_raise_since[hand] = _time
		elif _time - _raise_since[hand] >= finger_confirm_time:
			return hand
	return -1


func _update_finger(hand_data, delta : float) -> void:
	if not is_instance_valid(_big) or not _big.is_held():
		_big = null
		_set_state(State.COOLDOWN)
		return

	# Pose lost (hand not tracked, or index not extended any more): wait a
	# moment, then give the ball back to both hands.
	if hand_data == null or not _is_index_extended(hand_data):
		if _finger_lost_since < 0.0:
			_finger_lost_since = _time
		elif _time - _finger_lost_since > finger_pose_lost_timeout:
			_raise_since = [ -1.0, -1.0 ]
			_set_state(State.HOLDING)
		return
	_finger_lost_since = -1.0

	# Hover above the fingertip, growing slowly.
	_finger_radius = min(_finger_radius + finger_grow_speed * delta, max(finger_max_radius, _finger_radius))
	var hover : Vector3 = hand_data.index_tip + Vector3.UP * (_finger_radius + finger_hover_height)
	_big.hold(hover, _finger_radius)

	# Finger lowered: throw the ball where the finger points.
	if _time - _state_since > finger_min_hold_time \
			and hand_data.index_direction.dot(Vector3.UP) < finger_throw_up_dot:
		_big.launch(hand_data.index_direction, finger_throw_speed)
		_big = null
		_set_state(State.COOLDOWN)


## Returns the launch direction if both hands are being pushed forward
## together right now, null otherwise.
func _launch_direction():
	var old = _history_sample(0.1)
	if old == null or _history.is_empty():
		return null
	var newest : Array = _history[-1]
	var dt : float = newest[0] - old[0]
	if dt < 0.03:
		return null

	var left_velocity : Vector3 = (newest[1] - old[1]) / dt
	var right_velocity : Vector3 = (newest[2] - old[2]) / dt
	if left_velocity.length() < launch_min_speed or right_velocity.length() < launch_min_speed:
		return null
	if left_velocity.normalized().dot(right_velocity.normalized()) < launch_same_direction:
		return null

	var direction : Vector3 = ((left_velocity + right_velocity) * 0.5).normalized()
	var camera : Camera3D = get_viewport().get_camera_3d()
	if camera:
		var head_forward : Vector3 = -camera.global_transform.basis.z
		if direction.dot(head_forward) < launch_forward:
			return null
	return direction


# ---- Helpers ----------------------------------------------------------------

## Most recent history sample that is at least `age` seconds old (or the
## oldest one we have), null if there's no usable history.
func _history_sample(age : float):
	if _history.size() < 2:
		return null
	for i in range(_history.size() - 1, -1, -1):
		if _time - _history[i][0] >= age:
			return _history[i]
	return _history[0]


## The attached small fireball of a hand (0 = left, 1 = right), or null.
func _get_orb(hand : int) -> HandOrb:
	for detector in get_tree().get_nodes_in_group(&"finger_snap_detectors"):
		if detector.hand == hand:
			return detector.get_orb()
	return null


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


## Everything we need about a hand, in world space, or null if that hand
## isn't tracked this frame (or a needed joint isn't visible):
##   position        : palm centre
##   normal          : direction the palm faces
##   index_tip       : tip of the index finger
##   index_direction : where the index points (knuckle -> tip)
##   straightness    : [index, middle, ring, pinky], ~1 straight, ~0.4 curled
func _read_hand(hand : int):
	var tracker_name : StringName = &"/user/hand_tracker/left" if hand == 0 else &"/user/hand_tracker/right"
	var hand_tracker : XRHandTracker = XRServer.get_tracker(tracker_name)
	if not hand_tracker or not hand_tracker.has_tracking_data:
		return null

	var needed : Array = [ XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST ]
	for chain in FINGER_CHAINS:
		needed.append_array(chain)
	var p := {}
	for joint in needed:
		if not (hand_tracker.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
			return null
		p[joint] = to_global(hand_tracker.get_hand_joint_transform(joint).origin)

	# Same palm normal as HandOrb._palm_normal() (left/right hands are mirrored).
	var forward : Vector3 = p[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL] - p[XRHandTracker.HAND_JOINT_WRIST]
	var side : Vector3 = p[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL] - p[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]
	var normal : Vector3 = forward.cross(side).normalized()
	if hand == 1:
		normal = -normal

	# Straightness of each finger: base-to-tip distance / bone-by-bone length.
	var straightness : Array = []
	for chain in FINGER_CHAINS:
		var length : float = 0.0
		for i in range(1, chain.size()):
			length += p[chain[i - 1]].distance_to(p[chain[i]])
		straightness.append(p[chain[0]].distance_to(p[chain[-1]]) / max(length, 0.0001))

	var index_tip : Vector3 = p[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]
	var index_direction : Vector3 = (index_tip - p[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL]).normalized()

	return {
		"position": p[XRHandTracker.HAND_JOINT_PALM],
		"normal": normal,
		"index_tip": index_tip,
		"index_direction": index_direction,
		"straightness": straightness,
	}
