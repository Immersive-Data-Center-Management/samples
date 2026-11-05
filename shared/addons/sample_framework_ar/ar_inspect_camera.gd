extends XRCamera3D
class_name ARInspectCamera

## Two independent views on top of the live AR view. Attach to the XRCamera3D under an XROrigin3D.
## The UI finds it via the "ar_inspect_controller" group.
##
## - Frozen ([method set_frozen]): ARCore holds the camera image and pose while it keeps tracking
##   underneath, so the user can lower the phone and keep tapping parts; resuming is seamless.
## - 3D view ([method set_3d_view]): the scene without the camera image, the real meshes shown,
##   orbit / zoom / pan with a child [OrbitController] around the part picked with [ObjectPicker],
##   e.g. to take the rack to the desk. Leaving it returns to the AR view it came from, live or
##   frozen, with the camera where it was.
##
## The OrbitController moves the XROrigin3D: the XR system owns the camera's local transform.
## The 3D view freezes ARCore while it is open, so the pose does not change under the orbit.

## Emitted when the 3D view is opened ([param active] = true) or closed.
signal view_3d_changed(active: bool)

## Distance (m) in front of the camera where the orbit pivot starts if nothing is selected.
@export var pivot_distance := 0.5
## How strongly zooming in pulls the pivot onto the selected object (0 = off, 1 = snap).
@export_range(0.0, 1.0) var zoom_recenter_strength := 0.5
## Background of the 3D view.
@export var view_3d_background_color := Color(0.3, 0.43, 0.85)

var _orbit: OrbitController
var _origin: XROrigin3D
var _origin_initial: Transform3D
var _frozen := false  # what the user asked for with set_frozen()
var _view_3d := false
var _bg_mode_initial := Environment.BG_SKY


func _enter_tree() -> void:
	add_to_group("ar_inspect_controller")


func _ready() -> void:
	_origin = get_parent() as XROrigin3D
	if _origin == null:
		push_error("ARInspectCamera: parent is not an XROrigin3D; the 3D view cannot orbit.")
		return
	_orbit = OrbitController.new()
	_orbit.camera = self
	_orbit.move_node = _origin
	_orbit.enabled = false
	_orbit.stay_above_floor = false
	_orbit.min_distance = 0.05
	_orbit.max_distance = 50.0
	_orbit.orbit_speed = 0.006
	_orbit.zoom_step = 0.12
	_orbit.zoom_recenter_strength = zoom_recenter_strength
	add_child(_orbit)
	var picker := _picker()
	if picker:
		picker.object_selected.connect(func(_id): _pivot_to_selection())


func is_frozen() -> bool:
	return _frozen


func is_3d_view() -> bool:
	return _view_3d


## Freeze (true) or resume (false) the AR camera image. Inside the 3D view the change applies
## once the view is closed.
func set_frozen(frozen: bool) -> void:
	_frozen = frozen
	if not _view_3d:
		ARCoreInterfaceInstance.set_ar_frozen(frozen)


## Open (true) or close (false) the 3D view.
func set_3d_view(active: bool) -> void:
	if active == _view_3d or _orbit == null:
		return
	_view_3d = active
	if active:
		ARCoreInterfaceInstance.set_ar_frozen(true)
		_origin_initial = _origin.global_transform
		_orbit.sync_from_camera(pivot_distance)
		_pivot_to_selection()
		_orbit.enabled = true
		if environment:
			_bg_mode_initial = environment.background_mode
			environment.background_mode = Environment.BG_COLOR
			environment.background_color = view_3d_background_color
	else:
		_orbit.enabled = false
		_origin.global_transform = _origin_initial
		if environment:
			environment.background_mode = _bg_mode_initial
		ARCoreInterfaceInstance.set_ar_frozen(_frozen)
	_reveal_meshes(active)
	view_3d_changed.emit(active)


## Reframes the selected object at screen centre, keeping angle and distance (3D view only).
func center_on_selected() -> void:
	var obj := _selected()
	if not _view_3d or obj == null:
		return
	_orbit.pivot = obj.get_pick_center()
	_orbit.apply()


## Orbit around the selected object; zooming in also drifts towards it.
func _pivot_to_selection() -> void:
	var obj := _selected()
	_orbit.zoom_anchor = obj.get_pick_center() if obj else Vector3.INF
	if _view_3d and obj:
		_orbit.set_pivot(obj.get_pick_center())


## Tell every PickableObject to show its real meshes (3D view) or its AR overlay look.
func _reveal_meshes(reveal: bool) -> void:
	for obj in get_tree().get_nodes_in_group("pickable_object"):
		obj.set_reveal_meshes(reveal)


func _picker() -> ObjectPicker:
	return get_tree().get_first_node_in_group("ar_object_picker") as ObjectPicker


func _selected() -> PickableObject:
	var picker := _picker()
	return picker.get_selected() if picker else null
