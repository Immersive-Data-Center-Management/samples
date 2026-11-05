extends FlowState

## Step 2: the rack list. Lists every AAS shell with a bill of material (HierarchicalStructures)
## submodel; a double click stores the rack's shell id and USD model URL in AppData and opens the 3D viewer.

@onready var item_list: ItemList = $MarginContainer/VBoxContainer/ItemList
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var source_label: Label = $MarginContainer/VBoxContainer/SourceLabel
@onready var back_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/BackButton

## Back button target.
@export var login_state: FlowState

var _aas: AasService


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	item_list.item_activated.connect(_on_item_double_clicked)
	_aas = Session.new_aas_service()
	add_child(_aas)


func enter_state() -> void:
	_load_racks()


## Lists every shell that has a bill of material (HierarchicalStructures) submodel, labelled with its
## idShort, nameplate product designation and how many components are installed (from the bill of
## material). Components are browsed inside the rack.
func _load_racks() -> void:
	status_label.text = "Loading racks..."
	source_label.text = ("Every AAS shell on %s with a bill of material (IDTA HierarchicalStructures) is a rack. "
		+ "Product from its Nameplate, installed parts from the bill of material, 3D model from Models3D.") % Session.base_url
	var boms := {}
	for sm in await _aas.fetch_submodels_by_semantic_id(RackComponents.BOM_SEMANTIC_ID):
		boms[str(sm.get("id", ""))] = RackComponents.parse_bom(sm)
	var model_urls := {}
	for sm in await _aas.fetch_submodels_by_semantic_id(RackComponents.MODELS3D_SEMANTIC_ID):
		model_urls[str(sm.get("id", ""))] = _aas.reachable_url(AasService.find_file_value(sm))
	var products := {}
	for sm in await _aas.fetch_submodels_by_semantic_id(RackComponents.NAMEPLATE_SEMANTIC_ID):
		products[str(sm.get("id", ""))] = AasService.element_texts(sm).get("ManufacturerProductDesignation", "")

	var racks: Array = []
	for shell in await _aas.fetch_all_shells():
		var sm_ids := AasService.extract_submodel_ids(shell)
		if not sm_ids.any(func(id): return boms.has(id)):
			continue
		var rack := {"shell_id": str(shell.get("id", "")), "url": "", "label": str(shell.get("idShort", ""))}
		var parts := ""
		for id in sm_ids:
			if model_urls.has(id):
				rack["url"] = model_urls[id]
			if not str(products.get(id, "")).is_empty():
				rack["label"] += "  –  " + products[id]
			if boms.has(id):
				var units := 0
				for comp in boms[id]:
					units += int(comp["height_units"])
				parts = "  ·  %d components installed, %d U used" % [boms[id].size(), units]
		rack["label"] += parts
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


func _on_item_double_clicked(index: int) -> void:
	var rack: Dictionary = item_list.get_item_metadata(index)
	if str(rack["url"]).is_empty():
		status_label.text = "Selected rack has no 3D model."
		return
	AppData.selected_item_url = rack["url"]
	AppData.selected_shell_id = rack["shell_id"]
	finish()


func _on_back_pressed() -> void:
	go_to(login_state)
