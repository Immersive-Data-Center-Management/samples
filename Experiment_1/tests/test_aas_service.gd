extends Node

## Offline checks for AasService parsing helpers. Run:
##   godot --headless --path . res://tests/test_aas_service.tscn

func _ready() -> void:
	# base64url, no padding ("?" encodes to "/" in plain base64)
	assert(AasService.encode_id("urn:x?") == "dXJuOng_")
	assert(AasService.encode_id("a") == "YQ")

	var shell := {"submodels": [
		{"type": "ModelReference", "keys": [{"type": "Submodel", "value": "sm-1"}]},
		{"type": "ModelReference", "keys": []},
	]}
	assert(AasService.extract_submodel_ids(shell) == ["sm-1"])

	var submodel := {
		"semanticId": {"keys": [{"type": "GlobalReference", "value": "urn:sem"}]},
		"submodelElements": [
			{"modelType": "Property", "idShort": "P", "value": "x"},
			{"modelType": "File", "idShort": "USDFile", "value": "http://h/a.usd"},
		],
	}
	assert(AasService.submodel_semantic_id_matches(submodel, "urn:sem"))
	assert(not AasService.submodel_semantic_id_matches(submodel, "urn:other"))
	assert(AasService.find_file_value(submodel) == "http://h/a.usd")
	assert(AasService.find_file_value({}) == "")

	assert(AasService.element_text({"value": "SRV-1"}) == "SRV-1")
	assert(AasService.element_text({"value": [
		{"language": "de", "text": "Server"}, {"language": "en", "text": "Rack Server"},
	]}) == "Rack Server")

	print("test_aas_service: OK")
	get_tree().quit()
