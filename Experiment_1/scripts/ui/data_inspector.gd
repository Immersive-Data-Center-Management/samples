extends FloatingPanel
class_name DataInspector

## Details of the selected shell/component: optional rack placement rows, the top-level
## elements of its AAS nameplate submodel and, for components, the live values of its
## OperationalData submodel (written by the demo stack's simulator), re-read every few seconds.

const HINT := "Click an object in the 3D view or the hierarchy to see its details."
## Live values shown, in this order.
const LIVE_KEYS := ["Status", "Temperature", "PowerDraw"]
const POLL_SECONDS := 3.0

@onready var selection_label: Label = %Selection
@onready var status_label: Label = %Status
@onready var rows: PropertyList = %Rows

var _aas: AasService
## Incremented on every new selection; a request that finishes for an older one is dropped.
var _request_serial := 0
## Rows that don't change while a part is selected: placement details and the nameplate.
var _details := {}
var _nameplate := {}
## OperationalData of the selected component ("" for the rack) and its last values.
var _live_submodel_id := ""
var _live := {}
var _poll := Timer.new()


func _ready() -> void:
	super()
	_aas = Session.new_aas_service()
	add_child(_aas)
	_poll.wait_time = POLL_SECONDS
	_poll.timeout.connect(_refresh_live)
	add_child(_poll)
	clear()


## External API: show the nameplate of a shell (e.g. the rack).
func set_selected_shell(shell_id: String) -> void:
	_show_shell(shell_id, "", {})


## External API: show an installed component. `details` (label -> value) is
## shown above the nameplate, e.g. the rack height and position.
func set_selected_component(identifier: String, shell_id: String, details := {}) -> void:
	_show_shell(shell_id, identifier, details)


func clear() -> void:
	_reset({})
	selection_label.text = ""
	status_label.text = HINT


## Stops polling while the panel is hidden (e.g. the viewer is left); resumes when shown again.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _poll.is_inside_tree():
		if is_visible_in_tree() and not _live_submodel_id.is_empty():
			_poll.start()
		else:
			_poll.stop()


func _reset(details: Dictionary) -> void:
	_request_serial += 1
	_poll.stop()
	_details = details
	_nameplate = {}
	_live_submodel_id = ""
	_live = {}
	_render()


func _show_shell(shell_id: String, identifier: String, details: Dictionary) -> void:
	_reset(details)
	var serial := _request_serial
	selection_label.text = identifier if not identifier.is_empty() else shell_id
	status_label.text = "Loading nameplate…"

	var submodel := await _aas.find_submodel_by_semantic_id(shell_id, RackComponents.NAMEPLATE_SEMANTIC_ID)
	if serial != _request_serial:
		return
	if submodel.is_empty():
		status_label.text = "No nameplate found."
		return
	# Rack view: keep the hint so users know components are selectable.
	status_label.text = HINT if identifier.is_empty() else ""
	_nameplate = AasService.element_texts(submodel)
	_render()

	# Only components have live data; the rack shell has no OperationalData.
	var live := await _aas.find_submodel_by_semantic_id(shell_id, RackComponents.OPERATIONAL_SEMANTIC_ID)
	if serial != _request_serial or live.is_empty():
		return
	_live_submodel_id = str(live.get("id", ""))
	_refresh_live()
	_poll.start()


func _refresh_live() -> void:
	var serial := _request_serial
	var values := await _aas.fetch_submodel_values(_live_submodel_id)
	if serial != _request_serial:
		return
	_live = {}
	for key in LIVE_KEYS:
		var v := str(values.get(key, ""))
		_live[key] = v if not v.is_empty() else "no data"
	_render()


func _render() -> void:
	rows.clear()
	for key in _details:
		rows.add_row(str(key), str(_details[key]))
	if not _nameplate.is_empty():
		rows.add_heading("Nameplate (AAS)")
		for key in _nameplate:
			rows.add_row(key, _nameplate[key])
	if not _live.is_empty():
		rows.add_heading("Live data (AAS OperationalData, every %d s)" % POLL_SECONDS)
		for key in _live:
			rows.add_row(key, _live[key])
