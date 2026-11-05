extends Node
class_name AasSession

## The logged-in AAS session: server URL, access token and user name. Register it as an autoload
## (e.g. "Session", the name must differ from the class name), log in once with [method login],
## then create clients with [method new_aas_service], also before the login: every login updates
## all clients it created. When the server rejects the token (HTTP 401), [signal expired] fires
## once, so the app can return to its login screen.

## Emitted once when a request was rejected with HTTP 401.
signal expired

var base_url := ""
var auth_token := ""
## Display name of the user (the token's "name" claim), e.g. for reports.
var user_name := ""
## Why the last [method login] failed, ready to show to the user.
var error_text := ""
## Shown once on the login screen, e.g. after the session expired. Read it with [method take_message].
var _message := ""

var _keycloak: KeycloakLogin
var _clients := []  # AasServices made by new_aas_service(), updated on login


func _ready() -> void:
	_keycloak = KeycloakLogin.new()
	add_child(_keycloak)


## Logs in at the Keycloak server of [param aas_url]. Returns false and sets [member error_text]
## on failure.
func login(aas_url: String, user: String, password: String) -> bool:
	var token := await _keycloak.login(aas_url, user, password)
	error_text = _keycloak.error_text
	if token.is_empty():
		return false
	_set_login(aas_url, token)
	return true


func _set_login(aas_url: String, token: String) -> void:
	base_url = aas_url
	auth_token = token
	user_name = KeycloakLogin.token_claim(token, "name")
	_clients = _clients.filter(is_instance_valid)
	for client in _clients:
		client.base_url = base_url
		client.auth_token = auth_token


func is_logged_in() -> bool:
	return not auth_token.is_empty()


## An AasService for this session; add it to the tree before use. It follows later logins.
func new_aas_service() -> AasService:
	var aas := AasService.new()
	aas.base_url = base_url
	aas.auth_token = auth_token
	aas.unauthorized.connect(_on_unauthorized)
	_clients.append(aas)
	return aas


## The message for the login screen ("" if none); cleared once read.
func take_message() -> String:
	var m := _message
	_message = ""
	return m


func _on_unauthorized() -> void:
	if auth_token.is_empty():
		return  # another request already reported it
	auth_token = ""
	_message = "Session expired. Please log in again."
	expired.emit()
