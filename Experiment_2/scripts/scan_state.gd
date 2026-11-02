extends FlowState

## Step 3: scan QR codes until the right part is found. Each QR code holds the AAS shell id of
## the part it is stuck on. A wrong part tells the technician where the right one is.

@export var task_state: FlowState

@onready var hint_label: Label = %HintLabel
@onready var result_label: Label = %ResultLabel
@onready var qr: QRCodeTrackedComponent = $QRCodeTrackedComponent

## Desktop has no camera: type or paste a QR content here to simulate a scan.
@onready var debug_input: LineEdit = %DebugInput


func _ready() -> void:
	qr.matched_found.connect(_on_scanned)
	%BackButton.pressed.connect(func(): go_to(task_state))
	debug_input.text_submitted.connect(_on_scanned)
	debug_input.visible = ARCoreInterfaceInstance.get_interface() == null


func enter_state() -> void:
	_set_scanning(true)
	var t := AppData.task
	hint_label.text = "Find %s (%s, U %s) and scan its QR code." % [t["identifier"], AppData.RACK_NAME, t["position_from"]]
	result_label.text = ""
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
	if data == target.get("shell_id"):
		result_label.text = "✅  Right part: %s" % target["identifier"]
		finish.call_deferred()
		return
	var other := AppData.component_by_shell(data)
	if other.is_empty():
		result_label.text = "❌  This code is not a part of %s." % AppData.RACK_NAME
		return
	var diff := int(target["position_from"]) - int(other["position_from"])
	var where := "%d U above" % diff if diff > 0 else "%d U below" % -diff
	result_label.text = "❌  This is %s (U %s).\nYou are looking for %s, %s." % [
		other["identifier"], other["position_from"], target["identifier"], where]
