extends Control

## Login screen. Gets a Keycloak access token (password grant) for the entered
## AAS server, stores token and URL in AppState and opens the item list.
## Enter in any field submits.

@onready var url_input: LineEdit = $MarginContainer/VBoxContainer/UrlInput
@onready var username_input: LineEdit = $MarginContainer/VBoxContainer/UsernameInput
@onready var password_input: LineEdit = $MarginContainer/VBoxContainer/PasswordInput
@onready var login_button: Button = $MarginContainer/VBoxContainer/LoginButton
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var http_request: HTTPRequest = $HTTPRequest

const CLIENT_ID := "basyx-client-api"
const KEYCLOAK_PORT := 8180
const REALM := "BaSyx"


func _ready() -> void:
	login_button.pressed.connect(_on_login_pressed)
	for input in [url_input, username_input, password_input]:
		input.text_submitted.connect(func(_text): if not login_button.disabled: _on_login_pressed())
	http_request.timeout = 10.0
	http_request.request_completed.connect(_on_token_request_completed)
	status_label.text = AppState.login_message
	AppState.login_message = ""
	_check_idtxflow()


## The IDTXFlow GDExtension is not in the repo; bootstrap.ps1 downloads it.
## Without it UsdStageNode3D is unknown and the 3D viewer breaks, so block login.
func _check_idtxflow() -> void:
	if ClassDB.class_exists("UsdStageNode3D"):
		return
	var message := (
		"IDTXFlow extension is missing. Close Godot, run bootstrap.ps1 and restart\n"
		+ "(see README, \"Run the app\").")
	push_error(message)
	status_label.text = message
	login_button.disabled = true


func _on_login_pressed() -> void:
	var base_url := url_input.text.strip_edges().rstrip("/")
	var user_name := username_input.text.strip_edges()
	var user_pass := password_input.text

	if base_url.is_empty() or user_name.is_empty() or user_pass.is_empty():
		status_label.text = "Please fill in all fields."
		return

	var token_url := _keycloak_token_url(base_url)
	if token_url.is_empty():
		status_label.text = "Server URL must start with http:// or https://."
		return

	login_button.disabled = true
	status_label.text = "Logging in..."

	var body := (
		"grant_type=password"
		+ "&client_id=" + CLIENT_ID.uri_encode()
		+ "&username=" + user_name.uri_encode()
		+ "&password=" + user_pass.uri_encode()
		+ "&scope=openid"
	)

	var headers := ["Content-Type: application/x-www-form-urlencoded"]
	var error := http_request.request(token_url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		status_label.text = "Failed to send request: " + str(error)
		login_button.disabled = false


## Derives the Keycloak token endpoint from the AAS URL: same host, port 8180.
func _keycloak_token_url(aas_url: String) -> String:
	var scheme_end := aas_url.find("://")
	if scheme_end < 0:
		return ""
	var host_start := scheme_end + 3
	var path_start := aas_url.find("/", host_start)
	var authority := aas_url.substr(host_start, path_start - host_start if path_start >= 0 else -1)
	var host := authority.get_slice(":", 0)
	if host.is_empty():
		return ""
	var scheme := aas_url.substr(0, scheme_end)
	return "%s://%s:%d/realms/%s/protocol/openid-connect/token" % [
		scheme, host, KEYCLOAK_PORT, REALM]


## Plain-language text for a failed token request. Names the Keycloak URL,
## because that (not the AAS URL) is what the request tried to reach.
func _connection_error_text(result: int) -> String:
	var server := _keycloak_token_url(url_input.text.strip_edges().rstrip("/")).get_slice("/realms/", 0)
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR, \
		HTTPRequest.RESULT_TIMEOUT, HTTPRequest.RESULT_NO_RESPONSE:
			return (
				"Could not reach the login server at %s.\n" % server
				+ "Is the demo stack running? Start it with \"docker compose up -d\" in Experiment_1/deploy\n"
				+ "(see README, \"Demo stack\").")
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "Unknown host %s. Check the Server URL." % server
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS error at %s. Does the server use https?" % server
	return "Connection error at %s (HTTPRequest result %d)." % [server, result]


func _on_token_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	login_button.disabled = false

	if result != HTTPRequest.RESULT_SUCCESS:
		status_label.text = _connection_error_text(result)
		return

	if response_code != 200:
		status_label.text = "Authentication failed (HTTP %d)" % response_code
		return

	var json := JSON.new()
	var parse_error := json.parse(body.get_string_from_utf8())
	if parse_error != OK:
		status_label.text = "Failed to parse response."
		return

	var data: Dictionary = json.data
	if not data.has("access_token"):
		status_label.text = "No access token in response."
		return

	# Store state and navigate to item list
	AppState.auth_token = data["access_token"]
	AppState.base_url = url_input.text.strip_edges().rstrip("/")

	status_label.text = "Login successful! Loading..."
	get_tree().change_scene_to_file("res://scenes/screens/item_list_screen.tscn")
