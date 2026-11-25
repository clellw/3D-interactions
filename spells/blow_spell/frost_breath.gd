extends Node3D


const FROST_DECAL = preload("uid://djql75yq5c5n2")
@onready var ray_cast_3d: RayCast3D = $RayCast3D
@onready var snow_particles: GPUParticles3D = $SnowParticles
@onready var ice_particles: GPUParticles3D = $IceParticles

@export var decal_cd: float = 0.12
var can_decal = true
var decal_timer:Timer

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	decal_timer = Timer.new()
	add_child(decal_timer)
	decal_timer.wait_time = decal_cd
	decal_timer.one_shot = true
	decal_timer.autostart = false
	decal_timer.timeout.connect(_on_decal_timer_timeout)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	if ray_cast_3d.is_colliding() and can_decal:
		_spawn_decal(ray_cast_3d.get_collision_point())
		can_decal = false
		decal_timer.start()
		
		
func _spawn_decal(hit_point: Vector3) -> void:
	var hit_normal: Vector3 = ray_cast_3d.get_collision_normal()
	var frost_decal_instance: Decal = FROST_DECAL.instantiate()
	get_tree().current_scene.add_child(frost_decal_instance)
	
	frost_decal_instance.global_position = hit_point
	
	# 1. Align the decal's local +Y axis with the surface normal
	frost_decal_instance.global_basis = Basis(Quaternion(Vector3.UP, hit_normal))
	
	# 2. Rotate locally around the normal (local Y) for variety
	frost_decal_instance.rotate_object_local(Vector3.UP, randf_range(0, TAU))
	
	# 3. Apply random scale
	var rand_scale := randf_range(0.5, 1.0)
	frost_decal_instance.scale = Vector3(rand_scale, 1.0, rand_scale)


func _on_blow_magic_spell_activated(activated: bool) -> void:
	snow_particles.emitting = activated
	ice_particles.emitting = activated


func _on_decal_timer_timeout() -> void:
	can_decal = true
