extends Node

var _failed := false

## Offline checks for RackComponents parsing and session layer. Run:
##   godot --headless --path Experiment_1 res://addons/sample_framework_aas/tests/test_rack_components.tscn  (see shared/tests/README.md)

func _ready() -> void:
	var bom := {"submodelElements": [
		{"modelType": "Property", "idShort": "ArcheType", "value": "OneDown"},
		{"modelType": "Entity", "idShort": "EntryNode", "globalAssetId": "urn:rack", "statements": [
			{"modelType": "Entity", "idShort": "Srv1", "globalAssetId": "urn:a", "statements": [
				{"modelType": "Property", "idShort": "HeightUnits", "value": "2"},
				{"modelType": "Property", "idShort": "PositionFrom", "value": "10"},
			]},
			{"modelType": "RelationshipElement", "idShort": "HasPart_Srv1"},
		]},
	]}
	var parsed := RackComponents.parse_bom(bom)
	check(parsed.size() == 1)
	var comp: Dictionary = parsed[0]
	check(comp["identifier"] == "Srv1" and comp["global_asset_id"] == "urn:a")
	check(comp["height_units"] == "2" and comp["position_from"] == "10")
	check(RackComponents.parse_installed_component({}).is_empty())

	var unplaced := RackComponents.parse_installed_component({"idShort": "NoModel"})
	comp["model_url"] = "http://h/s.usdc"
	var layer := RackComponents.session_layer([unplaced, comp])
	check(comp["prim_name"] == "AAS_Component_0" and not unplaced.has("prim_name"))
	check(layer.contains("prepend payload = @http://h/s.usdc@"))
	check(layer.contains("(0, 0, 0.542500)"))
	check(RackComponents.session_layer([unplaced]) == "")

	print("test_rack_components: FAILED" if _failed else "test_rack_components: OK")
	get_tree().quit(1 if _failed else 0)



## Like assert(), but a failed run exits with code 1 (a failed assert() only pauses headless
## Godot, so the run never ends). The printed stack has the line number.
func check(ok: bool) -> void:
	if not ok:
		_failed = true
		push_error("check failed")
		print_stack()
