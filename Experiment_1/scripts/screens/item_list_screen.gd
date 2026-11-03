extends Control

## Rack list screen. Lists every AAS shell with a RackUsage submodel; double
## click stores the rack's shell id and USD model URL in AppState and opens
## the 3D viewer.

@onready var item_list: ItemList = $MarginContainer/VBoxContainer/ItemList
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var back_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/BackButton

const SEM_3D := "urn:apeirora.eu:smt:3dAssets:0.1"
const SEM_RACK_USAGE := "urn:apeirora.eu:smt:rackUsage:0.1"
const SEM_NAMEPLATE := "https://admin-shell.io/idta/nameplate/3/0/Nameplate"

var _aas: AasService


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	item_list.item_activated.connect(_on_item_double_clicked)
	_aas = AasService.new()
	add_child(_aas)
	_load_racks()


## Lists every shell that has a RackUsage submodel, labelled with its idShort
## and nameplate product designation. Components are browsed inside the rack.
func _load_racks() -> void:
	status_label.text = "Loading racks..."
	var rack_usage_ids := {}
	for sm in await _aas.fetch_submodels_by_semantic_id(SEM_RACK_USAGE):
		rack_usage_ids[str(sm.get("id", ""))] = true
	var model_urls := {}
	for sm in await _aas.fetch_submodels_by_semantic_id(SEM_3D):
		model_urls[str(sm.get("id", ""))] = AasService.find_file_value(sm)
	var products := {}
	for sm in await _aas.fetch_submodels_by_semantic_id(SEM_NAMEPLATE):
		products[str(sm.get("id", ""))] = _product_designation(sm)

	var racks: Array = []
	for shell in await _aas.fetch_all_shells():
		var sm_ids := AasService.extract_submodel_ids(shell)
		if not sm_ids.any(func(id): return rack_usage_ids.has(id)):
			continue
		var rack := {"shell_id": str(shell.get("id", "")), "url": "", "label": str(shell.get("idShort", ""))}
		for id in sm_ids:
			if model_urls.has(id):
				rack["url"] = model_urls[id]
			if not str(products.get(id, "")).is_empty():
				rack["label"] += "  –  " + products[id]
		racks.append(rack)

	item_list.clear()
	for rack in racks:
		var index := item_list.add_item(rack["label"])
		item_list.set_item_tooltip(index, rack["shell_id"])
		item_list.set_item_metadata(index, rack)

	if racks.is_empty():
		status_label.text = "No racks found."
	else:
		status_label.text = "%d rack(s) found. Double-click to open." % racks.size()


## English ManufacturerProductDesignation of a nameplate, or "".
static func _product_designation(nameplate: Dictionary) -> String:
	for element in nameplate.get("submodelElements", []):
		if element is Dictionary and element.get("idShort") == "ManufacturerProductDesignation":
			return AasService.element_text(element)
	return ""


func _on_item_double_clicked(index: int) -> void:
	var rack: Dictionary = item_list.get_item_metadata(index)
	if str(rack["url"]).is_empty():
		status_label.text = "Selected rack has no 3D model."
		return
	AppState.selected_item_url = rack["url"]
	AppState.selected_shell_id = rack["shell_id"]
	get_tree().change_scene_to_file("res://scenes/screens/viewer_3d.tscn")


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/screens/login_screen.tscn")
