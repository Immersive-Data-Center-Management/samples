extends FloatingPanel
class_name DataInspector

## Details of the selected shell/component: optional rack placement rows plus
## the top-level elements of its AAS nameplate submodel.

const NAMEPLATE_SEMANTIC_ID := "https://admin-shell.io/idta/nameplate/3/0/Nameplate"
const HINT := "Click an object in the 3D view or the hierarchy to see its details."

@onready var selection_label: Label = %Selection
@onready var status_label: Label = %Status
@onready var rows: VBoxContainer = %Rows

var _aas: AasService
var _request_serial := 0


func _ready() -> void:
	super()
	_aas = AasService.new()
	add_child(_aas)
	clear()


## External API: show the nameplate of a shell (e.g. the rack).
func set_selected_shell(shell_id: String) -> void:
	_show_shell(shell_id, "", {})


## External API: show an installed component. `details` (label -> value) is
## shown above the nameplate, e.g. the rack height and position.
func set_selected_component(identifier: String, shell_id: String, details := {}) -> void:
	_show_shell(shell_id, identifier, details)


func clear() -> void:
	_request_serial += 1
	_clear_rows()
	selection_label.text = ""
	status_label.text = HINT


func _show_shell(shell_id: String, identifier: String, details: Dictionary) -> void:
	_request_serial += 1
	var serial := _request_serial

	_clear_rows()
	selection_label.text = identifier if not identifier.is_empty() else shell_id
	for key in details:
		_add_row(str(key), str(details[key]))
	status_label.text = "Loading nameplate…"

	var submodel := await _aas.find_submodel_by_semantic_id(shell_id, NAMEPLATE_SEMANTIC_ID)
	if serial != _request_serial:
		return
	if submodel.is_empty():
		status_label.text = "No nameplate found."
		return

	# Rack view: keep the hint so users know components are selectable.
	status_label.text = HINT if identifier.is_empty() else ""
	_add_row("Nameplate", "")
	for element in submodel.get("submodelElements", []):
		if element is Dictionary:
			_add_row(str(element.get("idShort", "")), AasService.element_text(element))


func _add_row(key: String, value: String) -> void:
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = key if value.is_empty() else "%s: %s" % [key, value]
	label.tooltip_text = label.text
	rows.add_child(label)


func _clear_rows() -> void:
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
