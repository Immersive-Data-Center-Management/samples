extends Node3D
class_name ARCoreInit

## Minimal ARCore initialiser — add to any scene that needs AR (or instance XRSetup.tscn).
##
## Set [member enabled_features] in the Inspector to choose which ARCore subsystems
## to activate at startup. After ARCore starts ([signal arcore_ready]), you can toggle
## individual features on/off at runtime via [method set_feature_enabled].


## Emitted once ARCore has started and all requested startup features are active.
signal arcore_ready(features: int)

const PLUGIN_NAME := "ARCorePlugin"
const START_RETRY_INTERVAL := 2.0  # seconds between retries of a failed ARCore start

## Image target detection — detects and tracks reference images in the scene. (use in combination with ImageTrackedComponent.gd)
const FEAT_IMAGE_TRACKING    := 1
## QR / barcode scanning — starts the scanner to detect QR codes and barcodes in the environment. (use in combination with QRCodeTrackedComponent.gd)
const FEAT_QR_SCANNING       := 2
## Horizontal plane detection — detects floors and ceilings (mostly debug visualization).
const FEAT_HORIZONTAL_PLANES := 4
## Vertical plane detection — detects walls (mostly debug visualization).
const FEAT_VERTICAL_PLANES   := 8
## Point cloud visualization — renders depth points (debug only; not needed for production).
const FEAT_POINT_CLOUD       := 16

## Bitmask of features to enable at startup. Change in the Inspector.
## Default: Image Tracking + QR Scanning + Horizontal Planes.
## After ARCore starts, use [method set_feature_enabled] to toggle features at runtime.
@export_flags(
		"Image Tracking:1",
		"QR Scanning:2",
		"Horizontal Planes:4",
		"Vertical Planes:8",
		"Point Cloud:16") var enabled_features: int = 7

## Current active features. Updated at startup and when you call [method set_feature_enabled].
## Use [method is_feature_enabled] to check instead of reading this directly.
var features_active: int = 0

## True when ARCore has finished startup.
var arcore_started: bool = false

var _android_plugin
var _cam_tex_bound := false
var _waiting_for_permission := false
var _retry_timer := 0.0  # > 0 while waiting to retry a failed ARCore start
var _sky_material: ShaderMaterial
var _last_vp_size := Vector2i.ZERO
var _plane_manager: Node3D
var _point_cloud_visualizer: Node3D

func _enter_tree() -> void:
	# Lets app states find the AR rig without knowing its path, e.g. to toggle QR scanning.
	add_to_group("arcore_init")
	# Grab the sky material already configured on XRCamera3D in the scene/subscene.
	var env: Environment = $XROrigin3D/XRCamera3D.environment
	if env and env.sky:
		_sky_material = env.sky.sky_material as ShaderMaterial

	if Engine.has_singleton(PLUGIN_NAME):
		_android_plugin = Engine.get_singleton(PLUGIN_NAME)
		_android_plugin.initializeEnvironment()
	else:
		printerr("[ARCore] Plugin '%s' not found." % PLUGIN_NAME)

	_request_permission_and_start()

func _exit_tree() -> void:
	if is_instance_valid(_android_plugin):
		_android_plugin.uninitializeEnvironment()

## Returns true if [param feature] is currently active (after [signal arcore_ready] fires).
func is_feature_enabled(feature: int) -> bool:
	return (features_active & feature) != 0

## Enable or disable a specific feature at runtime (only works after [signal arcore_ready]).
## For example: `set_feature_enabled(ARCoreInit.FEAT_QR_SCANNING, true)` to start QR scanning.
func set_feature_enabled(feature: int, enabled: bool) -> void:
	if not arcore_started:
		printerr("[ARCore] Cannot set features before arcore_ready signal.")
		return

	var is_currently_enabled := (features_active & feature) != 0
	if enabled == is_currently_enabled:
		return

	_apply_feature(feature, enabled)

	if enabled:
		features_active |= feature
	else:
		features_active &= ~feature
	print("[ARCore] Feature 0x%x set to %s" % [feature, enabled])

## Internal: applies a feature without state changes or guards.
func _apply_feature(feature: int, enabled: bool) -> void:
	match feature:
		FEAT_IMAGE_TRACKING:
			ARCoreInterfaceInstance.enable_images_detection(enabled)
			if enabled:
				ARCoreInterfaceInstance.create_image_tracker_database()
		FEAT_QR_SCANNING:
			if enabled:
				ARCoreInterfaceInstance.qr_scanner_start()
			else:
				ARCoreInterfaceInstance.qr_scanner_stop()
		FEAT_HORIZONTAL_PLANES, FEAT_VERTICAL_PLANES:
			if feature == FEAT_HORIZONTAL_PLANES:
				ARCoreInterfaceInstance.enable_horizontal_plane_detection(enabled)
			else:
				ARCoreInterfaceInstance.enable_vertical_plane_detection(enabled)
			if enabled:
				_create_plane_manager()
			elif not (features_active & (FEAT_HORIZONTAL_PLANES | FEAT_VERTICAL_PLANES) & ~feature):
				_destroy_plane_manager()  # no plane detection left
		FEAT_POINT_CLOUD:
			if enabled:
				_create_point_cloud_visualizer()
			else:
				_destroy_point_cloud_visualizer()

# ---------------------------------------------------------------------------
# Permission + startup
# ---------------------------------------------------------------------------

func _request_permission_and_start() -> void:
	if OS.has_feature("android") and \
			not "android.permission.CAMERA" in OS.get_granted_permissions():
		OS.request_permissions()
		_waiting_for_permission = true
		print("[ARCore] Waiting for camera permission...")
	else:
		_do_start()

func _do_start() -> void:
	_waiting_for_permission = false
	var started := ARCoreInterfaceInstance.start()

	if OS.has_feature("android") and not started:
		# Typically "Google Play Services for AR" still installing/updating on first launch.
		# Don't enable features on a dead session; retry until it comes up.
		printerr("[ARCore] Start failed (%s), retrying..." % ARCoreInterfaceInstance.get_last_error())
		_retry_timer = START_RETRY_INTERVAL
		return

	if not get_viewport().use_xr:
		# No native ARCore (desktop/editor): set up a viewable preview so non-AR features
		# (e.g. the object picker) can be tested off-device. Deferred so the camera is fully
		# inside the tree (look_at requires it) — _do_start can run during _enter_tree.
		_setup_desktop_preview.call_deferred()

	for feature in [FEAT_IMAGE_TRACKING, FEAT_QR_SCANNING, FEAT_HORIZONTAL_PLANES, FEAT_VERTICAL_PLANES, FEAT_POINT_CLOUD]:
		if enabled_features & feature:
			_apply_feature(feature, true)

	features_active = enabled_features
	arcore_started = true
	arcore_ready.emit(features_active)
	print("[ARCore] Started — features: 0x%x" % features_active)

## Desktop/editor-only preview. Off-device there is no camera feed (the sky shader's texture is
## unbound and renders white) and the AR camera sits on top of the origin-anchored content, so
## nothing is visible. Swap in a plain procedural sky (which also lights the scene) and frame the
## camera on the content so features like object picking can be exercised. Never runs with XR on.
func _setup_desktop_preview() -> void:
	var cam := $XROrigin3D/XRCamera3D as ARInspectCamera
	if cam == null:
		push_error("[ARCore] Desktop preview: XRCamera3D is missing the ARInspectCamera script.")
		return
	cam.current = true

	if cam.environment:
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		cam.environment.sky = sky
		cam.environment.background_mode = Environment.BG_SKY
		cam.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	# Frame the visible pickable content (image-tracked content is shown off-device by
	# ImageTrackedComponent.simulate_found()). Deferred a frame so that has happened.
	await get_tree().process_frame
	var bounds := _visible_pickable_bounds()
	var center := bounds.get_center() if bounds.has_volume() else Vector3(0.0, 0.15, 0.1)
	var radius := maxf(bounds.size.length() * 0.5, 0.15)
	cam.position = center + Vector3(0.0, 0.3, 1.0).normalized() * radius * 3.0
	cam.look_at(center, Vector3.UP)

	# Leave manual camera control disabled at startup, same as on device — the app enables it with
	# ARInspectCamera.set_3d_view (Experiment 3: the "3D view" toggle), then the mouse orbits.
	print("[ARCore] Desktop preview active (no XR): procedural sky + framed camera. Open the 3D view to orbit.")

## World-space box around the colliders of all visible PickableObjects (empty if none).
func _visible_pickable_bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for obj in get_tree().get_nodes_in_group("pickable_object"):
		if not (obj is Node3D and obj.is_visible_in_tree()):
			continue
		for shape_node in obj.find_children("*", "CollisionShape3D", false, false):
			var box := shape_node.shape as BoxShape3D
			if box == null:
				continue
			var world_box: AABB = shape_node.global_transform * AABB(-box.size * 0.5, box.size)
			bounds = world_box if first else bounds.merge(world_box)
			first = false
	return bounds

# ---------------------------------------------------------------------------
# Per-frame: permission poll + camera texture bind + viewport size (on change)
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _waiting_for_permission:
		if "android.permission.CAMERA" in OS.get_granted_permissions():
			_do_start()
		return

	if _retry_timer > 0.0:
		_retry_timer -= _delta
		if _retry_timer <= 0.0:
			_do_start()
		return

	if not _cam_tex_bound:
		var tex = ARCoreInterfaceInstance.get_camera_rgba_texture()
		if tex != null:
			if _sky_material:
				_sky_material.set_shader_parameter("camera_texture", tex)
			_cam_tex_bound = true
			print("[ARCore] Camera texture bound (%dx%d)" % [tex.get_width(), tex.get_height()])

	var vp_size: Vector2i = get_viewport().size
	if vp_size != _last_vp_size:
		_last_vp_size = vp_size
		if _sky_material:
			_sky_material.set_shader_parameter("viewport_size", vp_size)

# ---------------------------------------------------------------------------
# Plane manager creation/destruction
# ---------------------------------------------------------------------------

func _create_plane_manager() -> void:
	if is_instance_valid(_plane_manager):
		return  # Already exists
	
	_plane_manager = Node3D.new()
	_plane_manager.name = "ARPlaneManager"
	_plane_manager.set_script(load("res://addons/sample_framework_ar/ARPlaneManager.gd"))
	add_child(_plane_manager)
	_plane_manager.show_planes = true
	print("[ARCore] Plane manager created")

func _destroy_plane_manager() -> void:
	if is_instance_valid(_plane_manager):
		_plane_manager.queue_free()
		_plane_manager = null
		print("[ARCore] Plane manager destroyed")

# ---------------------------------------------------------------------------
# Point cloud visualizer creation/destruction
# ---------------------------------------------------------------------------

func _create_point_cloud_visualizer() -> void:
	if is_instance_valid(_point_cloud_visualizer):
		return  # Already exists
	
	_point_cloud_visualizer = MeshInstance3D.new()
	_point_cloud_visualizer.name = "ARPointCloud"
	_point_cloud_visualizer.set_script(load("res://addons/sample_framework_ar/ARPointCloud.gd"))
	add_child(_point_cloud_visualizer)
	_point_cloud_visualizer.enable(true)
	print("[ARCore] Point cloud visualizer created")

func _destroy_point_cloud_visualizer() -> void:
	if is_instance_valid(_point_cloud_visualizer):
		_point_cloud_visualizer.queue_free()
		_point_cloud_visualizer = null
		print("[ARCore] Point cloud visualizer destroyed")
