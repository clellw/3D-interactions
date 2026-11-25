extends Node3D

@export var xr_camera:XRCamera3D

@export_enum("Left", "Right") var hand : int = 1

@onready var mic_player: AudioStreamPlayer = $AudioStreamPlayer
@onready var mic_bus_idx: int = AudioServer.get_bus_index("Mic")
@export var blow_threshold_db: float = -40.0 # Blowing is usually much louder than talking
@export var particle_forward_local: Vector3 = Vector3(0.0, 0.0, -1.0)
@onready var frost_breath: Node3D = $FrostBreath
var spectrum: AudioEffectSpectrumAnalyzerInstance
@onready var blow_magic_circle: Node3D = $BlowMagicCircle

signal spell_activated(activated:bool)

func _ready() -> void:
	get_tree().on_request_permissions_result.connect(_on_permission_result)

	if mic_bus_idx == -1:
		push_warning("The 'Mic' audio bus does not exist")

	# Wait for OpenXR session focus so Horizon OS doesn't swallow the popup
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		xr_interface.session_begun.connect(_on_xr_session_begun)
	else:
		request_mic_access()
	#spectrum = AudioServer.get_bus_effect_instance(mic_bus_idx, 0)

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
		_start_microphone()


func _on_permission_result(permission: String, granted: bool) -> void:
	print("Permission callback -> ", permission, " : ", granted)
	if permission == "android.permission.RECORD_AUDIO":
		if granted:
			_start_microphone()
		else:
			push_warning("Microphone permission denied by user in headset.")


func _start_microphone() -> void:
	if mic_player.stream is AudioStreamMicrophone and not mic_player.playing:
		mic_player.play()



func _physics_process(delta: float) -> void:
	var peak_db := -80.0
	if mic_bus_idx >= 0:
		peak_db = AudioServer.get_bus_peak_volume_left_db(mic_bus_idx, 0)

	var detected := is_ok_gesture(hand)


	if detected:
		var blow_origin := get_ok_circle_midpoint(hand)
		blow_magic_circle.visible = true
		blow_magic_circle.global_position = blow_origin + Vector3(-0.02,0.025,0.025)
		blow_magic_circle.global_rotation = xr_camera.global_rotation
		frost_breath.global_position = blow_origin
		frost_breath.global_rotation = xr_camera.global_rotation
			
		if peak_db >= blow_threshold_db:
			spell_activated.emit(true)
		else:
			spell_activated.emit(false)
	else:
		blow_magic_circle.visible = false
		spell_activated.emit(false)


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


	
