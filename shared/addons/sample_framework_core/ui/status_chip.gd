extends Button
class_name StatusChip

## Small button that counts the [PickableObject]s in [constant PickableObject.Status.WARNING]
## (found via the "pickable_object" group and visible in the tree, so e.g. content of an image
## target that is not found yet is not counted) and hides itself while there are none. Pressing it
## selects the next warning object through the [ObjectPicker] (group "ar_object_picker"), as if
## it had been tapped, and emits [signal focused] so the app can e.g. centre the camera on it.

## Emitted after a warning object was selected by pressing the chip.
signal focused(obj: PickableObject)

## Text when exactly one / several objects warn. "%d" is replaced by the count.
@export var text_one := "⚠ 1 warning"
@export var text_many := "⚠ %d warnings"

var _next := 0

func _ready() -> void:
	pressed.connect(_on_pressed)
	visible = false
	# Pickables register in their own _ready; connect once the whole scene is in.
	_connect_pickables.call_deferred()

func _connect_pickables() -> void:
	for obj in get_tree().get_nodes_in_group("pickable_object"):
		if not obj.status_changed.is_connected(_on_status_changed):
			obj.status_changed.connect(_on_status_changed)
	refresh()

## Recount the warning objects and update text/visibility. Call it when pickables are shown or hidden.
func refresh() -> void:
	var count := _warnings().size()
	visible = count > 0
	text = text_one if count == 1 else text_many % count

func _on_status_changed(_object_id: String, _status: int) -> void:
	refresh()

func _on_pressed() -> void:
	var list := _warnings()
	var picker := get_tree().get_first_node_in_group("ar_object_picker")
	if list.is_empty() or picker == null:
		return
	_next = (_next + 1) % list.size()
	picker.select(list[_next])
	focused.emit(list[_next])

func _warnings() -> Array[PickableObject]:
	var result: Array[PickableObject] = []
	for obj in get_tree().get_nodes_in_group("pickable_object"):
		if obj is PickableObject and obj.status == PickableObject.Status.WARNING and not obj.disabled and obj.is_visible_in_tree():
			result.append(obj)
	return result
