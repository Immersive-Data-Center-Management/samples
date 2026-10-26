extends Node3D

## 3D rack screen. Loads the rack USD picked on the item list, reads the rack's
## installed components from the AAS (RackComponents) and reloads the stage
## with a session layer that adds the component models in their rack slots.
##
## Selection: a 3D pick (StageSelection) or a hierarchy click selects the rack
## (""), a component (its identifier) or nothing (null). _select() mirrors it
## to the 3D highlight, the hierarchy and the inspector.
## The OrbitCamera focuses the selection on F; its child light follows the view.

@onready var stage_node: Node3D = $UsdStageNode3D
@onready var selection: StageSelection = $StageSelection
@onready var back_button: Button = %BackButton
@onready var status_label: Label = %StatusLabel
@onready var scene_tree_view: SceneTreeView = %SceneTreeView
@onready var data_inspector: DataInspector = %DataInspector

var _components: Array = []
var _aas: AasService


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	selection.picked.connect(_select)
	scene_tree_view.item_selected.connect(_select)

	var url := AppState.selected_item_url
	if url.is_empty():
		status_label.text = "No model URL provided."
		return
	stage_node.set_stage_uri(url)
	scene_tree_view.populate(AppState.selected_shell_id, _components)
	_select(null)

	_aas = AasService.new()
	add_child(_aas)
	status_label.text = "Loading components..."
	_components = await RackComponents.fetch(_aas, AppState.selected_shell_id)
	selection.components = _components
	scene_tree_view.populate(AppState.selected_shell_id, _components)
	await RackComponents.resolve_models(_aas, _components)
	_apply_session_layer()
	status_label.text = ""


func _apply_session_layer() -> void:
	var layer := RackComponents.session_layer(_components)
	if layer.is_empty():
		return
	stage_node.set_meta(&"USD_OVERRIDE_LAYER", layer)
	stage_node.set_meta(&"USD_OVERRIDE_LAYERID", "user://aas_models/local_composition.usd")
	# set_stage_uri with an unchanged value would not reload the stage
	stage_node.set_stage_uri("")
	stage_node.set_stage_uri(AppState.selected_item_url)


# --- Selection ---

func _select(identifier: Variant) -> void:
	selection.highlight(identifier)
	scene_tree_view.select(identifier)
	if identifier == null:
		data_inspector.clear()
		return
	var comp := selection.component_by(&"identifier", str(identifier))
	if comp.is_empty():
		data_inspector.set_selected_shell(AppState.selected_shell_id)
		return
	var shell_id: String = comp["shell_id"] if not comp["shell_id"].is_empty() else AppState.selected_shell_id
	data_inspector.set_selected_component(comp["identifier"], shell_id, {
		"Height": "%s U" % comp["height_units"],
		"Position": "U %s" % comp["position_from"],
	})


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/screens/item_list_screen.tscn")
