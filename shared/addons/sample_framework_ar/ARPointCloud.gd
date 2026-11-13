extends MeshInstance3D

## Renders the ARCore point cloud as a set of coloured dots.
## Attach this script to a MeshInstance3D node in the scene.
## Call enable(true) to start rendering; enable(false) to stop and hide.

var _enabled := false
var _mesh: ImmediateMesh
var _material: StandardMaterial3D

func _ready() -> void:
	_mesh = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(0.0, 1.0, 0.2, 1.0)
	_material.use_point_size = true
	_material.point_size = 6.0
	_material.vertex_color_use_as_albedo = true
	mesh = _mesh
	visible = false

func enable(toggled: bool) -> void:
	_enabled = toggled
	ARCoreInterfaceInstance.enable_point_cloud_detection(toggled)
	if not toggled:
		visible = false
		_mesh.clear_surfaces()

func _process(_delta: float) -> void:
	if not _enabled:
		return
	var points: PackedVector3Array = ARCoreInterfaceInstance.point_cloud_get_points()
	if points.is_empty():
		return
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_POINTS, _material)
	for pt in points:
		_mesh.surface_add_vertex(pt)
	_mesh.surface_end()
	set_surface_override_material(0, _material)
	visible = true
