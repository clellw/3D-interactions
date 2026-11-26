class_name FireFX
extends RefCounted

## Shared toolbox to build fire effects in code (no texture or scene needed).
## Used by BigFireball and FireballClap. (HandOrb and SwordFire contain their
## own copy of the same technique.)
##
## The technique:
## - Every piece of fire is a camera-facing quad (billboard) with a soft round
##   texture, drawn with ADDITIVE blending: overlapping pieces add their light,
##   which is what makes fire look bright and hot.
## - Particles are emitted in world space (local_coords = false) so they stay
##   behind when the emitter moves (trails), and rise with negative gravity.
## - Colour ramps go yellow -> orange -> red -> transparent over each particle's
##   life; smoke uses normal blending (it darkens instead of adding light).

static var _soft_texture : GradientTexture2D


## Soft round texture: opaque white in the centre, transparent at the edge.
static func soft_texture() -> GradientTexture2D:
	if not _soft_texture:
		_soft_texture = GradientTexture2D.new()
		_soft_texture.gradient = gradient([ Color(1, 1, 1, 1), Color(1, 1, 1, 0) ], [ 0.0, 1.0 ])
		_soft_texture.fill = GradientTexture2D.FILL_RADIAL
		_soft_texture.fill_from = Vector2(0.5, 0.5)
		_soft_texture.fill_to = Vector2(0.5, 0.0)
		_soft_texture.width = 64
		_soft_texture.height = 64
	return _soft_texture


static func material(billboard_mode : BaseMaterial3D.BillboardMode, additive : bool = true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.albedo_texture = soft_texture()
	mat.billboard_mode = billboard_mode
	mat.billboard_keep_scale = true
	return mat


## A single camera-facing glowing quad.
static func billboard(size : float, tint : Color) -> MeshInstance3D:
	var mat := material(BaseMaterial3D.BILLBOARD_ENABLED)
	mat.albedo_color = tint
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = mat
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = quad
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh_instance


## Quad for particles; its colour comes from the particle colour ramp.
static func particle_mesh(size : float, additive : bool = true) -> QuadMesh:
	var mat := material(BaseMaterial3D.BILLBOARD_PARTICLES, additive)
	mat.vertex_color_use_as_albedo = true
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = mat
	return quad


static func gradient(colors : Array, offsets : Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	return g


static func curve(points : Array) -> Curve:
	var c := Curve.new()
	for point in points:
		c.add_point(point)
	return c


static func flame_ramp() -> Gradient:
	return gradient(
		[ Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.5, 0.1, 0.8), Color(0.7, 0.12, 0.05, 0.4), Color(0.2, 0.05, 0.05, 0.0) ],
		[ 0.0, 0.3, 0.7, 1.0 ])


static func ember_ramp() -> Gradient:
	return gradient(
		[ Color(1.0, 0.95, 0.6, 1.0), Color(1.0, 0.5, 0.1, 0.9), Color(1.0, 0.3, 0.05, 0.0) ],
		[ 0.0, 0.5, 1.0 ])


static func smoke_ramp() -> Gradient:
	return gradient(
		[ Color(0.25, 0.22, 0.2, 0.35), Color(0.3, 0.3, 0.3, 0.2), Color(0.35, 0.35, 0.35, 0.0) ],
		[ 0.0, 0.5, 1.0 ])


## Continuous flame emitter (not one-shot). Add it as a child of something.
static func flame_emitter(amount : int, lifetime : float, size : float, emission_radius : float) -> CPUParticles3D:
	var flames := CPUParticles3D.new()
	flames.amount = amount
	flames.lifetime = lifetime
	flames.local_coords = false
	flames.mesh = particle_mesh(size)
	flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	flames.emission_sphere_radius = emission_radius
	flames.direction = Vector3.UP
	flames.spread = 20.0
	flames.initial_velocity_min = 0.05
	flames.initial_velocity_max = 0.15
	flames.gravity = Vector3(0.0, 0.6, 0.0)
	flames.scale_amount_curve = curve([ Vector2(0.0, 0.6), Vector2(0.25, 1.0), Vector2(1.0, 0.1) ])
	flames.color_ramp = flame_ramp()
	return flames


## One-shot burst at `frame` (world transform), added to `parent`, deleted
## automatically once its particles are gone. Emits from a point, or from a
## box if box_extents isn't zero.
static func burst(parent : Node, frame : Transform3D, amount : int, lifetime : float, size : float,
		velocity_min : float, velocity_max : float, spread : float, gravity : Vector3,
		damping : float, ramp : Gradient, additive : bool = true,
		box_extents : Vector3 = Vector3.ZERO) -> CPUParticles3D:
	var b := CPUParticles3D.new()
	b.one_shot = true
	b.explosiveness = 0.9
	b.amount = amount
	b.lifetime = lifetime
	b.local_coords = false
	b.mesh = particle_mesh(size, additive)
	if box_extents != Vector3.ZERO:
		b.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		b.emission_box_extents = box_extents
	b.direction = Vector3.UP
	b.spread = spread
	b.initial_velocity_min = velocity_min
	b.initial_velocity_max = velocity_max
	b.damping_min = damping
	b.damping_max = damping * 1.3
	b.gravity = gravity
	b.scale_amount_curve = curve([ Vector2(0.0, 1.0), Vector2(1.0, 0.2) ])
	b.color_ramp = ramp
	parent.add_child(b)
	b.global_transform = frame
	b.emitting = true
	b.get_tree().create_timer(lifetime + 0.5).timeout.connect(b.queue_free)
	return b


## Short flash of light that fades out, added as a child of `parent`.
static func flash(parent : Node3D, energy : float, light_range : float, duration : float) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.5, 0.15)
	light.omni_range = light_range
	light.light_energy = energy
	parent.add_child(light)
	light.create_tween().tween_property(light, "light_energy", 0.0, duration)
