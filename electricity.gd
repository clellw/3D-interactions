
extends Node3D

@export var left_palm: XRNode3D
@export var right_palm: XRNode3D

@export var electric_arc: Node3D
@export var electric_arc_big: Node3D
@export var electric_particles: GPUParticles3D

@export var activation_distance := 0.10
@export var deactivation_distance := 0.60

var electricity_active := false

func _ready():
	electric_arc.visible = false
	electric_arc_big.visible = false
	electric_particles.emitting = false

func _process(_delta):

	if left_palm == null or right_palm == null:
		return

	var left_position = left_palm.global_position
	var right_position = right_palm.global_position

	var distance = left_position.distance_to(right_position)

	# Activation de l'électricité
	if not electricity_active and distance < activation_distance:
		activate_electricity()

	# Désactivation avec une petite marge
	elif electricity_active and distance > deactivation_distance:
		deactivate_electricity()

	# Mise à jour des extrémités de l'éclair
	if electricity_active:
		electric_arc.set_endpoints(
			left_position,
			right_position
		)
		electric_arc_big.set_endpoints(
			left_position,
			right_position
		)

func activate_electricity():
	electricity_active = true

	electric_arc.visible = true
	electric_arc_big.visible = true
	electric_particles.emitting = true

func deactivate_electricity():
	electricity_active = false

	electric_arc.visible = false
	electric_arc_big.visible = false
	electric_particles.emitting = false
