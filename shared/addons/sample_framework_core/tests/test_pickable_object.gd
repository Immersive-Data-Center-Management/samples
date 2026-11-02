extends Node3D

class AsyncContent extends Node3D:
	signal stage_loading_finished(success: bool)

var _failed := false

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_fitting()
	_test_async_fitting()
	_test_authored_collider()
	_test_visuals()
	await _test_picking()
	print("test_pickable_object: FAILED" if _failed else "test_pickable_object: OK")
	get_tree().quit(1 if _failed else 0)

func _mesh(parent: Node3D, size: Vector3, offset := Vector3.ZERO) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.mesh.size = size
	mesh.position = offset
	parent.add_child(mesh)
	return mesh

func _part() -> PickableObject:
	var part := PickableObject.new()
	part.object_id = "part"
	part.visuals_unselected = PickableObject.VIS_HINT | PickableObject.VIS_COLLIDER_FILL
	part.visuals_selected = PickableObject.VIS_HIGHLIGHT
	return part

func _test_fitting() -> void:
	var part := _part()
	part.transform = Transform3D(Basis.from_euler(Vector3(0.2, 0.4, 0.1)).scaled(Vector3(2, 3, 4)), Vector3(4, 5, 6))
	var content := Node3D.new()
	content.position = Vector3(1, 2, 3)
	content.rotation.y = PI / 2.0
	part.add_child(content)
	_mesh(content, Vector3(2, 4, 6))
	_mesh(part, Vector3.ONE * 0.0001, Vector3(100, 100, 100))
	part.add_child(MeshInstance3D.new())
	add_child(part)
	var shape := part.get_node_or_null("AutoCollider") as CollisionShape3D
	check(shape != null, "assets without colliders receive an AutoCollider")
	if shape != null:
		check(shape.position.is_equal_approx(content.position), "fit uses object-local bounds")
		check(shape.shape.size.is_equal_approx(Vector3(6, 4, 2) * part.collider_padding), "fit handles rotation, scale, padding and tiny meshes")
		check(part.get_pick_center().is_equal_approx(shape.global_position), "inspect pivot is world-space collider centre")
		var before: Vector3 = shape.shape.size
		check(part.refit_collider() and shape.shape.size.is_equal_approx(before), "refitting excludes generated box visuals")
		part.collider_padding = 1.0
		check(part.refit_collider() and shape.shape.size.is_equal_approx(Vector3(6, 4, 2)), "refit updates existing box")
		_mesh(part, Vector3.ONE * 2.0, Vector3(10, 0, 0))
		check(part.refit_collider() and shape.shape.size.is_equal_approx(Vector3(13, 5, 5)), "fit merges multiple mesh bounds")
		check(shape.position.is_equal_approx(Vector3(4.5, 1.5, 1.5)), "merged collider centre")
		part.ignore_meshes_smaller_than = 0.0
		check(part.refit_collider() and shape.shape.size.x > 100.0, "zero size threshold includes tiny distant meshes")
	part.free()

func _test_async_fitting() -> void:
	var part := _part()
	var loader := AsyncContent.new()
	part.add_child(loader)
	add_child(part)
	check(part.get_node_or_null("AutoCollider") == null, "empty async content waits for meshes")
	var mesh := _mesh(loader, Vector3(2, 3, 4))
	loader.stage_loading_finished.emit(true)
	var shape := part.get_node_or_null("AutoCollider") as CollisionShape3D
	check(shape != null, "async completion fits the collider")
	if shape != null:
		mesh.position.x = 3.0
		loader.stage_loading_finished.emit(true)
		check(shape.position.is_equal_approx(Vector3(3, 0, 0)), "reload refits the same collider")
		check(part.find_children("AutoCollider", "CollisionShape3D", true, false).size() == 1, "reload does not duplicate colliders")
	part.free()

func _test_authored_collider() -> void:
	for collider_name in ["AuthoredCollider", "AutoCollider"]:
		var part := _part()
		var shape := CollisionShape3D.new()
		shape.name = collider_name
		shape.shape = BoxShape3D.new()
		shape.shape.size = Vector3(7, 8, 9)
		shape.position = Vector3(1, 0, 0)
		part.add_child(shape)
		var loader := AsyncContent.new()
		part.add_child(loader)
		_mesh(loader, Vector3.ONE)
		add_child(part)
		loader.stage_loading_finished.emit(true)
		check(shape.shape.size == Vector3(7, 8, 9) and shape.position == Vector3(1, 0, 0), "authored and baked colliders survive startup and reload")
		check(part.find_children("*", "CollisionShape3D", true, false).size() == 1, "authored collider is not duplicated")
		part.free()
	var unfitted := _part()
	unfitted.auto_fit_collider = false
	_mesh(unfitted, Vector3.ONE)
	add_child(unfitted)
	check(unfitted.get_node_or_null("AutoCollider") == null, "automatic fitting can be disabled")
	unfitted.free()

func _test_visuals() -> void:
	var parent := Node3D.new()
	add_child(parent)
	var part := _part()
	var mesh := _mesh(part, Vector3.ONE)
	parent.add_child(part)
	var shape := part.get_node("AutoCollider") as CollisionShape3D
	var viz := part.get_node("ColliderViz") as Node3D
	check(not mesh.visible and viz.visible and viz.get_child_count() == 1, "AR shows the hint box instead of real meshes")
	check(viz.get_child(0).material_override.albedo_color == part.hint_color, "hint tint")
	part.visuals_unselected |= PickableObject.VIS_COLLIDER_WIRE
	part.on_deselected()
	check(viz.get_child_count() == 2, "fill and wire can be combined")
	var wire: MeshInstance3D = viz.get_child(1)
	check(wire.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES and wire.mesh.surface_get_array_len(0) == 24, "wire has twelve edges")
	check(is_equal_approx(wire.material_override.albedo_color.a, part.hint_color.a * 3.0), "wire opacity")
	part.on_selected()
	check(mesh.visible and mesh.material_override.albedo_color == part.highlight_color and not viz.visible, "selected AR part is a highlighted ghost mesh")
	part.set_reveal_meshes(true)
	check(mesh.visible and mesh.material_override == null and mesh.material_overlay.albedo_color == part.highlight_color, "inspect mode reveals the selected textured mesh")
	part.on_deselected()
	check(mesh.material_overlay.albedo_color == part.hint_color, "revealed unselected part keeps its hint")
	var statuses: Array = []
	part.status_changed.connect(func(id, value): statuses.append([id, value]))
	part.status = PickableObject.Status.WARNING
	part.status = PickableObject.Status.WARNING
	check(statuses == [["part", PickableObject.Status.WARNING]], "status signal only fires on change")
	check(mesh.material_overlay.albedo_color == part.warning_color, "warning overrides the hint")
	var marker := part.find_children("*", "Label3D", true, false)[0] as Label3D
	part._process(0.0)
	check(marker.visible and part.is_processing() and marker.global_position.y > shape.global_position.y, "warning marker follows above the part")
	part.on_selected()
	check(mesh.material_overlay.albedo_color == part.highlight_color, "selection overrides warning tint")
	part.disabled = true
	check(shape.disabled and not mesh.visible and not viz.visible and not marker.visible and not part.is_processing(), "disabled part has no collider or visuals")
	part.disabled = false
	part.status = PickableObject.Status.NORMAL
	check(not shape.disabled and not marker.visible and not part.is_processing(), "reenabling restores collider; normal status hides marker")
	parent.hide()
	check(shape.disabled, "hidden ancestors disable picking")
	parent.show()
	check(not shape.disabled, "showing ancestors restores picking")
	parent.free()

func _test_picking() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 8)
	add_child(camera)
	camera.make_current()
	var picker := ObjectPicker.new()
	camera.add_child(picker)
	var near_part := _part()
	var far_part := _part()
	near_part.object_id = "near"
	far_part.object_id = "far"
	far_part.position.z = -4
	_mesh(near_part, Vector3.ONE)
	_mesh(far_part, Vector3.ONE)
	add_child(near_part)
	add_child(far_part)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(picker._pick_box(camera.position, Vector3(0, 0, -8)) == near_part, "ray picks nearest box")
	var events: Array = []
	picker.object_selected.connect(func(id): events.append(id))
	picker.selection_cleared.connect(func(): events.append(null))
	picker.select(far_part)
	picker.select(far_part)
	picker.select(null)
	check(events == ["far", null] and picker.get_selected() == null, "programmatic selection and clearing")
	var centre := get_viewport().get_visible_rect().size * 0.5
	_touch(picker, 0, true, centre)
	_touch(picker, 0, false, centre)
	check(picker.get_selected() == near_part, "single-finger tap selects")
	picker.select(null)
	_touch(picker, 0, true, centre)
	_touch(picker, 1, true, centre + Vector2(30, 0))
	_touch(picker, 1, false, centre + Vector2(30, 0))
	_touch(picker, 0, false, centre)
	check(picker.get_selected() == null, "pinch does not select")
	_touch(picker, 0, true, centre)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = centre + Vector2(30, 0)
	picker._unhandled_input(drag)
	_touch(picker, 0, false, centre)
	check(picker.get_selected() == null, "drag returning to its origin is not a tap")
	near_part.hide()
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(picker._pick_box(camera.position, Vector3(0, 0, -8)) == far_part, "hidden boxes do not intercept picks")
	far_part.disabled = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(picker._pick_box(camera.position, Vector3(0, 0, -8)) == null, "disabled boxes do not intercept picks")
	camera.free()
	near_part.free()
	far_part.free()

func _touch(picker: ObjectPicker, index: int, pressed: bool, position: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = pressed
	event.position = position
	picker._unhandled_input(event)

func check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
		print_stack()
