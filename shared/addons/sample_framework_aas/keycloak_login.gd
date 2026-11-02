extends Node
class_name KeycloakLogin

## Gets a Keycloak access token with the password grant for an AAS server.
## The token URL is derived from the AAS URL: same host, port 8180 (demo stack
## in shared/deploy). Await [method login]; it returns the token or "" and sets
## [member error_text] to a plain-language reason on failure.

const CLIENT_ID := "basyx-client-api"
const KEYCLOAK_PORT := 8180
const REALM := "BaSyx"

## Why the last [method login] failed, ready to show to the user.
var error_text := ""

var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)


## Returns the access token, or "" on failure (see [member error_text]).
func login(aas_url: String, user_name: String, user_pass: String) -> String:
	error_text = ""
	var token_url := token_url_for(aas_url)
	if token_url.is_empty():
		error_text = "Server URL must start with http:// or https://."
		return ""

	var body := (
		"grant_type=password"
		+ "&client_id=" + CLIENT_ID.uri_encode()
		+ "&username=" + user_name.uri_encode()
		+ "&password=" + user_pass.uri_encode()
		+ "&scope=openid"
	)
	var headers := ["Content-Type: application/x-www-form-urlencoded"]
	var err := _http.request(token_url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		error_text = "Failed to send request: " + str(err)
		return ""

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var response_code: int = response[1]
	var response_body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		error_text = connection_error_text(token_url, result)
		return ""
	if response_code != 200:
		error_text = "Authentication failed (HTTP %d)" % response_code
		return ""

	var data: Variant = JSON.parse_string(response_body.get_string_from_utf8())
	if not (data is Dictionary) or not data.has("access_token"):
		error_text = "No access token in response."
		return ""
	return data["access_token"]


## Reads a claim (e.g. "name", "preferred_username") from a JWT access token without verifying
## it; the server verifies tokens, the app only uses this for display. "" if missing.
static func token_claim(token: String, claim: String) -> String:
	var parts := token.split(".")
	if parts.size() < 2:
		return ""
	var payload := parts[1].replace("-", "+").replace("_", "/")
	payload += "=".repeat((4 - payload.length() % 4) % 4)
	var data: Variant = JSON.parse_string(Marshalls.base64_to_utf8(payload))
	return str(data.get(claim, "")) if data is Dictionary else ""


## Derives the Keycloak token endpoint from the AAS URL: same host, port 8180.
static func token_url_for(aas_url: String) -> String:
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
static func connection_error_text(token_url: String, result: int) -> String:
	var server := token_url.get_slice("/realms/", 0)
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR, \
		HTTPRequest.RESULT_TIMEOUT, HTTPRequest.RESULT_NO_RESPONSE:
			return (
				"Could not reach the login server at %s.\n" % server
				+ "Is the demo stack running? Start it with \"docker compose up -d\" in shared/deploy\n"
				+ "(see shared/deploy/README.md). On a phone, use the PC's LAN IP (or 127.0.0.1 with \"adb reverse\").")
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "Unknown host %s. Check the Server URL." % server
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS error at %s. Does the server use https?" % server
	return "Connection error at %s (HTTPRequest result %d)." % [server, result]
