extends Node3D
class_name ObjectPicker

## Selects [PickableObject]s by tapping or clicking them (Experiment 3; for why this isn't
## [StageSelection], see [PickableObject]). Attach as a child of the Camera3D (the XRCamera3D in AR).
##
## A "tap" is a single-finger press/release with little movement, so it doesn't
## fight the inspect-camera's orbit/pinch drags (see ar_inspect_camera.gd). This node
## never marks input as handled, so both handlers coexist. Works in live AR, frozen AR
## and the 3D view.
##
## It owns the current selection: it drives each object's highlight and emits an id the
## AR view uses to show that object's data.

## Emitted when a pickable object becomes selected.
signal object_selected(object_id: String)
## Emitted when the selection is cleared (tap on empty space).
signal selection_cleared

## Max pointer travel (px) between press and release still counted as a tap, not a drag.
@export var tap_move_threshold: float = 16.0
## Max ray length (m) for the pick query.
@export var ray_length: float = 100.0

var _camera: Camera3D
var _selected: PickableObject
var _logged_ray := false  # print the ray source once, to confirm which projection is in use

# Tap tracking (touch): the finger index we're following, plus where it went down.
var _tap_index: int = -1
var _tap_start_pos: Vector2 = Vector2.ZERO
var _tap_valid: bool = false

# Tap tracking (mouse, for desktop/editor testing).
var _mouse_down_pos: Vector2 = Vector2.ZERO
var _mouse_valid: bool = false

func _enter_tree() -> void:
	# Let the AR view find this picker without a cross-scene NodePath.
	add_to_group("ar_object_picker")

func _ready() -> void:
	_camera = get_parent() as Camera3D
	if _camera == null:
		_camera = get_viewport().get_camera_3d()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if _tap_index == -1:
				# First finger down — a potential tap.
				_tap_index = event.index
				_tap_start_pos = event.position
				_tap_valid = true
			else:
				# A second finger means a pinch/pan gesture, not a tap.
				_tap_valid = false
		else:
			if event.index == _tap_index:
				if _tap_valid and event.position.distance_to(_tap_start_pos) <= tap_move_threshold:
					_pick(event.position)
				_tap_index = -1
				_tap_valid = false
		return

	if event is InputEventScreenDrag:
		if event.index == _tap_index and event.position.distance_to(_tap_start_pos) > tap_move_threshold:
			_tap_valid = false
		return

	# Mouse support for desktop / in-editor testing.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_mouse_down_pos = event.position
			_mouse_valid = true
		elif _mouse_valid:
			if event.position.distance_to(_mouse_down_pos) <= tap_move_threshold:
				_pick(event.position)
			_mouse_valid = false
		return

	if event is InputEventMouseMotion and _mouse_valid:
		if event.position.distance_to(_mouse_down_pos) > tap_move_threshold:
			_mouse_valid = false

func _pick(screen_pos: Vector2) -> void:
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return

	var ray := _screen_ray(screen_pos)
	var picked := _pick_box(ray.from, ray.to)
	if picked != null:
		_select(picked)
	else:
		_clear()

## Build a world-space pick ray { from, to } for a screen position.
## Under XR the image is rendered with ARCore's own projection matrix (see ARCoreInterface), NOT the
## Godot Camera3D.fov — so project_ray_normal() is misaligned (wrong FOV/aspect) and taps land off,
## worst toward the edges. We unproject the tap through ARCore's actual matrix + the camera's world
## pose instead, which matches the rendered image regardless of FOV/aspect/orientation. Off-XR
## (desktop) there's no ARCore projection, so we use the camera's own projection.
func _screen_ray(screen_pos: Vector2) -> Dictionary:
	# Looked up by path, so this addon also works in projects without the ARCore plugin.
	var arcore := get_node_or_null(^"/root/ARCoreInterfaceInstance")
	if get_viewport().use_xr and arcore:
		var m: PackedFloat64Array = arcore.get_projection_matrix()
		if m.size() == 16:
			var proj := Projection(
				Vector4(m[0], m[1], m[2], m[3]),
				Vector4(m[4], m[5], m[6], m[7]),
				Vector4(m[8], m[9], m[10], m[11]),
				Vector4(m[12], m[13], m[14], m[15]))
			var inv := proj.inverse()
			var vp := Vector2(get_viewport().get_visible_rect().size)
			# Screen pixel -> normalized device coords (y flipped: screen y is down, NDC y is up).
			var ndc := Vector2(2.0 * screen_pos.x / vp.x - 1.0, 1.0 - 2.0 * screen_pos.y / vp.y)
			# Unproject the near (clip z = -1) and far (clip z = +1) points; column-major M * v via
			# the inverse projection's column Vector4s, then the perspective divide.
			var near4: Vector4 = inv.x * ndc.x + inv.y * ndc.y + inv.z * -1.0 + inv.w
			var far4: Vector4 = inv.x * ndc.x + inv.y * ndc.y + inv.z * 1.0 + inv.w
			var cam_t := _camera.global_transform
			var from := cam_t * (Vector3(near4.x, near4.y, near4.z) / near4.w)
			var to := cam_t * (Vector3(far4.x, far4.y, far4.z) / far4.w)
			if not _logged_ray:
				_logged_ray = true
				print("[ObjectPicker] XR pick via ARCore projection (vp=%s ndc=%s)." % [vp, ndc])
			return {"from": from, "to": to}

	var origin := _camera.project_ray_origin(screen_pos)
	return {"from": origin, "to": origin + _camera.project_ray_normal(screen_pos) * ray_length}

## The nearest [PickableObject] whose collider the ray hits. Hidden objects switch their colliders
## off (see [PickableObject]), so they can't be hit. Bodies are ignored: the static-body proxies
## IDTXFlow builds from USD collision prims are not pickable.
func _pick_box(from: Vector3, to: Vector3) -> PickableObject:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.get("collider") as PickableObject if not hit.is_empty() else null

func _select(obj: PickableObject) -> void:
	if obj == _selected:
		return
	if _selected != null:
		_selected.on_deselected()
	_selected = obj
	_selected.on_selected()
	object_selected.emit(obj.object_id)

func _clear() -> void:
	if _selected == null:
		return
	_selected.on_deselected()
	_selected = null
	selection_cleared.emit()

## Select [param obj] from code (e.g. a "show warnings" button), as if it had been tapped.
## null clears the selection.
func select(obj: PickableObject) -> void:
	if obj == null:
		_clear()
	else:
		_select(obj)

## The currently selected object, or null. Used e.g. by the inspect camera to orbit around it.
func get_selected() -> PickableObject:
	return _selected
