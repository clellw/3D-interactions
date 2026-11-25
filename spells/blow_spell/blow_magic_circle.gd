extends Node3D

@onready var outer_circle: MeshInstance3D = $OuterCircle
@onready var inner_circle: MeshInstance3D = $InnerCircle

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta: float) -> void:
	outer_circle.rotate_object_local(Vector3.UP, PI * delta)
	inner_circle.rotate_object_local(Vector3.UP, -PI * 0.5 * delta)
