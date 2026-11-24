class_name HandOrb
extends Node3D

## A flame orb that appears after a finger snap and reacts to the hand pose.
##
## It is created by FingerSnapDetector and lives in the world (it is NOT a
## child of the hand): every frame it computes a target position from the hand
## joints and smoothly moves towards it. The target depends on the current mode:
##
##   SNAPPED   : just spawned -> between thumb tip and index tip, slightly above.
##   OPEN      : fingers uncurled but not flat -> centre of the 5 fingertips,
##               slightly above the hand.
##   CUPPED    : hand semi-closed (all fingers half curled) -> floats in the
##               hollow of the hand, a bit off the palm. In this pose the
##               fireball can imbue a sword with fire (see sword_fire.gd).
##   FLAT      : hand flat -> sits just above the palm.
##   PISTOL    : index + middle extended, ring + pinky curled, thumb up -> on
##               the middle fingertip. An aiming beam shows where the shot
##               will go. Flicking the hand upwards (recoil) fires the orb.
##   ABSORBING : fist -> flames squirt out of the hand (crush effect), the orb
##               goes into the palm, shrinks and disappears.
##   FLYING    : fired -> travels straight, pushes the boxes it hits.
##
## How the hand pose is recognised:
## For each finger (index, middle, ring, pinky) we compute a "straightness"
## ratio = (distance from the finger base to the tip) / (length of the finger
## measured bone by bone). A perfectly straight finger gives ~1.0, a fully
## curled finger gives ~0.4. Comparing these 4 numbers with thresholds tells
## us which pose the hand is in. This ratio doesn't depend on hand size.
##
## The thumb moves differently (it doesn't really "curl"), so for it we measure
## how far its tip is from the index knuckle, divided by the palm width.
## Thumb tucked against the fingers (fist, or resting on the middle finger)
## gives a small value; thumb sticking up gives a large one.

signal fired(direction: Vector3)
signal absorbed

enum Mode { SNAPPED, OPEN, CUPPED, FLAT, PISTOL, ABSORBING, FLYING }

# Joints of each finger, from the base (metacarpal, inside the palm) to the tip.
# Including the metacarpal means bending at the knuckle also counts as "curl",
# which is what lets us tell a relaxed hand from a really flat one.
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
const FINGER_NAMES := [ "index", "middle", "ring", "pinky" ]

## 0 = left, 1 = right. Set by FingerSnapDetector.
var hand : int = 0
## Node whose space the joint positions are in (child of XROrigin3D with an
## identity transform). Set by FingerSnapDetector.
var tracking_space : Node3D

# ---- Look -------------------------------------------------------------------
## Orb radius in meters.
var radius : float = 0.02
## How far "slightly above" is, in meters.
var hover_offset : float = 0.04

# ---- Movement ---------------------------------------------------------------
## How fast the orb catches up with its target (higher = snappier).
var follow_speed : float = 14.0
## Faster follow when on the fingertip, so it doesn't lag behind when aiming.
var pistol_follow_speed : float = 30.0

# ---- Pose recognition (straightness ratios, see top of file) ----------------
## A finger above this is "extended" (used for the pistol).
var extended_threshold : float = 0.85
## A finger below this is "curled" (used for the pistol and the fist).
var curled_threshold : float = 0.6
## Thumb-out ratio above this = thumb up (required for the pistol).
var thumb_up_threshold : float = 0.8
## All 4 fingers above this = flat hand.
var flat_threshold : float = 0.95
## All 4 fingers above this (but not flat) = open, relaxed hand.
## All 4 fingers between curled_threshold and this = cupped (semi-closed) hand.
var open_threshold : float = 0.82
## A new pose must be held this long before we switch to it (avoids flicker).
var pose_confirm_time : float = 0.1
## Right after a snap the fingers are still curled: ignore fists for this long
## so the orb isn't absorbed immediately.
var fist_grace_time : float = 0.6
## If the orb ends up on the back of your hand instead of the palm side, set
## this to true (the palm direction is computed from the joints, see
## _palm_normal()).
var flip_palm_normal : bool = false

# ---- Shooting ---------------------------------------------------------------
## Pistol pose must be held this long before a shot can happen.
var pistol_arm_time : float = 0.25
## The recoil must happen within this time window...
var fire_window : float = 0.2
## ...rotating the fingers by at least this many degrees...
var fire_min_angle : float = 25.0
## ...and upwards (change of the finger direction's vertical component).
var fire_min_rise : float = 0.25
## Shot speed in m/s.
var shot_speed : float = 8.0
## Shot is removed after this many seconds if it hits nothing.
var shot_lifetime : float = 3.0
## Impulse given to a rigid body that gets hit.
var shot_impulse : float = 1.5

# ---- Spawn animation --------------------------------------------------------
## When created, the orb grows to this size (1 = normal size)...
var spawn_overshoot : float = 1.8
## ...in this time...
var spawn_grow_time : float = 0.15
## ...then wobbles back down to its normal size in this time.
var spawn_settle_time : float = 0.6

# ---- Aiming aid -------------------------------------------------------------
## Show a beam from the fingers to where the shot will land.
var show_aim_beam : bool = true
## Aim assist: if a rigid body (e.g. a box) is within this angle (degrees) of
## the aim, the beam locks onto it. 0 disables it.
var aim_assist_angle : float = 7.0
## How far the beam (and the aim assist) reaches, in meters.
var aim_max_distance : float = 15.0
## Smoothing of the aim direction (higher = follows the hand faster, but
## shakier). Hand tracking jitters, so a bit of smoothing makes aiming easier.
var aim_smoothing : float = 15.0

## Short description of what the orb is doing, shown by the detector's label.
var debug_text : String = ""

var mode : Mode = Mode.SNAPPED

var _time : float = 0.0          # time since the orb was spawned
var _mode_since : float = 0.0
var _candidate : int = -1        # pose we might switch to
var _candidate_since : float = 0.0
var _first_frame : bool = true
var _aim_history : Array = []    # [ [time, finger direction, aim point, aim point valid], ... ] while in PISTOL
var _velocity : Vector3
var _fly_time : float = 0.0
var _crushed : bool = false      # crush effect already played?

# Aiming state. The direction is computed in _process (from the joints), the
# raycast that finds the aim point runs in _physics_process (physics queries
# are only safe there).
var _aim_direction : Vector3 = Vector3.FORWARD
var _aim_reset : bool = true     # next aim update starts fresh (no smoothing)
var _aim_point : Vector3         # where the shot will go
var _aim_point_valid : bool = false
var _aim_on_surface : bool = false
var _aim_target : Node3D = null  # body picked by the aim assist
var _assist_candidates : Array = []
var _assist_next_refresh : float = 0.0
var _beam : MeshInstance3D
var _beam_material : StandardMaterial3D
var _marker : MeshInstance3D

var _scale_now : float = 1.0     # 1 -> 0 when absorbed
var _scale_goal : float = 1.0
var _spawn_size : float = 0.0    # spawn animation: 0 -> overshoot -> 1 (animated by a tween)
var _ignited : bool = false      # ignition burst already played?
# Visual parts of the flame orb (see _ready()).
var _core : MeshInstance3D        # bright white-yellow heart
var _glow : MeshInstance3D        # larger soft orange halo
var _flames : CPUParticles3D      # flame tongues rising from the orb
var _embers : CPUParticles3D      # a few sparks flying off
var _light : OmniLight3D          # flickering light on the hand
var _noise := FastNoiseLite.new() # smooth random values for the flicker

# Soft round "blob" texture shared by every flame part (made in code, no asset).
static var _soft_texture : GradientTexture2D


## How the flame orb is built:
## - Everything is a camera-facing quad (billboard) with a soft round texture
##   and ADDITIVE blending: overlapping parts add their light, so the centre
##   gets brighter, which is what makes fire look like fire.
## - The flames are particles emitted in WORLD space (local_coords = false):
##   once emitted they don't follow the orb, so moving the hand leaves a trail
##   of fire behind, and they always rise upwards (negative "gravity").
## - Each particle changes colour over its life (yellow -> orange -> red ->
##   transparent) and grows then shrinks, like a flame tongue.
## - A noise function makes the light and the core flicker.
func _ready() -> void:
	# Lets swords (SwordFire) find the fireballs that can imbue them.
	add_to_group(&"hand_orbs")

	_noise.frequency = 1.0
	_noise.seed = randi()

	# Core: small, very bright.
	_core = _make_billboard(radius * 2.2, Color(1.0, 0.95, 0.7, 1.0))
	add_child(_core)

	# Glow: bigger and faint.
	_glow = _make_billboard(radius * 5.0, Color(1.0, 0.45, 0.1, 0.35))
	add_child(_glow)

	# Flames.
	_flames = CPUParticles3D.new()
	_flames.amount = 48
	_flames.lifetime = 0.5
	_flames.local_coords = false
	_flames.mesh = _make_particle_mesh(radius * 1.8)
	_flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_flames.emission_sphere_radius = radius * 0.6
	_flames.direction = Vector3.UP
	_flames.spread = 20.0
	_flames.initial_velocity_min = 0.05
	_flames.initial_velocity_max = 0.15
	_flames.gravity = Vector3(0.0, 0.6, 0.0) # hot air rises
	_flames.scale_amount_curve = _make_curve([ Vector2(0.0, 0.6), Vector2(0.25, 1.0), Vector2(1.0, 0.1) ])
	_flames.color_ramp = _make_gradient(
		[ Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.5, 0.1, 0.8), Color(0.7, 0.12, 0.05, 0.4), Color(0.2, 0.05, 0.05, 0.0) ],
		[ 0.0, 0.3, 0.7, 1.0 ])
	_flames.emitting = false
	add_child(_flames)

	# Embers.
	_embers = CPUParticles3D.new()
	_embers.amount = 10
	_embers.lifetime = 0.9
	_embers.local_coords = false
	_embers.mesh = _make_particle_mesh(radius * 0.35)
	_embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_embers.emission_sphere_radius = radius * 0.5
	_embers.direction = Vector3.UP
	_embers.spread = 50.0
	_embers.initial_velocity_min = 0.1
	_embers.initial_velocity_max = 0.3
	_embers.gravity = Vector3(0.0, 0.3, 0.0)
	_embers.color_ramp = _make_gradient(
		[ Color(1.0, 0.95, 0.6, 1.0), Color(1.0, 0.5, 0.1, 0.9), Color(1.0, 0.3, 0.05, 0.0) ],
		[ 0.0, 0.5, 1.0 ])
	_embers.emitting = false
	add_child(_embers)

	# Light so the fire lights up the hand.
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.2)
	_light.omni_range = 0.35
	add_child(_light)

	# Aiming beam: a thin cylinder (1 m tall along Y) that we stretch and rotate
	# every frame between the orb and the aim point. top_level = true means it
	# ignores the orb's transform, we place it in world space ourselves.
	_beam_material = StandardMaterial3D.new()
	_beam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.0015
	beam_mesh.bottom_radius = 0.0015
	beam_mesh.height = 1.0
	beam_mesh.radial_segments = 6
	beam_mesh.rings = 1
	beam_mesh.material = _beam_material
	_beam = MeshInstance3D.new()
	_beam.mesh = beam_mesh
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.top_level = true
	_beam.visible = false
	add_child(_beam)

	# Dot where the beam lands. Drawn on top of everything so it's always visible.
	_marker = _make_billboard(radius * 1.5, Color(1.0, 0.6, 0.2, 1.0))
	var marker_material := (_marker.mesh as QuadMesh).material as StandardMaterial3D
	marker_material.no_depth_test = true
	marker_material.render_priority = 1
	_marker.top_level = true
	_marker.visible = false
	add_child(_marker)

	# Spawn animation: a tween animates _spawn_size, which multiplies the size
	# of every part of the orb (see _update_visual()).
	#  1. 0 -> overshoot quickly, decelerating (EASE_OUT): a "whoosh".
	#  2. overshoot -> 1 with an ELASTIC curve: it goes a bit under 1, then a
	#     bit over, and settles, which gives a lively wobble.
	var tween := create_tween()
	tween.tween_property(self, "_spawn_size", spawn_overshoot, spawn_grow_time) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "_spawn_size", 1.0, spawn_settle_time) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	_update_visual(0.0)


## True when the fireball can imbue a sword: held in a cupped hand.
func can_imbue() -> bool:
	return mode == Mode.CUPPED


func is_attached_to_hand() -> bool:
	return mode != Mode.FLYING and mode != Mode.ABSORBING


func _process(delta : float) -> void:
	_time += delta

	if not is_instance_valid(tracking_space):
		queue_free()
		return

	if mode == Mode.FLYING:
		# Movement happens in _physics_process (it needs raycasts).
		_update_visual(delta)
		return

	# 1. Read all hand joints in world space.
	var joints : Array = _read_joints()
	if joints.is_empty():
		# Hand not tracked this frame: the orb just floats where it is.
		debug_text = "Orb: %s (hand not tracked)" % Mode.keys()[mode]
		_update_visual(delta)
		return

	# 2. How straight is each finger?
	var straightness : Array[float] = []
	for chain in FINGER_CHAINS:
		straightness.append(_straightness(joints, chain))
	var thumb_out : float = _thumb_out(joints)

	# 3. Recognise the pose and maybe switch mode.
	_update_mode(_classify(straightness, thumb_out))

	# 4. Move towards the target for the current mode.
	var target : Vector3 = _compute_target(joints)
	if _first_frame:
		global_position = target
		_first_frame = false
		if not _ignited:
			# First time we know where the orb is: play the ignition burst there.
			_ignited = true
			_spawn_ignition(global_position)
	else:
		var speed : float = pistol_follow_speed if mode == Mode.PISTOL else follow_speed
		# Frame-rate independent smoothing.
		global_position = global_position.lerp(target, 1.0 - exp(-speed * delta))

	# 5. Mode-specific behaviour.
	if mode == Mode.PISTOL:
		_update_aim_direction(joints, delta)
		_check_fire(joints)
	elif mode == Mode.ABSORBING:
		if not _crushed:
			# Play the crush effect once, at the moment the fist closes.
			_crushed = true
			_spawn_crush(joints[XRHandTracker.HAND_JOINT_PALM])
			# Tell the swords: crushing the ball after imbuing ignites them.
			get_tree().call_group(&"sword_fires", &"on_orb_crushed", self)
		_scale_goal = 0.0
		if _scale_now <= 0.001:
			absorbed.emit()
			queue_free()
			return

	_update_visual(delta)

	debug_text = "Orb: %s\n" % Mode.keys()[mode]
	debug_text += "thumb out %.2f  " % thumb_out
	for i in FINGER_NAMES.size():
		debug_text += "%s %.2f  " % [ FINGER_NAMES[i], straightness[i] ]


# ---- Pose recognition -------------------------------------------------------

## Ratio between the straight-line distance and the bone-by-bone length.
func _straightness(joints : Array, chain : Array) -> float:
	var path_length : float = 0.0
	for i in range(1, chain.size()):
		path_length += joints[chain[i - 1]].distance_to(joints[chain[i]])
	if path_length < 0.0001:
		return 0.0
	return joints[chain[0]].distance_to(joints[chain[-1]]) / path_length


## Distance thumb tip -> index knuckle, relative to the palm width
## (index knuckle -> pinky knuckle), so it doesn't depend on hand size.
func _thumb_out(j : Array) -> float:
	var index_knuckle : Vector3 = j[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL]
	var palm_width : float = index_knuckle.distance_to(j[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL])
	if palm_width < 0.0001:
		return 0.0
	return j[XRHandTracker.HAND_JOINT_THUMB_TIP].distance_to(index_knuckle) / palm_width


## Returns the Mode matching the pose, or -1 if the pose isn't one we know
## (in that case we keep the current mode).
func _classify(s : Array[float], thumb_out : float) -> int:
	var index : float = s[0]
	var middle : float = s[1]
	var ring : float = s[2]
	var pinky : float = s[3]

	# Fist: all 4 fingers curled. Checked first as it's the most specific.
	if index < curled_threshold and middle < curled_threshold \
			and ring < curled_threshold and pinky < curled_threshold:
		return Mode.ABSORBING

	# Pistol: index + middle extended, ring + pinky curled, thumb up.
	if index > extended_threshold and middle > extended_threshold \
			and ring < curled_threshold and pinky < curled_threshold \
			and thumb_out > thumb_up_threshold:
		return Mode.PISTOL

	var least_straight : float = min(min(index, middle), min(ring, pinky))
	var most_straight : float = max(max(index, middle), max(ring, pinky))
	if least_straight > flat_threshold:
		return Mode.FLAT
	if least_straight > open_threshold:
		return Mode.OPEN
	# Cupped: every finger half curled, none fully curled nor straight.
	if least_straight >= curled_threshold and most_straight <= open_threshold:
		return Mode.CUPPED

	return -1


func _update_mode(candidate : int) -> void:
	# Once the fist is detected we're committed to disappearing.
	if mode == Mode.ABSORBING:
		return

	if candidate == -1 or candidate == mode:
		_candidate = -1
		return

	if candidate == Mode.ABSORBING and _time < fist_grace_time:
		return

	# The new pose must be stable for a short time before we switch.
	if candidate != _candidate:
		_candidate = candidate
		_candidate_since = _time
	elif _time - _candidate_since >= pose_confirm_time:
		_set_mode(candidate)


func _set_mode(new_mode : Mode) -> void:
	mode = new_mode
	_mode_since = _time
	_candidate = -1
	if mode == Mode.PISTOL:
		_aim_history.clear()
		_aim_reset = true
		_aim_point_valid = false


# ---- Target positions -------------------------------------------------------

func _compute_target(j : Array) -> Vector3:
	var palm : Vector3 = j[XRHandTracker.HAND_JOINT_PALM]
	var palm_normal : Vector3 = _palm_normal(j)

	match mode:
		Mode.SNAPPED:
			var thumb_index_middle : Vector3 = (j[XRHandTracker.HAND_JOINT_THUMB_TIP] \
				+ j[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]) * 0.5
			return thumb_index_middle + Vector3.UP * hover_offset

		Mode.OPEN:
			# Same distance from every finger = centre of the five fingertips.
			var centre : Vector3 = (j[XRHandTracker.HAND_JOINT_THUMB_TIP] \
				+ j[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] \
				+ j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP] \
				+ j[XRHandTracker.HAND_JOINT_RING_FINGER_TIP] \
				+ j[XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]) / 5.0
			return centre + palm_normal * hover_offset

		Mode.CUPPED:
			# In the hollow of the hand: a third of the way from the palm to
			# the fingertips, and lifted off the palm so it isn't glued to it.
			var tips : Vector3 = (j[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] \
				+ j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP] \
				+ j[XRHandTracker.HAND_JOINT_RING_FINGER_TIP] \
				+ j[XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]) / 4.0
			return palm.lerp(tips, 0.35) + palm_normal * (radius + 0.025)

		Mode.FLAT:
			# Resting on the palm: offset by the radius plus a small gap.
			return palm + palm_normal * (radius + 0.015)

		Mode.PISTOL:
			return j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP] + _finger_direction(j) * radius * 0.5

		Mode.ABSORBING:
			return palm

	return global_position


## Direction the palm faces, computed from the joints.
## forward = wrist -> middle knuckle, side = pinky knuckle -> index knuckle.
## Their cross product is perpendicular to the hand; its sign depends on the
## hand (left/right are mirror images).
func _palm_normal(j : Array) -> Vector3:
	var forward : Vector3 = j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL] \
		- j[XRHandTracker.HAND_JOINT_WRIST]
	var side : Vector3 = j[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL] \
		- j[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]
	var normal : Vector3 = forward.cross(side).normalized()
	if hand == 1:
		normal = -normal
	if flip_palm_normal:
		normal = -normal
	return normal


## Direction the middle finger points to.
func _finger_direction(j : Array) -> Vector3:
	return (j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP] \
		- j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL]).normalized()


# ---- Shooting ---------------------------------------------------------------

## Aim direction: from the index + middle knuckles to the index + middle
## fingertips. Using two fingers and their knuckles is much steadier than a
## single fingertip, and it matches where you "look along" your finger gun.
## It is then smoothed to remove the hand tracking jitter.
func _update_aim_direction(j : Array, delta : float) -> void:
	var knuckles : Vector3 = (j[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL] \
		+ j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL]) * 0.5
	var tips : Vector3 = (j[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] \
		+ j[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP]) * 0.5
	var raw : Vector3 = (tips - knuckles).normalized()

	if _aim_reset:
		_aim_direction = raw
		_aim_reset = false
	else:
		_aim_direction = _aim_direction.lerp(raw, 1.0 - exp(-aim_smoothing * delta)).normalized()


## Keeps a short history of where the fingers point and where the beam lands.
## If during the last fire_window seconds the fingers rotated upwards quickly
## (the recoil of a "finger gun"), we fire at the point the beam showed BEFORE
## the recoil: that's what the user was aiming at.
func _check_fire(j : Array) -> void:
	var direction : Vector3 = _finger_direction(j)
	_aim_history.append([ _time, direction, _aim_point, _aim_point_valid ])
	while not _aim_history.is_empty() and _time - _aim_history[0][0] > fire_window:
		_aim_history.pop_front()

	if _time - _mode_since < pistol_arm_time or _aim_history.is_empty():
		return

	var old_direction : Vector3 = _aim_history[0][1]
	var angle : float = rad_to_deg(old_direction.angle_to(direction))
	if angle > fire_min_angle and direction.y - old_direction.y > fire_min_rise:
		var aimed_point : Vector3 = _aim_history[0][2]
		if _aim_history[0][3] and aimed_point.distance_to(global_position) > 0.05:
			_fire((aimed_point - global_position).normalized())
		else:
			_fire(old_direction)


func _fire(direction : Vector3) -> void:
	mode = Mode.FLYING
	_velocity = direction.normalized() * shot_speed
	_fly_time = 0.0
	_update_beam()
	debug_text = "Orb: FLYING"
	print("Orb fired from ", "left" if hand == 0 else "right", " hand")
	fired.emit(direction)


## Finds where the aim lands: either a body picked by the aim assist, or the
## first surface the aim ray hits, or a point far away.
func _update_aim_point() -> void:
	var space : PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin : Vector3 = global_position

	_aim_target = _find_assist_target(space, origin, _aim_direction)
	if _aim_target:
		_aim_point = _aim_target.global_position
		_aim_on_surface = true
	else:
		var query := PhysicsRayQueryParameters3D.create(origin, origin + _aim_direction * aim_max_distance)
		var hit : Dictionary = space.intersect_ray(query)
		_aim_on_surface = not hit.is_empty()
		_aim_point = hit.position if _aim_on_surface else origin + _aim_direction * aim_max_distance
	_aim_point_valid = true


## Aim assist: the rigid body closest to the aim direction, if it's within
## aim_assist_angle degrees and nothing is in the way.
func _find_assist_target(space : PhysicsDirectSpaceState3D, origin : Vector3, direction : Vector3) -> Node3D:
	if aim_assist_angle <= 0.0:
		return null

	# Looking for bodies in the whole scene is a bit costly, so refresh the
	# list only twice per second.
	if _time >= _assist_next_refresh:
		_assist_candidates = get_tree().current_scene.find_children("*", "RigidBody3D", true, false)
		_assist_next_refresh = _time + 0.5

	var best : Node3D = null
	var best_angle : float = aim_assist_angle
	for body in _assist_candidates:
		# Skip deleted bodies and frozen ones (a box held in a hand is frozen).
		if not is_instance_valid(body) or body.freeze:
			continue
		var to_body : Vector3 = body.global_position - origin
		var distance : float = to_body.length()
		if distance < 0.05 or distance > aim_max_distance:
			continue
		var angle : float = rad_to_deg(direction.angle_to(to_body))
		if angle < best_angle:
			# Line of sight check: nothing else between us and the body.
			var query := PhysicsRayQueryParameters3D.create(origin, body.global_position)
			var hit : Dictionary = space.intersect_ray(query)
			if hit.is_empty() or hit.collider == body:
				best = body
				best_angle = angle
	return best


## Stretches the beam between the orb and the aim point.
func _update_beam() -> void:
	var visible_now : bool = show_aim_beam and mode == Mode.PISTOL and _aim_point_valid
	var beam_vector : Vector3 = _aim_point - global_position
	var length : float = beam_vector.length()
	if not visible_now or length < 0.01:
		_beam.visible = false
		_marker.visible = false
		return

	# Build a basis whose Y axis goes along the beam (the cylinder is along Y)
	# and is scaled to the beam length.
	var y_axis : Vector3 = beam_vector / length
	var x_axis : Vector3 = y_axis.cross(Vector3.UP)
	if x_axis.length() < 0.01:
		x_axis = y_axis.cross(Vector3.RIGHT)
	x_axis = x_axis.normalized()
	var z_axis : Vector3 = x_axis.cross(y_axis)
	_beam.global_transform = Transform3D(Basis(x_axis, y_axis * length, z_axis),
		global_position + beam_vector * 0.5)
	_beam.visible = true

	# Brighter, redder beam when the aim assist has locked onto something.
	_beam_material.albedo_color = Color(1.0, 0.25, 0.1, 0.8) if _aim_target \
		else Color(1.0, 0.55, 0.15, 0.45)

	_marker.global_position = _aim_point
	_marker.visible = _aim_on_surface


func _physics_process(delta : float) -> void:
	if mode == Mode.PISTOL:
		# Wait until _process has computed a first aim direction.
		if not _aim_reset:
			_update_aim_point()
		_update_beam()
		return

	if mode != Mode.FLYING:
		_update_beam() # hides it
		return

	_fly_time += delta
	var from : Vector3 = global_position
	var to : Vector3 = from + _velocity * delta

	# Raycast along this step's movement to see if we hit something.
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit : Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var body = hit.collider
		if body is RigidBody3D and not body.freeze:
			body.apply_impulse(_velocity.normalized() * shot_impulse, hit.position - body.global_position)
		_spawn_pop(hit.position)
		queue_free()
		return

	global_position = to
	if _fly_time > shot_lifetime:
		_spawn_pop(global_position)
		queue_free()


# ---- Visuals ----------------------------------------------------------------

func _update_visual(delta : float) -> void:
	# Shrink out when absorbed (0.25 s).
	_scale_now = move_toward(_scale_now, _scale_goal, delta / 0.25)

	# Final size = absorb factor x spawn animation factor.
	var size : float = max(_scale_now * _spawn_size, 0.001)

	# Flicker: noise gives smooth random values between -1 and 1.
	var flicker : float = _noise.get_noise_1d(_time * 12.0)
	var glow_flicker : float = _noise.get_noise_1d(_time * 7.0 + 100.0)

	# We don't scale the root node: that would also scale particles that are
	# already flying away. Instead each part is sized separately.
	_core.scale = Vector3.ONE * size * (1.0 + 0.12 * flicker)
	_glow.scale = Vector3.ONE * size * (1.0 + 0.2 * glow_flicker)
	_flames.scale_amount_min = 0.7 * size
	_flames.scale_amount_max = 1.2 * size
	_flames.emission_sphere_radius = radius * 0.6 * size
	_embers.scale_amount_min = size
	_embers.scale_amount_max = size

	# Stop emitting when (almost) gone, the remaining flames die out by themselves.
	var burning : bool = _scale_now > 0.05
	_flames.emitting = burning
	_embers.emitting = burning

	_light.light_energy = 0.8 * size * (1.0 + 0.35 * flicker)


## Burst of fire when the shot hits something.
func _spawn_pop(global_pos : Vector3) -> void:
	var burst := _make_burst(global_pos, 40, 0.6, radius * 2.0, 0.4, 1.2, 180.0,
		Vector3(0.0, 0.5, 0.0), 2.5, _flames.color_ramp, true)
	_add_flash(burst, 2.0, 1.0, 0.3)


## Ignition burst when the orb is created (at the same time, the orb itself
## pops in bigger than normal and wobbles down, see the tween in _ready()):
## a ball of flames bursting out, a column of fire shooting up, sparks flying
## everywhere and a bright flash.
func _spawn_ignition(pos : Vector3) -> void:
	# Ball of flames bursting out in every direction, slowed down quickly.
	var blast := _make_burst(pos, 60, 0.6, radius * 2.5, 0.3, 1.0, 180.0,
		Vector3(0.0, 1.0, 0.0), 3.0, _flames.color_ramp, true)
	_add_flash(blast, 3.0, 1.2, 0.5)

	# Column of fire shooting upwards.
	var column := _make_burst(pos, 30, 0.8, radius * 2.0, 0.4, 0.8, 15.0,
		Vector3(0.0, 0.8, 0.0), 1.0, _flames.color_ramp, true)
	column.explosiveness = 0.6 # a short stream rather than a single puff

	# Lots of sparks flying away and falling.
	_make_burst(pos, 30, 0.8, radius * 0.3, 0.5, 1.5, 180.0,
		Vector3(0.0, -1.0, 0.0), 1.0, _embers.color_ramp, true)


## Crush effect when the fist closes on the orb: fire squirting out of the
## hand in every direction, sparks falling down and a puff of smoke rising.
## It is made of 3 one-shot particle bursts started at the same time.
func _spawn_crush(palm_pos : Vector3) -> void:
	# Flames squeezed out between the fingers: fast, short-lived, slowed down
	# quickly by damping so they stay close to the hand.
	var flames := _make_burst(palm_pos, 50, 0.4, radius * 1.6, 0.3, 0.9, 180.0,
		Vector3(0.0, 0.8, 0.0), 4.0, _flames.color_ramp, true)
	_add_flash(flames, 1.5, 0.6, 0.4)

	# Sparks: small, fly further and fall down (negative gravity in Y).
	_make_burst(palm_pos, 20, 0.9, radius * 0.3, 0.3, 0.8, 180.0,
		Vector3(0.0, -1.5, 0.0), 0.5, _embers.color_ramp, true)

	# Smoke: big, slow, grows while rising and fades out. Smoke is NOT
	# additive (it should darken, not add light), so it uses normal blending.
	var smoke_ramp := _make_gradient(
		[ Color(0.25, 0.22, 0.2, 0.35), Color(0.3, 0.3, 0.3, 0.2), Color(0.35, 0.35, 0.35, 0.0) ],
		[ 0.0, 0.5, 1.0 ])
	var smoke := _make_burst(palm_pos, 14, 1.4, radius * 3.0, 0.05, 0.15, 40.0,
		Vector3(0.0, 0.25, 0.0), 0.5, smoke_ramp, false)
	smoke.explosiveness = 0.5 # spread the puffs a bit over time
	smoke.scale_amount_curve = _make_curve([ Vector2(0.0, 0.25), Vector2(1.0, 1.0) ])


## Creates a one-shot particle burst in the world and deletes it afterwards.
func _make_burst(global_pos : Vector3, amount : int, lifetime : float, size : float,
		velocity_min : float, velocity_max : float, spread : float, gravity : Vector3,
		damping : float, color_ramp : Gradient, additive : bool) -> CPUParticles3D:
	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.explosiveness = 0.9 # (almost) all particles at once
	burst.amount = amount
	burst.lifetime = lifetime
	burst.local_coords = false
	burst.mesh = _make_particle_mesh(size, additive)
	burst.direction = Vector3.UP
	burst.spread = spread # 180 = every direction
	burst.initial_velocity_min = velocity_min
	burst.initial_velocity_max = velocity_max
	burst.damping_min = damping
	burst.damping_max = damping * 1.3
	burst.gravity = gravity
	burst.scale_amount_curve = _make_curve([ Vector2(0.0, 1.0), Vector2(1.0, 0.2) ])
	burst.color_ramp = color_ramp
	get_parent().add_child(burst)
	burst.global_position = global_pos
	burst.emitting = true

	# Remove the burst once its particles are gone.
	get_tree().create_timer(lifetime + 0.5).timeout.connect(burst.queue_free)
	return burst


## Short flash of light that fades out.
func _add_flash(parent : Node3D, energy : float, light_range : float, duration : float) -> void:
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.5, 0.15)
	flash.omni_range = light_range
	flash.light_energy = energy
	parent.add_child(flash)
	flash.create_tween().tween_property(flash, "light_energy", 0.0, duration)


# ---- Visual building blocks -------------------------------------------------

func _get_soft_texture() -> GradientTexture2D:
	if not _soft_texture:
		# Radial gradient: opaque white in the centre, transparent at the edge.
		_soft_texture = GradientTexture2D.new()
		_soft_texture.gradient = _make_gradient([ Color(1, 1, 1, 1), Color(1, 1, 1, 0) ], [ 0.0, 1.0 ])
		_soft_texture.fill = GradientTexture2D.FILL_RADIAL
		_soft_texture.fill_from = Vector2(0.5, 0.5)
		_soft_texture.fill_to = Vector2(0.5, 0.0)
		_soft_texture.width = 64
		_soft_texture.height = 64
	return _soft_texture


## Unshaded material using the soft texture, additive by default.
func _make_fire_material(billboard : BaseMaterial3D.BillboardMode, additive : bool = true) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	material.albedo_texture = _get_soft_texture()
	material.billboard_mode = billboard
	material.billboard_keep_scale = true
	return material


## A single camera-facing quad (used for the core and the glow).
func _make_billboard(size : float, tint : Color) -> MeshInstance3D:
	var material := _make_fire_material(BaseMaterial3D.BILLBOARD_ENABLED)
	material.albedo_color = tint

	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = quad
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh_instance


## Quad used by particles. Its colour comes from the particle's colour ramp
## (stored as vertex colour), so the material uses vertex colours.
func _make_particle_mesh(size : float, additive : bool = true) -> QuadMesh:
	var material := _make_fire_material(BaseMaterial3D.BILLBOARD_PARTICLES, additive)
	material.vertex_color_use_as_albedo = true

	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material
	return quad


func _make_gradient(colors : Array, offsets : Array) -> Gradient:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	gradient.colors = PackedColorArray(colors)
	return gradient


func _make_curve(points : Array) -> Curve:
	var curve := Curve.new()
	for point in points:
		curve.add_point(point)
	return curve


# ---- Helpers ----------------------------------------------------------------

## Returns the 26 joint positions in world space, or an empty array if the
## hand isn't tracked or a joint isn't valid this frame.
func _read_joints() -> Array:
	var tracker_name : StringName = &"/user/hand_tracker/left" if hand == 0 \
		else &"/user/hand_tracker/right"
	var hand_tracker : XRHandTracker = XRServer.get_tracker(tracker_name)
	if not hand_tracker or not hand_tracker.has_tracking_data:
		return []

	var joints : Array = []
	joints.resize(XRHandTracker.HAND_JOINT_MAX)
	for i in XRHandTracker.HAND_JOINT_MAX:
		var joint := i as XRHandTracker.HandJoint
		if not (hand_tracker.get_hand_joint_flags(joint) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID):
			return []
		joints[i] = tracking_space.to_global(hand_tracker.get_hand_joint_transform(joint).origin)
	return joints
