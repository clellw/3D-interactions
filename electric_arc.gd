
extends Node3D

@export var start_point := Vector3.ZERO
@export var end_point := Vector3(0, 0, -2)
@export var segments := 7
@export var jitter := 0.09
@export var thickness := 0.003
@export var update_rate := 0.04

@export var material_color: Color

var timer := 0.0
var arc_root: Node3D

func _ready():
	randomize()

	arc_root = Node3D.new()
	add_child(arc_root)

	generate_arc()

func _process(delta):
	timer += delta

	if timer >= update_rate:
		timer = 0.0
		generate_arc()

func generate_arc():
	for child in arc_root.get_children():
		child.queue_free()

	var points: Array[Vector3] = []

	for i in range(segments + 1):
		var t := float(i) / segments
		var p := start_point.lerp(end_point, t)

		if i > 0 and i < segments:
			p += Vector3(
				randf_range(-jitter, jitter),
				randf_range(-jitter, jitter),
				randf_range(-jitter, jitter)
			)

		points.append(p)

	for i in range(segments):
		create_bolt_segment(points[i], points[i + 1])

func create_bolt_segment(a: Vector3, b: Vector3):
	var direction := b - a
	var length := direction.length()

	if length < 0.001:
		return

	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()

	cylinder.top_radius = thickness
	cylinder.bottom_radius = thickness
	cylinder.height = length
	cylinder.radial_segments = 5

	mesh_instance.mesh = cylinder

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = material_color
	material.emission_enabled = true
	material.emission = Color(0.102, 0.31, 1.0, 1.0)
	material.emission_energy_multiplier = 5.0

	mesh_instance.material_override = material

	arc_root.add_child(mesh_instance)

	mesh_instance.position = (a + b) / 2.0
	mesh_instance.quaternion = Quaternion(
	Vector3.UP,
	direction.normalized()
)

func set_endpoints(global_a: Vector3, global_b: Vector3):
	# Conversion des positions globales en positions locales
	start_point = to_local(global_a)
	end_point = to_local(global_b)

	# Régénération de l'éclair
	generate_arc()
