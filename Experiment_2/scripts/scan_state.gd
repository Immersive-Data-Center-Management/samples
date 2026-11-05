extends FlowState

## Step 3: scan QR codes until the right part is found. Each QR code holds the AAS shell id of
## the part it is stuck on. A wrong part tells the technician where the right one is.

@export var task_state: FlowState

@onready var hint_label: Label = %HintLabel
@onready var result_label: Label = %ResultLabel
@onready var qr: QRCodeTrackedComponent = $QRCodeTrackedComponent

## Desktop has no camera: type or paste a QR content here to simulate a scan.
@onready var debug_input: LineEdit = %DebugInput
## Shown once the right part is found: the technician confirms before the inspection opens.
@onready var continue_button: Button = %ContinueButton
## Draws a check or cross on every QR code in view (Android only, needs screen bounds).
@onready var marks: Control = %Marks

## QR codes currently in view: content -> true if it is the part to find.
var _seen := {}


func _ready() -> void:
	qr.matched_found.connect(_on_scanned)
	qr.matched_lost.connect(_on_lost)
	continue_button.pressed.connect(finish)
	marks.draw.connect(_draw_marks)
	%BackButton.pressed.connect(func(): go_to(task_state))
	debug_input.text_submitted.connect(_on_scanned)
	debug_input.visible = ARCoreInterfaceInstance.get_interface() == null


func enter_state() -> void:
	_set_scanning(true)
	var t := AppData.task
	hint_label.text = "Find %s (%s, U %s) and scan its QR code." % [t["identifier"], AppData.RACK_NAME, t["position_from"]]
	result_label.text = ""
	continue_button.hide()
	_seen.clear()
	marks.queue_redraw()
	debug_input.text = t.get("shell_id", "")


func exit_state() -> void:
	_set_scanning(false)


func _set_scanning(on: bool) -> void:
	var ar := get_tree().get_first_node_in_group("arcore_init") as ARCoreInit
	if ar and ar.arcore_started:
		ar.set_feature_enabled(ARCoreInit.FEAT_QR_SCANNING, on)


func _on_scanned(data: String) -> void:
	if not can_process():  # the QR component keeps listening while another state is active
		return
	var target: Dictionary = AppData.task
	_seen[data] = data == target.get("shell_id")
	if _seen[data]:
		result_label.text = "✅  Right part: %s (U %s)" % [target["identifier"], target["position_from"]]
		continue_button.text = "Check %s  →" % target["identifier"]
		continue_button.show()
		return
	if continue_button.visible:
		return  # right part already found: keep its message, other codes only get their ✗
	var other := AppData.component_by_shell(data)
	if other.is_empty():
		result_label.text = "❌  This code is not a part of %s." % AppData.RACK_NAME
		return
	var diff := int(target["position_from"]) - int(other["position_from"])
	var where := "%d U above" % diff if diff > 0 else "%d U below" % -diff
	result_label.text = "❌  This is %s (U %s).\nYou are looking for %s, %s." % [
		other["identifier"], other["position_from"], target["identifier"], where]


func _on_lost(data: String) -> void:
	_seen.erase(data)
	marks.queue_redraw()
	if data == AppData.task.get("shell_id") and continue_button.visible:
		continue_button.hide()  # right part out of view: scan it again before going on
		result_label.text = "Right part out of view. Point the camera at %s again." % AppData.task["identifier"]


func _process(_delta: float) -> void:
	if not _seen.is_empty():
		marks.queue_redraw()  # the codes move with the camera image


func _draw_marks() -> void:
	# Screen bounds are window pixels; map them into Marks' local space (the state is DPI-scaled).
	var to_local := (marks.get_viewport().get_final_transform() * marks.get_global_transform_with_canvas()).affine_inverse()
	for data in _seen:
		var r: Rect2 = to_local * ARCoreInterfaceInstance.qr_scanner_get_detected_screen_bounds(data)
		if not r.has_area():
			continue
		var ok: bool = _seen[data]
		var col := Color(0.2, 0.85, 0.3) if ok else Color(0.95, 0.25, 0.2)
		var c := r.get_center()
		var s := clampf(minf(r.size.x, r.size.y) * 0.3, 24.0, 80.0)
		marks.draw_rect(r, col, false, 6.0)
		marks.draw_circle(c, s * 1.2, Color(1, 1, 1, 0.85))
		if ok:
			marks.draw_polyline([c + Vector2(-0.6, 0.0) * s, c + Vector2(-0.15, 0.5) * s, c + Vector2(0.7, -0.5) * s], col, 10.0)
		else:
			marks.draw_line(c + Vector2(-0.55, -0.55) * s, c + Vector2(0.55, 0.55) * s, col, 10.0)
			marks.draw_line(c + Vector2(0.55, -0.55) * s, c + Vector2(-0.55, 0.55) * s, col, 10.0)
