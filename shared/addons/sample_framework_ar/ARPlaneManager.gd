extends Node3D

## Manages ARCore plane detection visualisation.
## Automatically creates plane nodes with ARTrackedPlane.gd and MeshInstance3D children.
## Toggle plane detection and visibility at runtime via [member show_planes].

## Enable or disable the whole plane visualisation. Individual plane nodes are
## added/removed automatically each frame while this is true.
@export var show_planes: bool = true:
	set(v):
		show_planes = v
		if not v:
			_clear_all()

## When false, vertical planes (walls) are not visualised.
@export var vertical_planes: bool = true:
	set(v):
		vertical_planes = v
		ARCoreInterfaceInstance.enable_vertical_plane_detection(v)

## When false, horizontal planes (floors/ceilings) are not visualised.
@export var horizontal_planes: bool = true:
	set(v):
		horizontal_planes = v
		ARCoreInterfaceInstance.enable_horizontal_plane_detection(v)

var _active_planes: Dictionary  # plane_id -> Node3D instance

func _process(_delta: float) -> void:
	if not show_planes:
		return

	var all_ids: Array = ARCoreInterfaceInstance.plane_tracker_get_all_plane_ids()

	# Remove planes that have disappeared or whose type is now disabled.
	for id in _active_planes.keys():
		var keep: bool = all_ids.has(id)
		if keep:
			var is_v: bool = _is_vertical(id)
			if is_v and not vertical_planes:
				keep = false
			elif not is_v and not horizontal_planes:
				keep = false
		if not keep:
			_active_planes[id].queue_free()
			_active_planes.erase(id)

	# Update or create plane nodes.
	for id in all_ids:
		var trsf: Transform3D = ARCoreInterfaceInstance.plane_tracker_get_plane_transform(id)
		var is_v: bool = abs(trsf.basis.y.dot(Vector3.UP)) < 0.5
		if is_v and not vertical_planes:
			continue
		if not is_v and not horizontal_planes:
			continue

		var plane_node: Node3D
		if _active_planes.has(id):
			plane_node = _active_planes[id]
		else:
			plane_node = _create_plane_node()
			_active_planes[id] = plane_node
			add_child(plane_node)

		plane_node.global_transform = trsf
		if plane_node.has_method("set_vertical"):
			plane_node.set_vertical(is_v)
		if plane_node.has_method("update_boundary"):
			plane_node.update_boundary(ARCoreInterfaceInstance.plane_tracker_get_plane_boundary(id))

func _is_vertical(id) -> bool:
	var trsf: Transform3D = ARCoreInterfaceInstance.plane_tracker_get_plane_transform(id)
	return abs(trsf.basis.y.dot(Vector3.UP)) < 0.5

func _create_plane_node() -> Node3D:
	var plane = Node3D.new()
	plane.set_script(load("res://addons/sample_framework_ar/ARTrackedPlane.gd"))
	
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "MeshInstance3D"
	plane.add_child(mesh_instance)
	
	return plane

func _clear_all() -> void:
	for id in _active_planes.keys():
		_active_planes[id].queue_free()
	_active_planes.clear()
