@tool
extends Node3D
class_name ImageTrackedComponent

## Tracks an ARCore image target and keeps this node's global transform in sync
## with the detected image's real-world pose (no offset applied here).
##
## Usage:
##   1. Add this node anywhere in the scene tree.
##   2. Set [member tracked_texture] to the reference image (PNG/JPG loaded from res://).
##      The filename (without extension) is used as the ARCore tracking ID — keep it stable.
##   3. Content that should appear on/around the image: add as child nodes and position
##      them locally. This component only moves itself; offsets live in child transforms.
##   4. Connect [signal image_found] and [signal image_lost] for custom logic.
##
## Requires [ARCoreInit.FEAT_IMAGE_TRACKING] to be enabled in the scene's ARCoreInit node (InitARCore.gd).

## Emitted (once per activation) with the world transform at the moment of first detection.
signal image_found(world_transform: Transform3D)
## Emitted when tracking is lost after the [member time_to_deactivate] grace period expires.
signal image_lost

## Reference image to register with ARCore as a tracking target.
@export var tracked_texture: Texture2D: set = _set_tracked_texture

## Physical width of the real-world image in metres.
## Improves ARCore detection accuracy. Leave at -1 to let ARCore estimate.
@export var physical_width: float = -1.0: set = _set_physical_width

## Runs Google's `arcoreimg eval-img` on [member tracked_texture] and prints its tracking
## quality score (0-100; ARCore recommends 75+) to the editor Output panel. The bootstrap
## script downloads arcoreimg into this addon's tools/ folder; the ARCOREIMG environment
## variable (full path) or your PATH work too.
@export_tool_button("Evaluate target quality") var _eval_quality_action: Callable = _evaluate_target_quality

## Grace period in seconds before [signal image_lost] fires after ARCore stops
## reporting the image. Prevents rapid flickering on brief tracking loss.
## Set to 0 for immediate hide.
@export var time_to_deactivate: float = 2.0

## Smoothing factor for transform interpolation (0 = no smoothing, 1 = frozen).[br]
## Higher values reduce jitter but add latency. 0.85 is a good starting point.
@export_range(0.0, 0.99, 0.01) var smoothing: float = 0.85

@export_group("Editor preview")
## Show a flat quad of [member tracked_texture] in the editor viewport, positioned exactly
## where the image will be tracked at runtime (this node's origin = image centre; the image
## lies in the local X-Z plane, +Y is its surface normal). Add content as child nodes and
## offset them against this quad. Editor-only — never rendered on device, never saved.
@export var show_target_preview: bool = true: set = _set_show_target_preview

## Preview quad width in metres, used only when [member physical_width] is unset (<= 0), so the
## guide still has a size to display. Height follows the texture's aspect ratio.
@export var preview_fallback_width: float = 0.2: set = _set_preview_fallback_width

## Opacity of the preview quad. Lower it to see child content placed behind the image plane.
@export_range(0.0, 1.0, 0.05) var preview_opacity: float = 1.0: set = _set_preview_opacity

var _tracked_image: Image
var _tracking_id: String = ""
var _registration_pending: bool = false
var _active: bool = false   # true while image is (or was recently) tracked
var _ttl: float = 0.0       # countdown to image_lost; reset to time_to_deactivate each tracked frame

func _ready() -> void:
	if Engine.is_editor_hint():
		_update_preview()
		return

	visible = false

	if tracked_texture == null:
		push_error("[ImageTracker] tracked_texture not set on '%s'" % name)
		return

	_tracked_image = tracked_texture.get_image()
	# VRAM-compressed imports can't be read per pixel (the native grayscale conversion would see black).
	if _tracked_image.is_compressed():
		_tracked_image.decompress()
	_tracking_id = tracked_texture.resource_path.get_file().get_basename()
	if _tracking_id.is_empty():
		_tracking_id = str(get_instance_id())

	print("[ImageTracker] Will register '%s'" % _tracking_id)
	_registration_pending = true

## Act as if the image had been detected where this node already is. For testing without a
## device, e.g. a desktop run where ARCore is unavailable.
func simulate_found() -> void:
	_active = true
	visible = true
	image_found.emit(global_transform)

func _try_register() -> void:
	# Waits until the ARCore interface is initialised (database must exist first).
	var iface = ARCoreInterfaceInstance.get_interface()
	if iface == null or not iface.is_initialized():
		return
	ARCoreInterfaceInstance.image_tracker_database_add_image(_tracked_image, _tracking_id, physical_width)
	_registration_pending = false
	print("[ImageTracker] Registered '%s'" % _tracking_id)

## Dynamically replace this component's target with a new image at runtime
## (e.g. a QR code captured by QRCodeTrackedComponent).
func track_dynamic(img: Image, identifier: String, width: float = -1.0) -> void:
	_tracked_image = img
	_tracking_id = identifier
	ARCoreInterfaceInstance.image_tracker_database_add_image(img, identifier, width)
	_registration_pending = false

func is_active() -> bool:
	return _active

func _process(delta: float) -> void:
	# Without native ARCore nothing can be tracked; return so a simulated detection isn't "lost".
	if Engine.is_editor_hint() or ARCoreInterfaceInstance.get_interface() == null:
		return

	if _registration_pending:
		_try_register()
		return

	# While the AR view is frozen for inspection, hold the last pose. ARCore keeps tracking
	# underneath (in FROZEN mode), but we must not reposition the content, or it would drift
	# as the user moves the phone — only manual orbit/zoom should move the view.
	if ARCoreInterfaceInstance.is_ar_frozen():
		return

	var tracking: bool = ARCoreInterfaceInstance.image_tracker_get_tracking_status(_tracking_id)

	if tracking:
		var trsf: Transform3D = ARCoreInterfaceInstance.image_tracker_get_tracked_transform(_tracking_id)
		if not trsf.basis.is_finite() or absf(trsf.basis.determinant()) < 0.0001:
			return

		# Frame-rate independent smoothing; snap on the first frame of a new detection.
		if smoothing > 0.0 and _active:
			global_transform = global_transform.interpolate_with(trsf, 1.0 - pow(smoothing, delta * 60.0))
		else:
			global_transform = trsf

		visible = true

		if not _active:
			_active = true
			image_found.emit(trsf)
			print("[ImageTracker] Found '%s'" % _tracking_id)
		_ttl = time_to_deactivate
	else:
		if _active:
			if _ttl > 0.0:
				_ttl -= delta
			else:
				_active = false
				visible = false
				image_lost.emit()
				print("[ImageTracker] Lost '%s'" % _tracking_id)


# ---------------------------------------------------------------------------
# Target quality evaluation (arcoreimg)
#
# Editor-only. Shells out to Google's `arcoreimg eval-img` and prints the tracking
# quality score (0-100, higher is better; ARCore recommends >= 75) for the assigned
# tracked_texture. The binary ships with the ARCore SDK; looked up in order: the ARCOREIMG
# environment variable (full path), tools/ next to this script (bootstrap.ps1 puts it there),
# res://tools/, then `arcoreimg` on PATH.
# ---------------------------------------------------------------------------

func _find_arcoreimg() -> String:
	var env := OS.get_environment("ARCOREIMG")
	if not env.is_empty() and FileAccess.file_exists(env):
		return env
	var exe := "arcoreimg.exe" if OS.get_name() == "Windows" else "arcoreimg"
	for dir in [get_script().resource_path.get_base_dir() + "/tools", "res://tools"]:
		var exe_path := ProjectSettings.globalize_path(dir + "/" + exe)
		if FileAccess.file_exists(exe_path):
			return exe_path
	return "arcoreimg"  # rely on PATH; OS.execute returns -1 if it can't be started

func _evaluate_target_quality() -> void:
	if tracked_texture == null:
		push_warning("[ImageTracker] Assign a tracked_texture before evaluating quality.")
		return

	var src := tracked_texture.resource_path
	if src.is_empty():
		push_warning("[ImageTracker] tracked_texture has no source file on disk to evaluate.")
		return

	var img_path := ProjectSettings.globalize_path(src)
	var exe := _find_arcoreimg()

	var out: Array = []
	var args := PackedStringArray(["eval-img", "--input_image_path=" + img_path])
	var code := OS.execute(exe, args, out, true)  # read_stderr so failures are visible
	var text := "\n".join(out).strip_edges()

	if code == -1:
		push_warning("[ImageTracker] Could not start '%s'. Run the experiment's bootstrap.ps1 (downloads it), or set the ARCOREIMG environment variable to the full path of arcoreimg from the ARCore SDK." % exe)
		return
	if code != 0:
		push_warning("[ImageTracker] arcoreimg failed (exit %d): %s" % [code, text])
		return

	print("[ImageTracker] arcoreimg quality for '%s': %s  (0-100, higher is better; ARCore recommends >= 75)" % [src.get_file(), text])


# ---------------------------------------------------------------------------
# Editor preview
#
# In the editor only, render tracked_texture as a flat quad at this node's origin,
# matching the pose ARCore reports at runtime: the image spans the local X-Z plane
# with +Y as its surface normal (Godot's default PlaneMesh orientation), so no axis
# flips are needed. The preview is an INTERNAL child — it is never persisted into the
# scene and never appears in the scene tree — and is skipped entirely at runtime.
# ---------------------------------------------------------------------------

var _preview: MeshInstance3D = null

func _set_tracked_texture(v: Texture2D) -> void:
	tracked_texture = v
	_update_preview()

func _set_physical_width(v: float) -> void:
	physical_width = v
	_update_preview()

func _set_show_target_preview(v: bool) -> void:
	show_target_preview = v
	_update_preview()

func _set_preview_fallback_width(v: float) -> void:
	preview_fallback_width = v
	_update_preview()

func _set_preview_opacity(v: float) -> void:
	preview_opacity = v
	_update_preview()

func _update_preview() -> void:
	if not Engine.is_editor_hint():
		return
	if not is_inside_tree():
		return  # setters can fire during scene load; _ready() builds it once ready

	if not show_target_preview or tracked_texture == null:
		if is_instance_valid(_preview):
			_preview.visible = false
		return

	_ensure_preview()
	_preview.visible = true

	var w: float = physical_width if physical_width > 0.0 else preview_fallback_width
	var tex_w := float(tracked_texture.get_width())
	var tex_h := float(tracked_texture.get_height())
	var aspect: float = (tex_h / tex_w) if tex_w > 0.0 else 1.0

	var mesh := _preview.mesh as PlaneMesh
	mesh.size = Vector2(w, w * aspect)  # x = image width (+X), y = image height (+Z)

	var mat := _preview.material_override as StandardMaterial3D
	mat.albedo_texture = tracked_texture
	if preview_opacity < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 1.0, 1.0, preview_opacity)
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)

func _ensure_preview() -> void:
	if is_instance_valid(_preview):
		return
	_preview = MeshInstance3D.new()
	_preview.name = "TargetPreview"
	_preview.mesh = PlaneMesh.new()
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from both sides in the editor
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_preview.material_override = mat

	# Internal + owner-less: not saved with the scene, not shown in the scene tree.
	add_child(_preview, false, Node.INTERNAL_MODE_BACK)
