extends MeshInstance3D

## Thin-line grid on the XZ plane at Y=0. Material: materials/grid.tres.

@export var half_extent := 20
@export var step := 1.0
@export var color := Color(0.45, 0.45, 0.45, 0.35)


func _ready() -> void:
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	lines.surface_set_color(color)
	var e := half_extent * step
	for i in range(-half_extent, half_extent + 1):
		var t := i * step
		lines.surface_add_vertex(Vector3(t, 0, -e))
		lines.surface_add_vertex(Vector3(t, 0, e))
		lines.surface_add_vertex(Vector3(-e, 0, t))
		lines.surface_add_vertex(Vector3(e, 0, t))
	lines.surface_end()
	mesh = lines
