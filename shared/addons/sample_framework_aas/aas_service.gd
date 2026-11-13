extends Node
class_name AasService

## Minimal authenticated AAS V3 (BaSyx) client.
##
## Owns one HTTPRequest and expects callers to await its methods. Set
## [member base_url] and [member auth_token] (e.g. from KeycloakLogin) before the
## first request. On HTTP 401 [signal unauthorized] is emitted so the app can send
## the user back to its login screen.

## Emitted on HTTP 401 (token expired or rejected).
signal unauthorized

## AAS server root, e.g. "http://127.0.0.1:8081".
var base_url := ""
## Keycloak access token, sent as bearer token.
var auth_token := ""

var _http: HTTPRequest
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = false
	_http.timeout = 10.0
	add_child(_http)


func fetch_all_shells() -> Array:
	return await _fetch_all_pages("/shells")


func fetch_submodels_by_semantic_id(semantic_id: String) -> Array:
	return await _fetch_all_pages("/submodels?semanticId=" + encode_id(semantic_id))


## Returns the submodel references of a shell. Each entry is an AAS Reference.
func fetch_submodel_refs(shell_id: String) -> Array:
	var response: Variant = await _request_json("/shells/" + encode_id(shell_id) + "/submodel-refs")
	if response is Dictionary and response.get("result") is Array:
		return response["result"]
	return []


## Returns the full submodel document, or {} on failure.
func fetch_submodel(submodel_id: String) -> Dictionary:
	var response: Variant = await _request_json("/submodels/" + encode_id(submodel_id))
	return response if response is Dictionary else {}


## Returns the submodel's values only (BaSyx "$value" view): {idShort: value, ...} with
## collections as nested dictionaries. {} on failure. Cheap enough to poll for live data.
func fetch_submodel_values(submodel_id: String) -> Dictionary:
	var response: Variant = await _request_json("/submodels/" + encode_id(submodel_id) + "/$value")
	return response if response is Dictionary else {}


## Replaces the top-level element [param element] (must carry its idShort) of a submodel.
## Returns true on success. The element has to exist already; see the seed for why.
func put_submodel_element(submodel_id: String, element: Dictionary) -> bool:
	var path := "/submodels/%s/submodel-elements/%s" % [encode_id(submodel_id), str(element.get("idShort", "")).uri_encode()]
	var result: Variant = await _request_json(path, HTTPClient.METHOD_PUT, element)
	return result != null


## Walks the shell's submodel refs and returns the first submodel whose
## semanticId matches. Returns {} when there is no match.
func find_submodel_by_semantic_id(shell_id: String, semantic_id: String) -> Dictionary:
	var ids: Array = []
	for ref in await fetch_submodel_refs(shell_id):
		ids.append(_reference_id(ref))
	return await find_submodel(ids, semantic_id)


## Fetches the given submodels in order and returns the first one whose
## semanticId matches. Returns {} when there is no match.
func find_submodel(submodel_ids: Array, semantic_id: String) -> Dictionary:
	for submodel_id in submodel_ids:
		if str(submodel_id).is_empty():
			continue
		var submodel := await fetch_submodel(submodel_id)
		if not submodel.is_empty() and submodel_semantic_id_matches(submodel, semantic_id):
			return submodel
	return {}


## Returns the submodel ids referenced by the inline `submodels[]` array of a
## shell (AAS V3 id is the value of the last key).
static func extract_submodel_ids(shell: Dictionary) -> Array:
	var ids: Array = []
	if not (shell.get("submodels") is Array):
		return ids
	for entry in shell["submodels"]:
		var id := _reference_id(entry)
		if not id.is_empty():
			ids.append(id)
	return ids


## Display text of a Property, or the English text of a MultiLanguageProperty.
static func element_text(element: Dictionary) -> String:
	var value: Variant = element.get("value", "")
	if value is Array:
		for text in value:
			if text is Dictionary and text.get("language") == "en":
				return str(text.get("text", ""))
		return ""
	return str(value)


## {idShort: display text} of the top-level elements of a submodel, e.g. a nameplate.
static func element_texts(submodel: Dictionary) -> Dictionary:
	var texts := {}
	for element in submodel.get("submodelElements", []):
		if element is Dictionary:
			texts[str(element.get("idShort", ""))] = element_text(element)
	return texts


## Returns the value of the first File element with idShort [param id_short] at any depth, or ""
## when there is none. Default: the USD URL in an IDTA Models3D submodel
## (Model3D[0].File.FileVersion[0].DigitalFile).
static func find_file_value(submodel: Dictionary, id_short := "DigitalFile") -> String:
	return _find_file_value(submodel.get("submodelElements"), id_short)


static func _find_file_value(elements: Variant, id_short: String) -> String:
	if not (elements is Array):
		return ""
	for element in elements:
		if not (element is Dictionary):
			continue
		if element.get("modelType") == "File" and element.get("idShort") == id_short and element.get("value") is String:
			return element["value"]
		var found := _find_file_value(element.get("value"), id_short)
		if not found.is_empty():
			return found
	return ""


## The demo seed stores asset URLs on 127.0.0.1, which only works on the PC itself. On a phone
## the app reaches the stack via the PC's address, so rewrite loopback hosts in [param url] to
## the host of [member base_url]. URLs on any other host are returned unchanged.
func reachable_url(url: String) -> String:
	for loopback in ["://127.0.0.1:", "://localhost:"]:
		if url.contains(loopback):
			var host := base_url.get_slice("://", 1).get_slice("/", 0).get_slice(":", 0)
			if not host.is_empty():
				return url.replace(loopback, "://%s:" % host)
	return url


static func submodel_semantic_id_matches(submodel: Dictionary, semantic_id: String) -> bool:
	var semantic: Variant = submodel.get("semanticId")
	if not (semantic is Dictionary):
		return false
	var keys: Variant = semantic.get("keys")
	if not (keys is Array):
		return false
	for key in keys:
		if key is Dictionary and key.get("value") == semantic_id:
			return true
	return false


static func _reference_id(reference: Variant) -> String:
	if not (reference is Dictionary):
		return ""
	var keys: Variant = reference.get("keys")
	if not (keys is Array) or keys.is_empty():
		return ""
	var last_key: Variant = keys[keys.size() - 1]
	if last_key is Dictionary and last_key.get("value") is String:
		return last_key["value"]
	return ""


## Follows `paging_metadata.cursor` and returns the concatenated `result` arrays.
func _fetch_all_pages(path: String) -> Array:
	var items: Array = []
	var cursor: String = ""

	# Defend against a server that keeps returning the same non-empty cursor.
	const MAX_PAGES := 1000
	for _page in MAX_PAGES:
		var page_path := path
		if not cursor.is_empty():
			page_path += ("&" if path.contains("?") else "?") + "cursor=" + cursor.uri_encode()

		var response: Variant = await _request_json(page_path)
		if not (response is Dictionary):
			break

		var result: Variant = response.get("result", [])
		if result is Array:
			items.append_array(result)

		cursor = ""
		var paging: Variant = response.get("paging_metadata", {})
		if paging is Dictionary and paging.get("cursor") is String:
			cursor = paging["cursor"]

		if cursor.is_empty():
			break

	return items


## GET returns the parsed JSON, or null on failure. Writes (with [param payload]) return
## true on success (BaSyx answers 204 without a body), null on failure.
func _request_json(path: String, method := HTTPClient.METHOD_GET, payload: Variant = null) -> Variant:
	# One HTTPRequest cannot serve two callers; serialize overlapping requests
	# instead of letting the second one fail with ERR_BUSY.
	while _busy:
		await get_tree().process_frame
	_busy = true
	var response: Variant = await _request_json_locked(base_url.rstrip("/") + path, method, payload)
	_busy = false
	return response


func _request_json_locked(url: String, method: int, payload: Variant) -> Variant:
	if base_url.is_empty() or auth_token.is_empty():
		return null

	var headers := PackedStringArray([
		"Authorization: Bearer " + auth_token,
		"Accept: application/json",
	])
	var body := ""
	if payload != null:
		headers.append("Content-Type: application/json")
		body = JSON.stringify(payload)
	var err := _http.request(url, headers, method, body)
	if err != OK:
		push_warning("AasService: request failed (err=%d) for %s" % [err, url])
		return null

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var response_code: int = response[1]

	if result != HTTPRequest.RESULT_SUCCESS:
		push_warning("AasService: transport error (result=%d) for %s" % [result, url])
		return null
	if response_code == 401:
		unauthorized.emit()
		return null
	if response_code < 200 or response_code >= 300:
		push_warning("AasService: HTTP %d for %s" % [response_code, url])
		return null

	var text := (response[3] as PackedByteArray).get_string_from_utf8()
	if text.is_empty():
		return true if method != HTTPClient.METHOD_GET else null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_warning("AasService: invalid JSON for %s" % url)
	return parsed


## AAS identifiers are base64url encoded (RFC 4648, no padding).
static func encode_id(value: String) -> String:
	return Marshalls.utf8_to_base64(value).replace("+", "-").replace("/", "_").rstrip("=")
