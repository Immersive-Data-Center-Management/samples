extends Node
class_name StageSelection

## Picking and highlighting on the USD stage. A left click (or tap) in the 3D view
## (clicks on UI panels never get here) emits `picked` with "" for the rack, a
## component identifier, or null for empty space. highlight() puts the
## highlight material on the meshes of that selection.
##
## Components are the RackComponents dictionaries; their prim_name links the
## AAS_Component_N payload prims to an identifier.

signal picked(identifier: Variant)

@export var stage: Node3D
@export var highlight_material: Material = preload("res://addons/sample_framework_core/highlight.tres")

var components: Array = []
## Meshes currently carrying the highlight overlay.
var _highlighted: Array[GeometryInstance3D] = []


## Set false to use highlight() only (e.g. a view that selects from code, not by tapping).
@export var pick_on_click := true

var _touch_start := Vector2.INF


func _unhandled_input(event: InputEvent) -> void:
	if not pick_on_click:
		return
	# A click / tap is a press that is released near where it started (a drag orbits the camera).
	var left_click: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT
	if left_click or (event is InputEventScreenTouch and event.index == 0):
		if event.pressed:
			_touch_start = event.position
		elif event.position.distance_to(_touch_start) < 16.0:
			picked.emit(_pick(event.position))


func highlight(identifier: Variant) -> void:
	for mesh in _highlighted:
		if is_instance_valid(mesh):
			mesh.material_overlay = null
	_highlighted.clear()
	if identifier == null:
		return

	var wrappers: Array[Node] = []
	for comp in components:
		var wrapper := _find_prim_node(stage, comp.get("prim_name", ""))
		if wrapper != null:
			wrappers.append(wrapper)

	var root := stage
	var comp := component_by(&"identifier", identifier)
	if not comp.is_empty():
		root = _find_prim_node(stage, comp.get("prim_name", ""))
		if root == null:
			return
	for mesh: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		# The rack is everything outside the component payloads.
		if root == stage and wrappers.any(func(w): return w.is_ancestor_of(mesh)):
			continue
		mesh.material_overlay = highlight_material
		_highlighted.append(mesh)


func has_selection() -> bool:
	return not _highlighted.is_empty()


## World-space bounds of the highlighted meshes.
func selected_bounds() -> AABB:
	var box: AABB = _highlighted[0].global_transform * _highlighted[0].get_aabb()
	for mesh in _highlighted:
		box = box.merge(mesh.global_transform * mesh.get_aabb())
	return box


func _pick(screen_pos: Vector2) -> Variant:
	var camera := stage.get_viewport().get_camera_3d()
	var origin := camera.project_ray_origin(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(screen_pos) * 1000.0)
	query.collide_with_areas = true
	var hit := stage.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	# IDTXFlow names payload nodes after the USD file; the prim name is the
	# AAS_Component_N wrapper from the session layer.
	var node: Node = hit["collider"]
	while node != null and node != stage:
		if node.has_method("get_prim_name"):
			var comp := component_by(&"prim_name", str(node.get_prim_name()))
			if not comp.is_empty():
				return comp["identifier"]
		node = node.get_parent()
	return ""


func component_by(key: StringName, value: String) -> Dictionary:
	for comp in components:
		if comp.get(key) == value:
			return comp
	return {}


func _find_prim_node(node: Node, prim_name: String) -> Node:
	if prim_name.is_empty():
		return null
	if node.has_method("get_prim_name") and str(node.get_prim_name()) == prim_name:
		return node
	for child in node.get_children():
		var found := _find_prim_node(child, prim_name)
		if found != null:
			return found
	return null
