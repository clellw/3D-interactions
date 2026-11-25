extends Decal

@export var decal_time: float = 2.0
var timer: Timer

func _ready() -> void:
	timer = Timer.new()
	timer.wait_time = max(decal_time, 0.01) 
	timer.one_shot = true
	timer.autostart = true
	timer.timeout.connect(queue_free)
	add_child(timer)

func _process(_delta: float) -> void:
	if timer and timer.time_left > 0.0:
		albedo_mix = timer.time_left / decal_time
