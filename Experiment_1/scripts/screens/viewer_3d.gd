extends FlowState

## Step 3: the 3D rack. Loads the rack USD picked on the item list, reads the rack's
## installed components from the AAS (RackComponents) and reloads the stage
## with a session layer that adds the component models in their rack slots.
##
## Selection: a 3D pick (StageSelection) or a hierarchy click selects the rack
## (""), a component (its identifier) or nothing (null). _select() mirrors it
## to the 3D highlight, the hierarchy and the inspector.
## The camera orbits around a picked part; F zooms to the selection.

@onready var stage_node: Node3D = $UsdStageNode3D
@onready var selection: StageSelection = $StageSelection
@onready var orbit: OrbitController = $Camera/OrbitController
@onready var back_button: Button = %BackButton
@onready var status_label: Label = %StatusLabel
@onready var scene_tree_view: SceneTreeView = %SceneTreeView
@onready var data_inspector: DataInspector = %DataInspector

var _components: Array = []
var _aas: AasService
var _loaded_shell_id := ""
## True while the stage with all components (load_rack) is loading; the rack alone loads first.
var _loading_components := false


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	selection.picked.connect(_select)
	scene_tree_view.item_selected.connect(_select)
	stage_node.stage_loading_finished.connect(_on_stage_loaded)
	_aas = Session.new_aas_service()
	add_child(_aas)


func enter_state() -> void:
	var url := AppData.selected_item_url
	# Compare the rack, not its model URL: all demo racks share ServerRack.usdc.
	if AppData.selected_shell_id == _loaded_shell_id:
		return  # same rack as last time: keep camera and selection
	_loaded_shell_id = AppData.selected_shell_id
	if url.is_empty():
		status_label.text = "No model URL provided."
		return
	stage_node.set_stage_uri(url)
	scene_tree_view.populate(AppData.selected_shell_id, _components)
	_select(null)

	status_label.text = "Reading installed components from the AAS…"
	_components = await RackComponents.fetch(_aas, AppData.selected_shell_id)
	selection.components = _components
	scene_tree_view.populate(AppData.selected_shell_id, _components)
	await RackComponents.resolve_models(_aas, _components)
	status_label.text = "Loading %d component models…" % _components.size()
	_loading_components = true
	RackComponents.load_rack(stage_node, url, _components)


func _on_stage_loaded(ok: bool) -> void:
	if not ok:
		status_label.text = "Loading the 3D model failed."
		_loading_components = false
		return
	if _loading_components:
		_loading_components = false
		status_label.text = ""
	# Frame the rack once its meshes are in (they arrive a moment after the signal).
	get_tree().create_timer(0.5).timeout.connect(_frame_rack)


func _frame_rack() -> void:
	selection.highlight("")
	if selection.has_selection():
		orbit.focus(selection.selected_bounds())
	selection.highlight(null)


# --- Selection ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F and selection.has_selection():
		orbit.focus(selection.selected_bounds())


func _select(identifier: Variant) -> void:
	selection.highlight(identifier)
	if selection.has_selection():
		orbit.set_pivot(selection.selected_bounds().get_center())
	scene_tree_view.select(identifier)
	if identifier == null:
		data_inspector.clear()
		return
	var comp := selection.component_by(&"identifier", str(identifier))
	if comp.is_empty():
		data_inspector.set_selected_shell(AppData.selected_shell_id)
		return
	var shell_id: String = comp["shell_id"] if not comp["shell_id"].is_empty() else AppData.selected_shell_id
	data_inspector.set_selected_component(comp["identifier"], shell_id, {
		"Height": "%s U" % comp["height_units"],
		"Position": "U %s" % comp["position_from"],
	})


func _on_back_pressed() -> void:
	finish()
