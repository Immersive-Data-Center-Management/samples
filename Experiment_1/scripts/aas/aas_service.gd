extends Node
class_name AasService

## Minimal authenticated AAS V3 (BaSyx) client.
##
## Owns one HTTPRequest and expects callers to await its methods. Endpoint and
## bearer token come from AppState. On HTTP 401 the session is ended via
## AppState.session_expired(), which returns the app to the login screen.

var _http: HTTPRequest
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = false
	_http.timeout = 30.0
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


## Returns the value of the first top-level File element (the USD URL in the
## 3dAssets submodel), or "" when there is none.
static func find_file_value(submodel: Dictionary) -> String:
	var elements: Variant = submodel.get("submodelElements")
	if not (elements is Array):
		return ""
	for element in elements:
		if element is Dictionary and element.get("modelType") == "File" and element.get("value") is String:
			return element["value"]
	return ""


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


func _request_json(path: String) -> Variant:
	# One HTTPRequest cannot serve two callers; serialize overlapping requests
	# instead of letting the second one fail with ERR_BUSY.
	while _busy:
		await get_tree().process_frame
	_busy = true
	var response: Variant = await _request_json_locked(AppState.base_url.rstrip("/") + path)
	_busy = false
	return response


func _request_json_locked(url: String) -> Variant:
	if AppState.base_url.is_empty() or AppState.auth_token.is_empty():
		return null

	var headers := PackedStringArray([
		"Authorization: Bearer " + AppState.auth_token,
		"Accept: application/json",
	])
	var err := _http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		push_warning("AasService: request failed (err=%d) for %s" % [err, url])
		return null

	var response: Array = await _http.request_completed
	var result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		push_warning("AasService: transport error (result=%d) for %s" % [result, url])
		return null
	if response_code == 401:
		AppState.session_expired()
		return null
	if response_code < 200 or response_code >= 300:
		push_warning("AasService: HTTP %d for %s" % [response_code, url])
		return null

	var text := body.get_string_from_utf8()
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_warning("AasService: invalid JSON for %s" % url)
	return parsed


## AAS identifiers are base64url encoded (RFC 4648, no padding).
static func encode_id(value: String) -> String:
	return Marshalls.utf8_to_base64(value).replace("+", "-").replace("/", "_").rstrip("=")
