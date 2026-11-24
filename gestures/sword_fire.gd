class_name SwordFire
extends Node3D

## Lets a fireball (HandOrb) imbue a sword with fire.
##
## Put this node as a child of the sword (identity transform) and set
## blade_start / blade_end to the bottom and the tip of the blade, in the
## sword's local space.
##
## How it works:
## - The blade is split into segment_count parts. Each part has a "heat"
##   value from 0 to 1, and its own flame emitter that grows with the heat.
## - Every frame we look for fireballs in the "hand_orbs" group. A fireball
##   held in a cupped hand (HandOrb.can_imbue()) heats every part closer than
##   imbue_radius. A part that reaches heat 1 ignites (small pop of fire).
##   So the blade catches fire progressively, where the ball passes.
## - When every part is ignited, the sword is CHARGED: it waits for the
##   fireball to be crushed. The HandOrb tells us through
##   on_orb_crushed() (it calls the "sword_fires" group).
## - Crushed while CHARGED -> IGNITED: a big burst along the blade, the flames
##   pop bigger and settle, and the sword keeps burning.
##   Crushed (or fired) too early -> COOLING: the partial flames die out.
##
##   IDLE --(ball heats a part)--> CHARGING --(all parts ignited)--> CHARGED
##   CHARGED --(ball crushed)--> IGNITED --(burn_duration elapsed)--> COOLING
##   CHARGING --(ball crushed / fired / gone)--> COOLING --(cold)--> IDLE

signal charged
signal ignited
signal extinguished

enum State { IDLE, CHARGING, CHARGED, IGNITED, COOLING }

## Bottom of the blade (just above the guard), in the sword's local space.
@export var blade_start : Vector3 = Vector3(0.0, 0.31, 0.0)
## Tip of the blade, in the sword's local space.
@export var blade_end : Vector3 = Vector3(0.0, 0.75, 0.0)
## Blade width and thickness, used to spread the flames over the blade.
@export var blade_width : float = 0.12
@export var blade_thickness : float = 0.03
## Number of parts the blade is split into. Each part heats up separately.
@export_range(3, 30) var segment_count : int = 10
## The fireball heats the parts of the blade closer than this (meters).
@export var imbue_radius : float = 0.08
## Time the fireball must stay on a part for it to ignite.
@export var heat_time : float = 0.25
## Time for the flames to die out when the imbuing fails or the fire ends.
@export var cool_time : float = 1.0
## How long the sword burns once ignited, in seconds. 0 = forever.
@export var burn_duration : float = 0.0

var state : State = State.IDLE

var _heat := PackedFloat32Array()
var _segment_ignited : Array[bool] = []
var _flames : Array[CPUParticles3D] = []
var _embers : CPUParticles3D
var _light : OmniLight3D
var _charging_orb : Node = null
var _boost : float = 1.0          # ignition "pop" (animated by a tween)
var _time : float = 0.0
var _ignited_since : float = 0.0
var _noise := FastNoiseLite.new()
var _flame_ramp : Gradient
var _ember_ramp : Gradient

static var _soft_texture : GradientTexture2D


func _ready() -> void:
	add_to_group(&"sword_fires")
	_noise.frequency = 1.0
	_noise.seed = randi()

	_heat.resize(segment_count)
	_heat.fill(0.0)
	_segment_ignited.resize(segment_count)
	_segment_ignited.fill(false)

	_flame_ramp = _make_gradient(
		[ Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.5, 0.1, 0.8), Color(0.7, 0.12, 0.05, 0.4), Color(0.2, 0.05, 0.05, 0.0) ],
		[ 0.0, 0.3, 0.7, 1.0 ])
	_ember_ramp = _make_gradient(
		[ Color(1.0, 0.95, 0.6, 1.0), Color(1.0, 0.5, 0.1, 0.9), Color(1.0, 0.3, 0.05, 0.0) ],
		[ 0.0, 0.5, 1.0 ])

	# One flame emitter per part of the blade. Each emitter is placed at the
	# centre of its part and emits from a box the size of that part.
	# local_coords = false: once emitted, flames stay in the world, so
	# swinging the sword leaves a trail of fire.
	var segment_length : float = _blade_length() / segment_count
	for i in segment_count:
		var flames := CPUParticles3D.new()
		flames.amount = 14
		flames.lifetime = 0.35
		flames.local_coords = false
		flames.mesh = _make_particle_mesh(0.035)
		flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		flames.emission_box_extents = Vector3(blade_width * 0.5, segment_length * 0.5, blade_thickness * 0.5)
		flames.direction = Vector3.UP
		flames.spread = 30.0
		flames.initial_velocity_min = 0.02
		flames.initial_velocity_max = 0.06
		flames.gravity = Vector3(0.0, 0.7, 0.0) # hot air rises
		flames.scale_amount_curve = _make_curve([ Vector2(0.0, 0.6), Vector2(0.25, 1.0), Vector2(1.0, 0.1) ])
		flames.color_ramp = _flame_ramp
		flames.emitting = false
		add_child(flames)
		flames.transform = _blade_frame((i + 0.5) / segment_count)
		_flames.append(flames)

	# Sparks over the whole blade, only once charged / ignited.
	_embers = CPUParticles3D.new()
	_embers.amount = 16
	_embers.lifetime = 0.8
	_embers.local_coords = false
	_embers.mesh = _make_particle_mesh(0.006)
	_embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_embers.emission_box_extents = Vector3(blade_width * 0.5, _blade_length() * 0.5, blade_thickness * 0.5)
	_embers.direction = Vector3.UP
	_embers.spread = 60.0
	_embers.initial_velocity_min = 0.1
	_embers.initial_velocity_max = 0.3
	_embers.gravity = Vector3(0.0, 0.3, 0.0)
	_embers.color_ramp = _ember_ramp
	_embers.emitting = false
	add_child(_embers)
	_embers.transform = _blade_frame(0.5)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.2)
	_light.omni_range = 0.8
	_light.light_energy = 0.0
	add_child(_light)
	_light.position = blade_start.lerp(blade_end, 0.5)


func _process(delta : float) -> void:
	_time += delta

	match state:
		State.IDLE, State.CHARGING:
			_absorb_heat_from_orbs(delta)

		State.CHARGED:
			# The ball disappeared without being crushed (e.g. fired).
			if not _is_orb_alive(_charging_orb):
				_start_cooling()

		State.IGNITED:
			if burn_duration > 0.0 and _time - _ignited_since > burn_duration:
				_start_cooling()

		State.COOLING:
			var still_hot : bool = false
			for i in segment_count:
				_heat[i] = max(_heat[i] - delta / cool_time, 0.0)
				if _heat[i] > 0.0:
					still_hot = true
			# A fireball can re-heat the blade while it cools down.
			_absorb_heat_from_orbs(delta)
			if not still_hot and state == State.COOLING:
				state = State.IDLE
				extinguished.emit()

	_update_visuals()


## Called by HandOrb (through the "sword_fires" group) when a fireball is
## crushed in a fist.
func on_orb_crushed(orb : Node) -> void:
	if orb != _charging_orb:
		return
	if state == State.CHARGED:
		_ignite()
	elif state == State.CHARGING:
		_start_cooling()


func is_on_fire() -> bool:
	return state == State.IGNITED


# ---- Imbuing ----------------------------------------------------------------

func _absorb_heat_from_orbs(delta : float) -> void:
	# The ball that started charging was fired or destroyed: fail.
	if state == State.CHARGING and not _is_orb_alive(_charging_orb):
		_start_cooling()
		return

	for orb in get_tree().get_nodes_in_group(&"hand_orbs"):
		if not orb.can_imbue():
			continue
		# Only one ball at a time charges a sword.
		if state == State.CHARGING and orb != _charging_orb:
			continue

		var heated : bool = false
		for i in segment_count:
			var centre : Vector3 = to_global(_blade_frame((i + 0.5) / segment_count).origin)
			if centre.distance_to(orb.global_position) < imbue_radius:
				heated = true
				_heat[i] = min(_heat[i] + delta / heat_time, 1.0)
				if _heat[i] >= 1.0 and not _segment_ignited[i]:
					_segment_ignited[i] = true
					_segment_pop(i)

		if heated:
			_charging_orb = orb
			if state != State.CHARGING:
				state = State.CHARGING

	if state == State.CHARGING and not _segment_ignited.has(false):
		state = State.CHARGED
		_add_flash(self, 1.0, 0.8, 0.3, _light.position)
		charged.emit()


func _is_orb_alive(orb : Node) -> bool:
	return is_instance_valid(orb) and orb.mode != HandOrb.Mode.FLYING


func _start_cooling() -> void:
	state = State.COOLING
	_charging_orb = null
	_segment_ignited.fill(false)


## Full ignition, like when the fireball is created: big burst along the
## blade, flash, and the flames pop bigger then settle (elastic tween).
func _ignite() -> void:
	state = State.IGNITED
	_ignited_since = _time
	_charging_orb = null
	_heat.fill(1.0)

	var tween := create_tween()
	tween.tween_property(self, "_boost", 1.8, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "_boost", 1.0, 0.6).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	var blade_box := Vector3(blade_width * 0.5, _blade_length() * 0.5, blade_thickness * 0.5)
	var frame : Transform3D = global_transform * _blade_frame(0.5)
	# Ball of flames bursting out of the whole blade.
	var blast := _make_burst(frame, blade_box, 90, 0.6, 0.05, 0.3, 0.9, 180.0, Vector3(0.0, 1.0, 0.0), 3.0, _flame_ramp)
	_add_flash(blast, 3.0, 1.5, 0.5, Vector3.ZERO)
	# Sparks flying everywhere.
	_make_burst(frame, blade_box, 40, 0.8, 0.006, 0.5, 1.5, 180.0, Vector3(0.0, -1.0, 0.0), 1.0, _ember_ramp)

	print("Sword ignited!")
	ignited.emit()


func _update_visuals() -> void:
	var flicker : float = _noise.get_noise_1d(_time * 10.0)
	var total_heat : float = 0.0

	for i in segment_count:
		var heat : float = _heat[i]
		total_heat += heat
		var size : float
		if state == State.IGNITED:
			size = 1.3 * _boost
		else:
			# Small flames as soon as it warms up, full size when ignited.
			size = 0.3 + 0.7 * heat
		_flames[i].emitting = heat > 0.02
		_flames[i].scale_amount_min = 0.7 * size
		_flames[i].scale_amount_max = 1.2 * size

	_embers.emitting = state == State.CHARGED or state == State.IGNITED

	var average_heat : float = total_heat / segment_count
	var energy : float = 1.2 * _boost if state == State.IGNITED else 0.6 * average_heat
	_light.light_energy = energy * (1.0 + 0.3 * flicker)


## Small pop of fire when one part of the blade ignites.
func _segment_pop(i : int) -> void:
	var frame : Transform3D = global_transform * _blade_frame((i + 0.5) / segment_count)
	var box := Vector3(blade_width * 0.5, _blade_length() / segment_count * 0.5, blade_thickness * 0.5)
	_make_burst(frame, box, 10, 0.3, 0.03, 0.1, 0.3, 180.0, Vector3(0.0, 0.8, 0.0), 2.0, _flame_ramp)


# ---- Blade geometry ---------------------------------------------------------

func _blade_length() -> float:
	return blade_start.distance_to(blade_end)


## Transform (in our local space) at a fraction t of the blade (0 = bottom,
## 1 = tip), with its Y axis along the blade.
func _blade_frame(t : float) -> Transform3D:
	var axis : Vector3 = (blade_end - blade_start).normalized()
	var blade_basis := Basis(Quaternion(Vector3.UP, axis)) if not axis.is_equal_approx(Vector3.UP) else Basis()
	return Transform3D(blade_basis, blade_start.lerp(blade_end, t))


# ---- Effect building blocks (same technique as HandOrb) ---------------------

## One-shot burst emitted from a box, in world space, deleted afterwards.
func _make_burst(frame : Transform3D, box_extents : Vector3, amount : int, lifetime : float,
		size : float, velocity_min : float, velocity_max : float, spread : float,
		gravity : Vector3, damping : float, color_ramp : Gradient) -> CPUParticles3D:
	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.explosiveness = 0.9
	burst.amount = amount
	burst.lifetime = lifetime
	burst.local_coords = false
	burst.mesh = _make_particle_mesh(size)
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	burst.emission_box_extents = box_extents
	burst.direction = Vector3.UP
	burst.spread = spread
	burst.initial_velocity_min = velocity_min
	burst.initial_velocity_max = velocity_max
	burst.damping_min = damping
	burst.damping_max = damping * 1.3
	burst.gravity = gravity
	burst.scale_amount_curve = _make_curve([ Vector2(0.0, 1.0), Vector2(1.0, 0.2) ])
	burst.color_ramp = color_ramp
	get_tree().current_scene.add_child(burst)
	burst.global_transform = frame
	burst.emitting = true
	get_tree().create_timer(lifetime + 0.5).timeout.connect(burst.queue_free)
	return burst


func _add_flash(parent : Node3D, energy : float, light_range : float, duration : float, local_pos : Vector3) -> void:
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.5, 0.15)
	flash.omni_range = light_range
	flash.light_energy = energy
	parent.add_child(flash)
	flash.position = local_pos
	flash.create_tween().tween_property(flash, "light_energy", 0.0, duration)


func _get_soft_texture() -> GradientTexture2D:
	if not _soft_texture:
		_soft_texture = GradientTexture2D.new()
		_soft_texture.gradient = _make_gradient([ Color(1, 1, 1, 1), Color(1, 1, 1, 0) ], [ 0.0, 1.0 ])
		_soft_texture.fill = GradientTexture2D.FILL_RADIAL
		_soft_texture.fill_from = Vector2(0.5, 0.5)
		_soft_texture.fill_to = Vector2(0.5, 0.0)
		_soft_texture.width = 64
		_soft_texture.height = 64
	return _soft_texture


## Camera-facing additive quad coloured by the particle colour ramp.
func _make_particle_mesh(size : float) -> QuadMesh:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_texture = _get_soft_texture()
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
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
