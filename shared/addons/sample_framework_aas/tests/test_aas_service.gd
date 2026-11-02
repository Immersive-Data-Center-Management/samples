extends Node

var _failed := false

## Offline checks for AasService parsing helpers. Run:
##   godot --headless --path Experiment_1 res://addons/sample_framework_aas/tests/test_aas_service.tscn  (see shared/tests/README.md)

func _ready() -> void:
	# base64url, no padding ("?" encodes to "/" in plain base64)
	check(AasService.encode_id("urn:x?") == "dXJuOng_")
	check(AasService.encode_id("a") == "YQ")

	var shell := {"submodels": [
		{"type": "ModelReference", "keys": [{"type": "Submodel", "value": "sm-1"}]},
		{"type": "ModelReference", "keys": []},
	]}
	check(AasService.extract_submodel_ids(shell) == ["sm-1"])

	var submodel := {
		"semanticId": {"keys": [{"type": "GlobalReference", "value": "urn:sem"}]},
		"submodelElements": [
			{"modelType": "Property", "idShort": "P", "value": "x"},
			# Models3D shape: Model3D[0].File.FileVersion[0].{PreviewFile, DigitalFile}
			{"modelType": "SubmodelElementList", "idShort": "Model3D", "value": [
				{"modelType": "SubmodelElementCollection", "value": [
					{"modelType": "SubmodelElementCollection", "idShort": "File", "value": [
						{"modelType": "SubmodelElementList", "idShort": "FileVersion", "value": [
							{"modelType": "SubmodelElementCollection", "value": [
								{"modelType": "File", "idShort": "PreviewFile", "contentType": "image/png"},
								{"modelType": "File", "idShort": "DigitalFile", "value": "http://h/a.usd"},
							]},
						]},
					]},
				]},
			]},
		],
	}
	check(AasService.submodel_semantic_id_matches(submodel, "urn:sem"))
	check(not AasService.submodel_semantic_id_matches(submodel, "urn:other"))
	check(AasService.find_file_value(submodel) == "http://h/a.usd")
	check(AasService.find_file_value(submodel, "PreviewFile") == "")
	check(AasService.find_file_value({}) == "")

	check(AasService.element_text({"value": "SRV-1"}) == "SRV-1")
	check(AasService.element_text({"value": [
		{"language": "de", "text": "Server"}, {"language": "en", "text": "Rack Server"},
	]}) == "Rack Server")

	check(KeycloakLogin.token_url_for("http://192.168.1.20:8081/") ==
		"http://192.168.1.20:8180/realms/BaSyx/protocol/openid-connect/token")
	check(KeycloakLogin.token_url_for("127.0.0.1:8081") == "")

	# header.payload.signature, payload {"name":"Alex Technician"} base64url without padding
	var jwt := "x." + Marshalls.utf8_to_base64('{"name":"Alex Technician"}').replace("+", "-").replace("/", "_").rstrip("=") + ".y"
	check(KeycloakLogin.token_claim(jwt, "name") == "Alex Technician")
	check(KeycloakLogin.token_claim("garbage", "name") == "")

	var aas := AasService.new()
	aas.base_url = "http://192.168.1.20:8081"
	check(aas.reachable_url("http://127.0.0.1:8080/api/v1/download/a.usdc") == "http://192.168.1.20:8080/api/v1/download/a.usdc")
	check(aas.reachable_url("https://assets.example.com/a.usdc") == "https://assets.example.com/a.usdc")
	aas.free()

	# AasSession: a 401 from any of its clients expires the session once and leaves a message.
	var session := AasSession.new()
	add_child(session)
	session.base_url = "http://h:8081"
	session.auth_token = "t"
	var expired := [0]
	session.expired.connect(func(): expired[0] += 1)
	var client := session.new_aas_service()
	check(client.base_url == "http://h:8081" and client.auth_token == "t")
	client.unauthorized.emit()
	client.unauthorized.emit()  # a second failing request must not expire it again
	check(expired[0] == 1 and not session.is_logged_in())
	check(session.take_message() != "" and session.take_message() == "")
	# Clients created before a login follow it.
	session._set_login("http://new:8081", jwt)
	check(client.base_url == "http://new:8081" and client.auth_token == jwt)
	check(session.user_name == "Alex Technician" and session.is_logged_in())
	client.free()
	session.free()

	print("test_aas_service: FAILED" if _failed else "test_aas_service: OK")
	get_tree().quit(1 if _failed else 0)



## Like assert(), but a failed run exits with code 1 (a failed assert() only pauses headless
## Godot, so the run never ends). The printed stack has the line number.
func check(ok: bool) -> void:
	if not ok:
		_failed = true
		push_error("check failed")
		print_stack()
