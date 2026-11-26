class_name BigFireball
extends Node3D

## The big fireball created by clapping two small fireballs together
## (see FireballClap, which creates and controls it).
##
## HELD     : FireballClap calls hold() every frame with the point between the
##            palms and a radius that depends on how far apart the hands are.
##            The ball glides there and grows / shrinks smoothly.
## FLYING   : after launch(): straight line, explodes on the first thing it
##            touches (or after max_flight_time, in the air).
## FIZZLING : after fizzle() (hands lost / pulled too far apart): shrinks,
##            puffs out in smoke, and disappears.
##
## The explosion pushes away every rigid body within explosion_radius.

signal launched(direction : Vector3)
signal exploded(global_pos : Vector3)

enum State { HELD, FLYING, FIZZLING }

## Radius the visuals are designed for; everything is scaled from it.
const BASE_RADIUS : float = 0.05

## Flight speed in m/s once launched (big and slow-ish, it should feel heavy).
@export var flight_speed : float = 5.0
## Explodes by itself after this many seconds if it hits nothing.
@export var max_flight_time : float = 5.0
## Bodies within this distance of the explosion are pushed away.
@export var explosion_radius : float = 1.2
## Push given to a body right at the centre of the explosion (less further away).
@export var explosion_impulse : float = 6.0

var state : State = State.HELD
var radius : float = 0.0          # current radius, smoothed towards _target_radius

var _target_position : Vector3
var _target_radius : float = 0.04
var _has_target : bool = false
var _velocity : Vector3
var _flight_time : float = 0.0
var _time : float = 0.0
var _boost : float = 0.0          # spawn "pop" (tween): 0 -> 1.6 -> 1
var _fade : float = 1.0           # 1 -> 0 when fizzling

var _core : MeshInstance3D
var _glow : MeshInstance3D
var _flames : CPUParticles3D
var _swirl : CPUParticles3D
var _embers : CPUParticles3D
var _light : OmniLight3D
var _noise := FastNoiseLite.new()


func _ready() -> void:
	_noise.frequency = 1.0
	_noise.seed = randi()

	# Same recipe as the small fireball, bigger and denser.
	_core = FireFX.billboard(BASE_RADIUS * 2.2, Color(1.0, 0.95, 0.75, 1.0))
	add_child(_core)
	_glow = FireFX.billboard(BASE_RADIUS * 5.5, Color(1.0, 0.4, 0.08, 0.4))
	add_child(_glow)

	# Main flames: rise from the whole ball.
	_flames = FireFX.flame_emitter(90, 0.55, BASE_RADIUS * 1.6, BASE_RADIUS * 0.7)
	add_child(_flames)

	# "Swirl": flames that are pulled back towards the centre (negative radial
	# acceleration), which makes the ball look like a churning sphere of fire
	# instead of a campfire.
	_swirl = FireFX.flame_emitter(50, 0.45, BASE_RADIUS * 1.1, BASE_RADIUS * 1.1)
	_swirl.spread = 180.0
	_swirl.gravity = Vector3.ZERO
	_swirl.initial_velocity_min = 0.1
	_swirl.initial_velocity_max = 0.2
	_swirl.radial_accel_min = -1.5
	_swirl.radial_accel_max = -0.8
	_swirl.tangential_accel_min = 0.5
	_swirl.tangential_accel_max = 1.0
	add_child(_swirl)

	_embers = CPUParticles3D.new()
	_embers.amount = 20
	_embers.lifetime = 1.0
	_embers.local_coords = false
	_embers.mesh = FireFX.particle_mesh(BASE_RADIUS * 0.15)
	_embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_embers.emission_sphere_radius = BASE_RADIUS
	_embers.direction = Vector3.UP
	_embers.spread = 60.0
	_embers.initial_velocity_min = 0.15
	_embers.initial_velocity_max = 0.4
	_embers.gravity = Vector3(0.0, 0.3, 0.0)
	_embers.color_ramp = FireFX.ember_ramp()
	add_child(_embers)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.5, 0.15)
	_light.omni_range = 1.0
	add_child(_light)

	# Spawn pop: overshoot then elastic settle, like the small fireball.
	var tween := create_tween()
	tween.tween_property(self, "_boost", 1.6, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "_boost", 1.0, 0.6).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	_update_visuals()


## Called every frame by FireballClap while the ball is between the hands.
func hold(target_position : Vector3, target_radius : float) -> void:
	if state != State.HELD:
		return
	if not _has_target:
		# First call: appear right there instead of gliding from the origin.
		global_position = target_position
		_has_target = true
	_target_position = target_position
	_target_radius = target_radius


## Throws the ball. speed <= 0 means flight_speed.
func launch(direction : Vector3, speed : float = -1.0) -> void:
	if state != State.HELD:
		return
	state = State.FLYING
	_velocity = direction.normalized() * (speed if speed > 0.0 else flight_speed)
	_flight_time = 0.0
	print("Big fireball launched")
	launched.emit(direction)


func fizzle() -> void:
	if state != State.HELD:
		return
	state = State.FIZZLING
	FireFX.burst(get_parent(), global_transform, 14, 1.2, radius * 3.0, 0.05, 0.2, 60.0,
		Vector3(0.0, 0.3, 0.0), 0.5, FireFX.smoke_ramp(), false)


func is_held() -> bool:
	return state == State.HELD


func _process(delta : float) -> void:
	_time += delta

	match state:
		State.HELD:
			global_position = global_position.lerp(_target_position, 1.0 - exp(-20.0 * delta))
			radius = lerp(radius, _target_radius, 1.0 - exp(-10.0 * delta))
		State.FIZZLING:
			_fade = move_toward(_fade, 0.0, delta / 0.4)
			if _fade <= 0.0:
				queue_free()
				return

	_update_visuals()


func _physics_process(delta : float) -> void:
	if state != State.FLYING:
		return

	_flight_time += delta
	var from : Vector3 = global_position
	var step : Vector3 = _velocity * delta
	# Ray a little longer than the step, by the ball's radius, so it explodes
	# when its surface touches something, not its centre.
	var to : Vector3 = from + step + _velocity.normalized() * radius
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit : Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_explode(hit.position)
		return

	global_position = from + step
	if _flight_time > max_flight_time:
		_explode(global_position)


func _update_visuals() -> void:
	var size : float = max(radius / BASE_RADIUS, 0.001) * _boost * _fade
	var flicker : float = _noise.get_noise_1d(_time * 10.0)

	_core.scale = Vector3.ONE * max(size * (1.0 + 0.1 * flicker), 0.001)
	_glow.scale = Vector3.ONE * max(size * (1.0 + 0.2 * _noise.get_noise_1d(_time * 6.0 + 50.0)), 0.001)

	_flames.scale_amount_min = 0.7 * size
	_flames.scale_amount_max = 1.2 * size
	_flames.emission_sphere_radius = BASE_RADIUS * 0.7 * size
	_swirl.scale_amount_min = 0.6 * size
	_swirl.scale_amount_max = 1.0 * size
	_swirl.emission_sphere_radius = BASE_RADIUS * 1.1 * size
	_embers.emission_sphere_radius = BASE_RADIUS * size

	var burning : bool = state != State.FIZZLING and size > 0.05
	_flames.emitting = burning
	_swirl.emitting = burning
	_embers.emitting = burning

	_light.omni_range = 0.6 + size * 0.6
	_light.light_energy = 1.0 * size * (1.0 + 0.3 * flicker)


## Big explosion: fire, a ring shockwave, sparks, smoke, a strong flash, and
## a push on every rigid body around.
func _explode(at : Vector3) -> void:
	var parent : Node = get_parent()
	var frame := Transform3D(Basis(), at)
	var size : float = max(radius / BASE_RADIUS, 1.0)

	# Fireball.
	var blast := FireFX.burst(parent, frame, 160, 0.8, BASE_RADIUS * 2.5 * size, 1.0, 3.0, 180.0,
		Vector3(0.0, 1.0, 0.0), 3.5, FireFX.flame_ramp())
	FireFX.flash(blast, 6.0, 3.0 * size, 0.6)
	# Sparks flying far and falling.
	FireFX.burst(parent, frame, 60, 1.2, BASE_RADIUS * 0.2, 2.0, 5.0, 180.0,
		Vector3(0.0, -3.0, 0.0), 1.0, FireFX.ember_ramp())
	# Rising smoke.
	var smoke := FireFX.burst(parent, frame, 30, 2.0, BASE_RADIUS * 5.0 * size, 0.2, 0.6, 180.0,
		Vector3(0.0, 0.4, 0.0), 1.5, FireFX.smoke_ramp(), false)
	smoke.explosiveness = 0.6
	smoke.scale_amount_curve = FireFX.curve([ Vector2(0.0, 0.3), Vector2(1.0, 1.0) ])

	_push_bodies(at)

	print("Big fireball exploded")
	exploded.emit(at)
	queue_free()


## Pushes every unfrozen rigid body within explosion_radius away from the
## centre, stronger when closer. A ball grown bigger than the normal maximum
## (e.g. over a finger) has a proportionally bigger and stronger explosion.
func _push_bodies(at : Vector3) -> void:
	var growth : float = max(1.0, radius / 0.12)
	var blast_radius : float = explosion_radius * growth
	var sphere := SphereShape3D.new()
	sphere.radius = blast_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis(), at)
	query.collide_with_bodies = true

	var results : Array[Dictionary] = get_world_3d().direct_space_state.intersect_shape(query, 32)
	var pushed : Array = []
	for result in results:
		var body = result.collider
		if not (body is RigidBody3D) or body.freeze or pushed.has(body):
			continue
		pushed.append(body)
		var away : Vector3 = body.global_position - at
		var distance : float = away.length()
		var strength : float = explosion_impulse * growth * clamp(1.0 - distance / blast_radius, 0.0, 1.0)
		# Push away from the centre, a bit upwards so things get lifted.
		var direction : Vector3 = (away.normalized() if distance > 0.01 else Vector3.UP) + Vector3.UP * 0.4
		body.apply_central_impulse(direction.normalized() * strength)
