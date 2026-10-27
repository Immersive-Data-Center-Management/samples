extends FloatingPanel
class_name SceneTreeView

## Hierarchy panel: the rack shell as root, its installed components below.
## Clicks emit item_selected; select() mirrors a selection made elsewhere.

## identifier is "" for the rack, else the component identifier.
signal item_selected(identifier: String)

@onready var _tree: Tree = %ComponentTree


func _ready() -> void:
	super()
	_tree.item_selected.connect(func(): item_selected.emit(_tree.get_selected().get_metadata(0)))


## Rebuilds the tree: rack shell as root, one child per component.
func populate(rack_shell_id: String, components: Array) -> void:
	_tree.clear()
	var root := _tree.create_item()
	root.set_text(0, rack_shell_id.get_file())
	root.set_tooltip_text(0, rack_shell_id)
	root.set_metadata(0, "")
	for comp in components:
		var item := _tree.create_item(root)
		item.set_text(0, comp["identifier"])
		item.set_metadata(0, comp["identifier"])


## Selects the item of a component (or the root for "") without emitting
## item_selected, so 3D picks can mirror their selection here. null clears it.
func select(identifier: Variant) -> void:
	_tree.set_block_signals(true)
	_tree.deselect_all()
	var item := _tree.get_root()
	while item != null and identifier != null:
		if item.get_metadata(0) == identifier:
			item.select(0)
			_tree.scroll_to_item(item)
			break
		item = item.get_next_in_tree()
	_tree.set_block_signals(false)
