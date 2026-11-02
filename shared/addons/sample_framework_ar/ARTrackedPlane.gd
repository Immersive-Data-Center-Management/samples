extends Node3D

## Visualises a single ARCore-detected plane as a transparent polygon mesh.
## Attach to the root Node3D of the tracked-plane scene used by ARPlaneManager.
## Requires a MeshInstance3D child node named "MeshInstance3D".
## Color: green = horizontal plane, blue = vertical plane (wall).

var _material: StandardMaterial3D
var _mesh_instance: MeshInstance3D
var _last_boundary_hash: int = -1

func _ready() -> void:
	_mesh_instance = $MeshInstance3D
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(0.2, 1.0, 0.4, 0.35)  # green (horizontal)

func set_vertical(is_vertical: bool) -> void:
	if is_vertical:
		_material.albedo_color = Color(0.2, 0.5, 1.0, 0.35)  # blue (vertical/wall)
	else:
		_material.albedo_color = Color(0.2, 1.0, 0.4, 0.35)  # green (horizontal)

func update_boundary(boundary: Array) -> void:
	if _mesh_instance == null or boundary.size() < 3:
		return
	var h := hash(boundary)
	if h == _last_boundary_hash:
		return
	_last_boundary_hash = h

	var polygon_2d := PackedVector2Array()
	for pt in boundary:
		polygon_2d.append(Vector2(pt.x, pt.z))

	var indices := Geometry2D.triangulate_polygon(polygon_2d)
	if indices.is_empty():
		return

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for pt in boundary:
		vertices.append(Vector3(pt.x, 0.0, pt.z))
		normals.append(Vector3.UP)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(indices)

	var new_mesh := ArrayMesh.new()
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	new_mesh.surface_set_material(0, _material)
	_mesh_instance.mesh = new_mesh
