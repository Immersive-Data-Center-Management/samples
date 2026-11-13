extends FlowState

## Step 2: the task. Reads every component of the rack and its live OperationalData from the
## AAS. A component reporting "unreachable" becomes a (fictional) service ticket for the
## technician role: "Check DemoServer02". The rack is shown in 3D with that part marked, so the
## technician knows where to go. Also shows the last report sent for it (LastInspection), if any.

@export var scan_state: FlowState

@onready var title_label: Label = %TitleLabel
@onready var detail_label: Label = %DetailLabel
@onready var check_button: Button = %CheckButton
@onready var report_button: Button = %ReportButton
@onready var report_label: Label = %ReportLabel
@onready var refresh_button: Button = %RefreshButton
@onready var ticket: Control = %Ticket
@onready var status_label: Label = %StatusLabel
@onready var busy: ProgressBar = %Busy
@onready var viewer: Control = %ViewerContainer
@onready var viewer_hint: Label = %ViewerHint
@onready var stage_node: Node3D = %ViewerContainer.get_node("Viewer/UsdStageNode3D")
@onready var selection: StageSelection = %ViewerContainer.get_node("Viewer/StageSelection")
@onready var orbit: OrbitController = %ViewerContainer.get_node("Viewer/Camera/OrbitController")

var _aas: AasService
var _report: Dictionary = {}
var _rack_loaded := false


func _ready() -> void:
	check_button.pressed.connect(func(): go_to(scan_state))
	report_button.pressed.connect(func(): report_label.visible = not report_label.visible)
	refresh_button.pressed.connect(_load)
	stage_node.stage_loading_finished.connect(func(_ok): _focus_part())


func enter_state() -> void:
	if _aas == null:
		_aas = Session.new_aas_service()
		add_child(_aas)
	%RoleLabel.text = "👷 You are: %s" % Session.user_name
	_load()


func _load() -> void:
	check_button.hide()
	report_button.hide()
	report_label.hide()
	ticket.hide()
	viewer.hide()
	viewer_hint.hide()
	status_label.text = "Checking rack status…"
	busy.show()
	refresh_button.disabled = true
	await _check_rack()
	busy.hide()
	refresh_button.disabled = false


## Reads the rack (once) and the status of each component, one request per component,
## so it shows how far it got.
func _check_rack() -> void:
	if AppData.components.is_empty():
		var comps := await RackComponents.fetch(_aas, AppData.RACK_SHELL_ID)
		await RackComponents.resolve_models(_aas, comps)
		AppData.components = comps

	AppData.task = {}
	var unread := 0
	for i in AppData.components.size():
		var comp: Dictionary = AppData.components[i]
		status_label.text = "Checking rack status…\ncomponent %d / %d" % [i + 1, AppData.components.size()]
		var values := await _operational_values(comp)
		if not values.has("Status"):
			unread += 1  # read failed (connection, token); must not count as "OK"
		elif str(values["Status"]) == "unreachable":
			AppData.task = comp
			_report = values.get("LastInspection", {})
			break

	if AppData.components.is_empty():
		status_label.text = "No rack data
Could not read %s from the AAS. Is the seed finished?" % AppData.RACK_SHELL_ID
		return
	if AppData.task.is_empty() and unread > 0:
		status_label.text = "Status unknown
Could not read the status of %d components. Check the connection and refresh." % unread
		return
	if AppData.task.is_empty():
		status_label.text = "No open tickets
All %d components of %s report OK." % [AppData.components.size(), AppData.RACK_NAME]
		return

	var t := AppData.task
	status_label.text = ""
	title_label.text = "Check %s" % t["identifier"]
	detail_label.text = "It stopped reporting. Go to %s, U %s, and find out why." % [AppData.RACK_NAME, t["position_from"]]
	ticket.show()
	viewer.show()
	viewer_hint.text = "The marked part is %s · drag to rotate" % t["identifier"]
	viewer_hint.show()
	_show_rack()
	check_button.show()
	report_button.show()
	report_button.disabled = _report.is_empty()
	report_button.text = "Last report" if not _report.is_empty() else "No report yet"
	report_label.text = format_report(_report)


## The rack model with every component in its slot, built from the AAS (RackComponents). Loaded
## once; a new task only moves the highlight.
func _show_rack() -> void:
	if _rack_loaded:
		_focus_part()
		return
	_rack_loaded = true
	var sm := await _aas.find_submodel_by_semantic_id(AppData.RACK_SHELL_ID, RackComponents.MODELS3D_SEMANTIC_ID)
	selection.components = AppData.components
	RackComponents.load_rack(stage_node, _aas.reachable_url(AasService.find_file_value(sm)), AppData.components)


## stage_loading_finished fires before the payload meshes are in the tree, so retry briefly.
func _focus_part() -> void:
	for attempt in 20:
		await get_tree().create_timer(0.25).timeout
		if AppData.task.is_empty():
			return
		selection.highlight(AppData.task["identifier"])
		if selection.has_selection():
			# Frame the part from the front (-Y in USD is +Z here) with some rack around it,
			# so the technician sees where it sits; the rack's sides are closed.
			orbit.yaw = 0.0
			orbit.pitch = deg_to_rad(15.0)
			var part := selection.selected_bounds()
			orbit.focus(AABB(part.get_center() - Vector3(0.3, 0.3, 0.05), Vector3(0.6, 0.6, 0.1)))
			return


## OperationalData values of [param comp] ({} if it has none). Caches the submodel id on comp.
func _operational_values(comp: Dictionary) -> Dictionary:
	if not comp.has("operational_id"):
		var sm := await _aas.find_submodel_by_semantic_id(comp["shell_id"], RackComponents.OPERATIONAL_SEMANTIC_ID)
		comp["operational_id"] = str(sm.get("id", ""))
	if comp["operational_id"].is_empty():
		return {}
	return await _aas.fetch_submodel_values(comp["operational_id"])


## One-line summary of a LastInspection value, e.g. "30.10. 14:12 · Alex · Lights off · photo taken".
static func format_report(report: Dictionary) -> String:
	if report.is_empty():
		return ""
	var time := str(report.get("Timestamp", "")).replace("T", " ").left(16)
	var parts := [time, report.get("Inspector", ""), report.get("Finding", "")]
	if str(report.get("PhotoTaken", "")) == "true":
		parts.append("photo taken")
	return " · ".join(parts.filter(func(p): return not str(p).is_empty()))
