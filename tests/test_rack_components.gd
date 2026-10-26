extends Node

## Offline checks for RackComponents parsing and session layer. Run:
##   godot --headless --path . res://tests/test_rack_components.tscn

func _ready() -> void:
	var comp := RackComponents.parse_installed_component({"idShort": "Srv1", "value": [
		{"modelType": "Entity", "idShort": "Asset", "globalAssetId": "urn:a"},
		{"modelType": "Property", "idShort": "HeightUnits", "value": "2"},
		{"modelType": "Property", "idShort": "PositionFrom", "value": "10"},
	]})
	assert(comp["identifier"] == "Srv1" and comp["global_asset_id"] == "urn:a")
	assert(comp["height_units"] == "2" and comp["position_from"] == "10")
	assert(RackComponents.parse_installed_component({}).is_empty())

	var unplaced := RackComponents.parse_installed_component({"idShort": "NoModel"})
	comp["model_url"] = "http://h/s.usdc"
	var layer := RackComponents.session_layer([unplaced, comp])
	assert(comp["prim_name"] == "AAS_Component_0" and not unplaced.has("prim_name"))
	assert(layer.contains("prepend payload = @http://h/s.usdc@"))
	assert(layer.contains("(0, 0, 0.444500)"))
	assert(RackComponents.session_layer([unplaced]) == "")

	print("test_rack_components: OK")
	get_tree().quit()
