@tool
extends Node

## Flags for plane_tracker_get_all_plane_ids() — OR values together to select which planes to include.
enum PlaneFilter {
	INCLUDE_TRACKING = 1,  ## planes ARCore is actively tracking
	INCLUDE_PAUSED   = 2,  ## planes temporarily not tracking (stale transform)
	INCLUDE_STOPPED  = 4,  ## planes ARCore permanently abandoned
	INCLUDE_SUBSUMED = 8,  ## planes absorbed into a larger sibling plane
}

## How much of the per-frame AR pipeline runs. Mirrors ARCoreInterface::ARSessionState (C++).
## Used to freeze the AR view ("inspect mode") so the user can interact with / orbit the
## currently visible content.
enum ARSessionState {
	AR_SESSION_RUNNING = 0,  ## normal AR: pose + displayed feed updated every frame
	AR_SESSION_FROZEN,       ## view held still (pose + feed frozen), but ARCore keeps tracking/detecting
	AR_SESSION_FULLY_PAUSED, ## ArSession_pause(): camera + tracking stopped entirely (saves power)
}

# Signals emitted by the C++ ARCoreInterface
signal qr_code_found(data: String, format: String)
signal qr_code_lost(data: String)

# This is the autoload that is set up when enabling the plugin
# It also communicates between ARCore and Godot
var arcore_interface  # ARCoreInterface — only available on Android at runtime

func _enter_tree():
	if not ClassDB.class_exists("ARCoreInterface"):
		return
	arcore_interface = ClassDB.instantiate("ARCoreInterface")
	if arcore_interface:
		XRServer.add_interface(arcore_interface)
		# Forward QR signals from the native interface through this autoload wrapper.
		arcore_interface.qr_code_found.connect(func(d, f): qr_code_found.emit(d, f))
		arcore_interface.qr_code_lost.connect(func(d): qr_code_lost.emit(d))

func _exit_tree():
	if arcore_interface:
		XRServer.remove_interface(arcore_interface)
		arcore_interface = null

func get_interface():
	return arcore_interface

## Set the AR session state (see [enum ARSessionState]). Pass an ARSessionState value.
func set_ar_session_state(state: int) -> void:
	if arcore_interface:
		arcore_interface.set_ar_session_state(state)

## Returns the current AR session state (see [enum ARSessionState]).
func get_ar_session_state() -> int:
	if arcore_interface:
		return arcore_interface.get_ar_session_state()
	return ARSessionState.AR_SESSION_RUNNING

## True when the AR view is frozen for inspection (FROZEN or FULLY_PAUSED). Tracked components
## should hold their last pose while this is true, so content doesn't move as the phone moves.
func is_ar_frozen() -> bool:
	return get_ar_session_state() != ARSessionState.AR_SESSION_RUNNING

## Convenience: freeze (true) or resume (false) the AR view for inspect mode.
## By default freezing uses AR_SESSION_FROZEN, which holds the view still but keeps ARCore
## running underneath (tracking, planes, QR) for a seamless resume. Pass full_pause = true
## to instead stop ARCore entirely (AR_SESSION_FULLY_PAUSED) when AR won't be needed for a while.
func set_ar_frozen(frozen: bool, full_pause: bool = false) -> void:
	if frozen:
		set_ar_session_state(ARSessionState.AR_SESSION_FULLY_PAUSED if full_pause else ARSessionState.AR_SESSION_FROZEN)
	else:
		set_ar_session_state(ARSessionState.AR_SESSION_RUNNING)

## Returns false if ARCore could not start (see get_last_error()); calling it again retries.
func start() -> bool:
	if not arcore_interface:
		# No native ARCore (e.g. desktop/editor) — skip XR so the rest of the app still runs
		# (lets non-AR features like object picking be tested off-device).
		print("[ARCore] Native interface unavailable; running without XR (AR features disabled).")
		return false
	if arcore_interface.initialize():
		get_viewport().use_xr = true
		return true
	return false

func get_last_error() -> String:
	return arcore_interface.get_last_error() if arcore_interface else "ARCore not available on this platform"

func get_tracking_status():
	return arcore_interface.get_tracking_status()

func enable_depth_estimation(toggled):
	if arcore_interface:
		arcore_interface.enable_depth_estimation(toggled)

func show_depth_map(toggled):
	if arcore_interface:
		arcore_interface.show_depth_map(toggled)

func set_max_depth_meters(value):
	if arcore_interface:
		arcore_interface.set_max_depth_meters(value)

func enable_vertical_plane_detection(toggled):
	if arcore_interface:
		arcore_interface.enable_vertical_plane_detection(toggled)

func enable_horizontal_plane_detection(toggled):
	if arcore_interface:
		arcore_interface.enable_horizontal_plane_detection(toggled)

func enable_images_detection(toggled):
	if arcore_interface:
		arcore_interface.enable_images_detection(toggled)

func track_nodes_to_images(dict: Dictionary):
	if arcore_interface:
		arcore_interface.set_node_images_mapping(dict)

func enable_instant_placement(toggled):
	if arcore_interface:
		arcore_interface.enable_instant_placement(toggled)

func enable_light_estimation(toggled):
	if arcore_interface:
		arcore_interface.enable_light_estimation(toggled)

func enable_point_cloud_detection(toggled):
	if arcore_interface:
		arcore_interface.enable_point_cloud_detection(toggled)

func switch_orientation(vertical):
	if arcore_interface:
		arcore_interface.switch_orientation(vertical)

func get_light_main_hdr_direction():
	if arcore_interface:
		return arcore_interface.get_light_main_hdr_direction()

func get_light_main_hdr_intensity():
	if arcore_interface:
		return arcore_interface.get_light_main_hdr_intensity()

func get_camera_feed():
	if arcore_interface:
		return arcore_interface.get_camera_feed()

func get_camera_rgba_texture():
	if arcore_interface:
		return arcore_interface.get_camera_rgba_texture()

func create_image_tracker_database():
	if arcore_interface:
		arcore_interface.image_tracker_database_create()

func get_image_tracker_database_serialized():
	if arcore_interface:
		return arcore_interface.image_tracker_database_get_serialized()

func load_image_tracker_database(bytes):
	if arcore_interface:
		arcore_interface.image_tracker_database_load(bytes)

func image_tracker_database_add_image(img: Image, identifier: String, physical_width: float = -1):
	if arcore_interface:
		arcore_interface.image_tracker_database_add_image(img, identifier, physical_width)

func image_tracker_get_tracked_transform(identifier: String):
	if arcore_interface:
		return arcore_interface.image_tracker_get_tracked_transform(identifier)

func image_tracker_get_tracking_status(identifier: String):
	if arcore_interface:
		return arcore_interface.image_tracker_get_image_tracking_status(identifier)

func raycast(ray_orig: Vector3, ray_dir: Vector3):
	if arcore_interface:
		return arcore_interface.getHitRayPose(ray_orig, ray_dir)

func screenRayCast(screen_x, screen_y):
	if arcore_interface:
		return arcore_interface.getHitPose(screen_x, screen_y)

## Vertical FOV (degrees) of ARCore's live rendering projection, or 0.0 when unavailable
## (desktop/editor, or before the first frame). Feed this into XRCamera3D.fov so project_ray_normal
## / object picking line up with the on-screen image (the XR projection bypasses Camera3D.fov).
func get_camera_fov() -> float:
	if arcore_interface:
		return arcore_interface.get_camera_fov()
	return 0.0

## The 4x4 rendering projection ARCore currently renders with (16 floats, column-major), or an
## empty array off-device. Unproject screen taps through this so object picking lines up with the
## on-screen image exactly (Camera3D's own projection is bypassed under XR). See ObjectPicker.
func get_projection_matrix() -> PackedFloat64Array:
	if arcore_interface:
		return arcore_interface.get_projection_matrix()
	return PackedFloat64Array()

func plane_tracker_get_all_plane_ids(flags: int = PlaneFilter.INCLUDE_TRACKING): #| PlaneFilter.INCLUDE_PAUSED
	if arcore_interface:
		return arcore_interface.plane_tracker_get_all_plane_ids(flags)
	return []

func plane_tracker_get_plane_boundary(plane_id):
	if arcore_interface:
		return arcore_interface.plane_tracker_get_plane_boundary(plane_id)

func plane_tracker_get_plane_transform(plane_id):
	if arcore_interface:
		return arcore_interface.plane_tracker_get_plane_transform(plane_id)

func plane_tracker_get_plane_parent(plane_id):
	if arcore_interface:
		return arcore_interface.plane_tracker_get_plane_parent(plane_id)

func qr_scanner_start():
	if arcore_interface:
		arcore_interface.qr_scanner_start()

func qr_scanner_stop():
	if arcore_interface:
		arcore_interface.qr_scanner_stop()

func qr_scanner_is_active() -> bool:
	if arcore_interface:
		return arcore_interface.qr_scanner_is_active()
	return false

## Scan every N-th frame (default 5). Scans run asynchronously, so a low value costs no frame time.
func qr_scanner_set_scan_interval(frames: int):
	if arcore_interface:
		arcore_interface.qr_scanner_set_scan_interval(frames)

## Seconds a code may be out of view before qr_code_lost is emitted (default 2).
func qr_scanner_set_lost_timeout(seconds: float):
	if arcore_interface:
		arcore_interface.qr_scanner_set_lost_timeout(seconds)

func qr_scanner_set_capture_detected_images(enabled: bool):
	if arcore_interface:
		arcore_interface.qr_scanner_set_capture_detected_images(enabled)

func qr_scanner_get_capture_detected_images() -> bool:
	if arcore_interface:
		return arcore_interface.qr_scanner_get_capture_detected_images()
	return false

func qr_scanner_get_detected_image(data: String) -> Image:
	if arcore_interface:
		return arcore_interface.qr_scanner_get_detected_image(data)
	return null

func qr_scanner_get_detected_bounds(data: String) -> Rect2:
	if arcore_interface:
		return arcore_interface.qr_scanner_get_detected_bounds(data)
	return Rect2()

## Bounds of an active QR code in screen pixels (window coordinates), where it shows on the
## camera background. Empty Rect2 if the code is not currently detected.
func qr_scanner_get_detected_screen_bounds(data: String) -> Rect2:
	if arcore_interface:
		return arcore_interface.qr_scanner_get_detected_screen_bounds(data)
	return Rect2()

func point_cloud_get_points():
	if arcore_interface:
		return arcore_interface.point_cloud_get_points()
	return PackedVector3Array()
