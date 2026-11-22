extends Node3D

@export var xr_camera:XRCamera3D

@export_enum("Left", "Right") var hand : int = 1

@onready var feedback : Node3D = $Feedback
@onready var label: Label3D = $Feedback/Label
@onready var mic_player: AudioStreamPlayer = $AudioStreamPlayer
@onready var mic_status: Label3D = $MicStatus
@onready var mic_bus_idx: int = AudioServer.get_bus_index("Mic")
@export var blow_threshold_db: float = -40.0 # Blowing is usually much louder than talking
@export var particle_forward_local: Vector3 = Vector3(0.0, 0.0, -1.0)
@onready var fire_particles: GPUParticles3D = $FireParticles
var spectrum: AudioEffectSpectrumAnalyzerInstance


func _ready() -> void:
	get_tree().on_request_permissions_result.connect(_on_permission_result)

	if mic_bus_idx == -1:
		push_warning("The 'Mic' audio bus does not exist")

	var particle_material := fire_particles.process_material as ParticleProcessMaterial
	if particle_material:
		particle_material.direction = particle_forward_local

	var camera := get_node_or_null("../XROrigin3D/XRCamera3D")
	if camera:
		mic_status.reparent(camera)
		mic_status.position = Vector3(0.0, -0.18, -0.8)

	# Wait for OpenXR session focus so Horizon OS doesn't swallow the popup
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		xr_interface.session_begun.connect(_on_xr_session_begun)
	else:
		request_mic_access()
	spectrum = AudioServer.get_bus_effect_instance(mic_bus_idx, 0)

	# Uncomment to calibrate values in your Output log:
	# print("Low: %.4f | Voice: %.4f | Ratio: %.2f | Blowing: %s" % [low_rumble, voice_band, ratio, is_blowing])

func _on_xr_session_begun() -> void:
	await get_tree().create_timer(1.0).timeout
	request_mic_access()


func request_mic_access() -> void:
	if OS.get_name() == "Android":
		var granted := OS.request_permission("android.permission.RECORD_AUDIO")
		print("RECORD_AUDIO already granted: ", granted)
		if granted:
			_start_microphone()
		else:
			mic_status.text = "Waiting for Mic Permission..."
	else:
		_start_microphone()


func _on_permission_result(permission: String, granted: bool) -> void:
	print("Permission callback -> ", permission, " : ", granted)
	if permission == "android.permission.RECORD_AUDIO":
		if granted:
			_start_microphone()
		else:
			mic_status.text = "Mic Permission DENIED"
			push_warning("Microphone permission denied by user in headset.")


func _start_microphone() -> void:
	if mic_player.stream is AudioStreamMicrophone and not mic_player.playing:
		mic_player.play()



func _process(delta: float) -> void:
	var peak_db := -80.0
	if mic_bus_idx >= 0:
		peak_db = AudioServer.get_bus_peak_volume_left_db(mic_bus_idx, 0)

	mic_status.text = "Mic: %.1f dB" % peak_db
	var detected := is_ok_gesture(hand)
	feedback.visible = detected
	
	# 1. Measure wind/turbulence rumble (20 Hz - 120 Hz)
	#var low_rumble = spectrum.get_magnitude_for_frequency_range(20.0, 120.0).length()
	#
	## 2. Measure human vocal range (300 Hz - 2500 Hz)
	#var voice_band = spectrum.get_magnitude_for_frequency_range(300.0, 2500.0).length()
#
	## 3. Check if low rumble dominates over vocal frequencies
	#var ratio = low_rumble / max(voice_band, 0.0001)

	if detected and peak_db >= blow_threshold_db:
		var blow_origin := get_ok_circle_midpoint(hand)
		#var blow_direction := get_ok_circle_normal(hand, blow_origin)
		feedback.global_position = blow_origin
		label.text = " OK | Mic: %.1f dB" % peak_db 
		var pulse := 1.0 + sin(Time.get_ticks_msec() * 0.012) * 0.12
		feedback.scale = Vector3.ONE * pulse
		fire_particles.emitting = true
		fire_particles.global_position = blow_origin
		fire_particles.global_rotation = xr_camera.global_rotation
			
	else:
		fire_particles.emitting = false


func get_ok_circle_midpoint(hand_index: int) -> Vector3:
	var tracker_path := &"/user/hand_tracker/left" \
		if hand_index == 0 else &"/user/hand_tracker/right"
	var tracker: XRHandTracker = XRServer.get_tracker(tracker_path)

	if not tracker:
		return Vector3.ZERO

	var thumb_tip := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_THUMB_TIP
	).origin
	var index_metacarpal := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL
	).origin

	return thumb_tip.lerp(index_metacarpal, 0.5)


func get_ok_circle_normal(hand_index: int, circle_center: Vector3) -> Vector3:
	var tracker_path := &"/user/hand_tracker/left" \
		if hand_index == 0 else &"/user/hand_tracker/right"
	var tracker: XRHandTracker = XRServer.get_tracker(tracker_path)

	if not tracker or not tracker.has_tracking_data:
		return Vector3.ZERO

	var thumb_tip := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_THUMB_TIP
	).origin
	var index_tip := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	).origin
	var index_metacarpal := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL
	).origin

	# The three points describe the plane of the OK opening.
	var thumb_edge := thumb_tip - circle_center
	var index_edge := index_tip - circle_center
	var knuckle_edge := index_metacarpal - circle_center
	var normal := thumb_edge.cross(index_edge)
	if normal.length_squared() < 0.000001:
		normal = thumb_edge.cross(knuckle_edge)
	if normal == Vector3.ZERO:
		return Vector3.ZERO

	var camera := get_viewport().get_camera_3d()
	if camera:
		var toward_camera := camera.global_position - circle_center
		if toward_camera.dot(normal) < 0.0:
			normal = -normal

	return normal.normalized()


func is_ok_gesture(hand: int) -> bool:
	var tracker_path := &"/user/hand_tracker/left" \
		if hand == 0 else &"/user/hand_tracker/right"

	var tracker: XRHandTracker = XRServer.get_tracker(tracker_path)
	if not tracker or not tracker.has_tracking_data:
		return false

	var wrist := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_WRIST
	).origin

	var thumb_tip := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_THUMB_TIP
	).origin

	var index_tip := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	).origin

	var middle_metacarpal := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL
	).origin

	# Relative scale makes the threshold independent of hand size.
	var hand_size := wrist.distance_to(middle_metacarpal)
	var thumb_index_distance := thumb_tip.distance_to(index_tip)

	# 25% of hand length; adjust after testing on your headset.
	return thumb_index_distance < hand_size * 0.25


	
