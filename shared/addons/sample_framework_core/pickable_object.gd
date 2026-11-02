@tool
extends Area3D
class_name PickableObject

## Experiment 3 uses [ObjectPicker] instead of [StageSelection]: its parts are separate
## USD files with local data, not one AAS-composed stage. AR needs ARCore-projected tap
## rays, hint boxes over the camera image, and per-part warning status.
## Box visuals include descendant USD collision proxies; only this Area3D is pickable.
##
## Setup: parent the model under this Area3D and set [member object_id] to the app's data key.
## Visual flags: Hint/Highlight choose the tint, Mesh shows the textured model, Collider Box
## (Fill/Wire) draws the box instead of tinting the model. A tint without Mesh draws a ghost mesh.

## Bake from meshes available in the editor; save the scene to keep the collider.
@warning_ignore("unused_private_class_variable")
@export_tool_button("Fit collider to mesh") var _bake_action = _editor_bake_collider
@export var object_id: String = ""
## Disables colliders and all visuals without removing the object from its group.
@export var disabled: bool = false:
	set(value):
		if disabled == value:
			return
		disabled = value
		if is_inside_tree() and not Engine.is_editor_hint():
			_update_collider_enabled()
			_apply_visuals()

enum Status { NORMAL, WARNING }
## WARNING adds a tint and "!" marker; the selected highlight takes precedence.
@export var status: Status = Status.NORMAL:
	set(value):
		if status == value:
			return
		status = value
		if is_inside_tree() and not Engine.is_editor_hint():
			_apply_visuals()
		status_changed.emit(object_id, status)

@export_group("Visuals")
@export_flags("Hint", "Highlight", "Mesh", "Collider Box (Fill)", "Collider Box (Wire)") var visuals_unselected: int = VIS_MESH
@export_flags("Hint", "Highlight", "Mesh", "Collider Box (Fill)", "Collider Box (Wire)") var visuals_selected: int = VIS_MESH | VIS_HIGHLIGHT
@export var highlight_color: Color = Color(0.2, 0.6, 1.0, 0.35)
@export var hint_color: Color = Color(0.2, 0.6, 1.0, 0.12)
@export var warning_color: Color = Color(1.0, 0.45, 0.0, 0.45)

@export_group("Collider")
## Fit on startup and stage_loading_finished; preserve existing colliders.
## Other async loaders can call refit_collider() once their meshes are ready.
@export var auto_fit_collider: bool = true
## Scales the fitted box; > 1 makes small parts easier to tap.
@export var collider_padding: float = 1.05
## Ignore stray meshes smaller than this world-space size (metres); 0 includes all.
@export var ignore_meshes_smaller_than: float = 0.002

signal selected(object_id: String)
signal deselected(object_id: String)
signal status_changed(object_id: String, status: Status)

# Keep bit values stable for saved scenes.
const VIS_HINT := 1
const VIS_HIGHLIGHT := 2
const VIS_MESH := 4
const VIS_COLLIDER_FILL := 8
const VIS_COLLIDER_WIRE := 16
const CONTENT_LOADED_SIGNAL := "stage_loading_finished"
var _materials: Dictionary[Color, StandardMaterial3D] = {}
var _collider_viz: Node3D
var _status_marker: Label3D
var _is_selected := false
var _reveal_meshes := false
var _auto_fitting := false

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	add_to_group("pickable_object")
	# Physics ignores visibility, including hidden image-tracking ancestors.
	visibility_changed.connect(_update_collider_enabled)
	_auto_fitting = auto_fit_collider and _collision_shapes().is_empty()
	var fitted := _auto_fitting and _fit_auto_collider() != null
	var will_load := false
	for node in find_children("*", "", true, false):
		if node.has_signal(CONTENT_LOADED_SIGNAL):
			will_load = true
			node.connect(CONTENT_LOADED_SIGNAL, _on_content_loaded)
	if _auto_fitting and not fitted and not will_load:
		push_warning("[PickableObject '%s'] No meshes or async loader; call refit_collider() once content exists." % object_id)
	_update_collider_enabled()
	_apply_visuals()

# Replaces Area3D's own "This node has no shape" warning: colliders here usually only exist at
# runtime (auto-fit after loading, or CollisionAPI proxies inside a USD stage loaded by IDTXFlow).
func _get_configuration_warnings() -> PackedStringArray:
	if auto_fit_collider or not _collision_shapes().is_empty() or _has_async_content():
		return PackedStringArray()
	return PackedStringArray(["No collider: turn auto_fit_collider on, click \"Fit collider to mesh\", add a CollisionShape3D, or load a USD stage with CollisionAPI proxies."])

func _has_async_content() -> bool:
	return find_children("*", "", true, false).any(func(n): return n.has_signal(CONTENT_LOADED_SIGNAL))

func _update_collider_enabled() -> void:
	var enabled := is_visible_in_tree() and not disabled
	for shape in _collision_shapes():
		shape.disabled = not enabled

## Refit after loading or moving meshes. Returns false if there are no mesh bounds.
func refit_collider() -> bool:
	var shape := _fit_auto_collider()
	if not Engine.is_editor_hint():
		_update_collider_enabled()
		_apply_visuals()
	return shape != null

func _fit_auto_collider() -> CollisionShape3D:
	var to_local := global_transform.affine_inverse()
	var bounds := AABB()
	var found := false
	for mi in _content_meshes():
		if mi.mesh == null:
			continue
		var aabb := mi.get_aabb()
		var world_size := (mi.global_transform * aabb).size
		if world_size[world_size.max_axis_index()] < ignore_meshes_smaller_than:
			continue
		var local_bounds := (to_local * mi.global_transform) * aabb
		bounds = bounds.merge(local_bounds) if found else local_bounds
		found = true
	if not found or bounds.size.is_zero_approx():
		print("[PickableObject '%s'] No mesh bounds yet; collider not fitted." % object_id)
		return null
	var shape := get_node_or_null(^"AutoCollider") as CollisionShape3D
	if shape == null:
		shape = CollisionShape3D.new()
		shape.name = "AutoCollider"
		add_child(shape)
	var box := BoxShape3D.new()
	box.size = bounds.size * collider_padding
	shape.shape = box
	shape.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
	return shape

func _on_content_loaded(success: bool) -> void:
	if not success:
		push_warning("[PickableObject '%s'] Content loading failed." % object_id)
		return
	if _auto_fitting:
		refit_collider()
	else:
		_apply_visuals()

func _editor_bake_collider() -> void:
	for shape in _collision_shapes():
		if shape != get_node_or_null(^"AutoCollider"):
			push_warning("[PickableObject '%s'] An authored collider already exists; remove it before baking." % object_id)
			return
	var baked := _fit_auto_collider()
	if baked:
		baked.owner = get_tree().edited_scene_root
		print("[PickableObject '%s'] Baked the collider, save the scene to keep it." % object_id)
	else:
		push_warning("[PickableObject '%s'] No meshes in the editor; use runtime auto-fit instead." % object_id)
	update_configuration_warnings()

func _collision_shapes() -> Array[CollisionShape3D]:
	var shapes: Array[CollisionShape3D] = []
	shapes.assign(find_children("*", "CollisionShape3D", true, false))
	return shapes

func _content_meshes() -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for mi in find_children("*", "MeshInstance3D", true, false):
		if _collider_viz == null or not _collider_viz.is_ancestor_of(mi):
			meshes.append(mi)
	return meshes

## World-space collider centre, used as the inspect camera's orbit pivot.
func get_pick_center() -> Vector3:
	var shapes := _collision_shapes()
	return shapes[0].global_position if not shapes.is_empty() else global_position

func on_selected() -> void:
	_is_selected = true
	_apply_visuals()
	selected.emit(object_id)

func on_deselected() -> void:
	_is_selected = false
	_apply_visuals()
	deselected.emit(object_id)

## ARInspectCamera reveals textures while retaining selection, hint and warning tints.
func set_reveal_meshes(enabled: bool) -> void:
	if enabled == _reveal_meshes:
		return
	_reveal_meshes = enabled
	_apply_visuals()

func _apply_visuals() -> void:
	if Engine.is_editor_hint():
		return
	_update_status_marker()
	var flags := visuals_selected if _is_selected else visuals_unselected
	if _reveal_meshes:
		flags = VIS_MESH | (VIS_HIGHLIGHT if _is_selected else visuals_unselected & VIS_HINT)
	if disabled:
		flags = 0
	var warning := status == Status.WARNING and not _is_selected
	var tinted := not disabled and (warning or (flags & (VIS_HINT | VIS_HIGHLIGHT)) != 0)
	var tint := highlight_color if flags & VIS_HIGHLIGHT else hint_color
	if warning:
		tint = warning_color
	var tint_mat: StandardMaterial3D = _material(tint) if tinted else null
	var show_mesh := (flags & VIS_MESH) != 0
	var on_box := tinted and (flags & (VIS_COLLIDER_FILL | VIS_COLLIDER_WIRE)) != 0
	var ghost := tinted and not show_mesh and not on_box
	for mi in _content_meshes():
		mi.visible = show_mesh or ghost
		mi.material_override = tint_mat if ghost else null
		mi.material_overlay = tint_mat if show_mesh and not on_box else null
	var fill_mat: StandardMaterial3D = tint_mat if on_box and (flags & VIS_COLLIDER_FILL) else null
	var wire_mat: StandardMaterial3D = null
	if on_box and (flags & VIS_COLLIDER_WIRE):
		wire_mat = _material(Color(tint, clampf(tint.a * 3.0, 0.0, 1.0)))
	_update_collider_viz(fill_mat, wire_mat)

func _update_collider_viz(fill_mat: StandardMaterial3D, wire_mat: StandardMaterial3D) -> void:
	var needed := fill_mat != null or wire_mat != null
	if _collider_viz == null:
		if not needed:
			return
		_collider_viz = Node3D.new()
		_collider_viz.name = "ColliderViz"
		add_child(_collider_viz)
	for child in _collider_viz.get_children():
		_collider_viz.remove_child(child)
		child.queue_free()
	_collider_viz.visible = needed
	if not needed:
		return
	var to_local := global_transform.affine_inverse()
	for shape in _collision_shapes():
		var box := shape.shape as BoxShape3D
		if box == null:
			continue
		var xform := to_local * shape.global_transform
		if fill_mat != null:
			var fill := BoxMesh.new()
			fill.size = box.size
			_add_viz_mesh(fill, fill_mat, xform)
		if wire_mat != null:
			_add_viz_mesh(_wire_box_mesh(box.size), wire_mat, xform)

func _add_viz_mesh(mesh: Mesh, mat: StandardMaterial3D, xform: Transform3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xform
	_collider_viz.add_child(mi)

## Twelve box edges without the solid surface included in Shape3D.get_debug_mesh().
static func _wire_box_mesh(size: Vector3) -> ArrayMesh:
	var box := AABB(-size * 0.5, size)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_LINES)
	for corner in 8:
		for axis_bit in [1, 2, 4]:
			if (corner & axis_bit) == 0:
				surface.add_vertex(box.get_endpoint(corner))
				surface.add_vertex(box.get_endpoint(corner | axis_bit))
	return surface.commit()

func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = color
		_materials[color] = mat
	return _materials[color]

func _update_status_marker() -> void:
	var active := status == Status.WARNING and not disabled
	set_process(active)
	if _status_marker == null and active:
		_status_marker = Label3D.new()
		_status_marker.text = "!"
		_status_marker.font_size = 96
		_status_marker.outline_size = 24
		_status_marker.pixel_size = 0.0008
		_status_marker.fixed_size = true
		_status_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_status_marker.no_depth_test = true
		_status_marker.render_priority = 100  # drawn after the transparent hint boxes, not under them
		_status_marker.top_level = true  # ignore the image target's scale
		add_child(_status_marker)
	if _status_marker != null:
		_status_marker.modulate = Color(warning_color, 1.0)
		_status_marker.visible = active

# Follow the image target, placing the marker 3 cm above the first box collider. "Above" is this
# object's own +Y, not the world's: an image target lying flat or on a wall turns the content.
func _process(_delta: float) -> void:
	_status_marker.global_position = global_position
	for shape in _collision_shapes():
		if shape.shape is BoxShape3D:
			var size := (shape.shape as BoxShape3D).size
			var box := (global_transform.affine_inverse() * shape.global_transform) * AABB(-size * 0.5, size)
			var top := global_transform * Vector3(box.get_center().x, box.end.y, box.get_center().z)
			_status_marker.global_position = top + global_basis.y.normalized() * 0.03
			return
