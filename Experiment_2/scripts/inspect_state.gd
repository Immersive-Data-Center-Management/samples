extends FlowState

## Step 4: on site at the right part. The camera image of the real part on top, its nameplate
## and live data below. The technician takes a photo, picks a finding and sends the report back
## into the AAS (LastInspection of the part's OperationalData).

## Visual findings offered in the dropdown.
const FINDINGS := [
	"Lights off, no fan noise",
	"Lights on, fans running",
	"Error LED on",
	"Cable unplugged",
]
## Display names of the AAS elements shown (idShort -> label).
const LABELS := {
	"ManufacturerProductDesignation": "Product",
	"SerialNumber": "Serial number",
	"Status": "Status",
	"Temperature": "Temperature",
	"PowerDraw": "Power draw",
}
## How often the live values are re-read while this screen is open.
const POLL_SECONDS := 3.0

@onready var title_label: Label = %TitleLabel
@onready var data_list: PropertyList = %Data
@onready var finding: OptionButton = %Finding
@onready var photo_button: Button = %PhotoButton
@onready var photo_rect: TextureRect = %Photo
@onready var send_button: Button = %SendButton
@onready var status_label: Label = %StatusLabel
@onready var ui: Control = $UI
@onready var background: Control = $Background

var _aas: AasService
var _nameplate := {}
var _photo_taken := false
var _poll := 0.0
var _refreshing := false


func _ready() -> void:
	for f in FINDINGS:
		finding.add_item(f)
	photo_button.pressed.connect(_on_photo_pressed)
	send_button.pressed.connect(_on_send_pressed)
	%NoCameraLabel.visible = not OS.has_feature("mobile")


func enter_state() -> void:
	if _aas == null:
		_aas = Session.new_aas_service()
		add_child(_aas)
	_photo_taken = false
	photo_rect.texture = null
	photo_button.text = "Take photo"
	send_button.disabled = false
	status_label.text = ""
	var t := AppData.task
	title_label.text = "%s  ·  U %s" % [t["identifier"], t["position_from"]]
	_load_nameplate(t)
	_refresh_live()


func _load_nameplate(comp: Dictionary) -> void:
	var texts := AasService.element_texts(await _aas.find_submodel_by_semantic_id(comp["shell_id"], RackComponents.NAMEPLATE_SEMANTIC_ID))
	_nameplate = {}
	for key in ["ManufacturerProductDesignation", "SerialNumber"]:
		if texts.has(key):
			_nameplate[LABELS[key]] = texts[key]


func _process(delta: float) -> void:
	_poll += delta
	if _poll >= POLL_SECONDS:
		_poll = 0.0
		_refresh_live()


func _refresh_live() -> void:
	if _refreshing:  # a slow server must not pile up polls in front of "Send report"
		return
	_refreshing = true
	var values := await _aas.fetch_submodel_values(AppData.task.get("operational_id", ""))
	_refreshing = false
	var props := _nameplate.duplicate()
	for key in ["Status", "Temperature", "PowerDraw"]:
		var v := str(values.get(key, ""))
		props[LABELS[key]] = v if not v.is_empty() else "no data"
	data_list.show_props(props)


func _on_photo_pressed() -> void:
	# The camera feed is the main viewport's background; hide the panel for the shot.
	var img := await ScreenCapture.capture(get_viewport(), [ui, background, %NoCameraLabel])
	photo_rect.texture = ImageTexture.create_from_image(img)
	_photo_taken = true
	photo_button.text = "✓ Photo taken · retake"
	# Short white flash, like a camera shutter.
	var flash: ColorRect = %Flash
	flash.modulate.a = 0.8
	flash.show()
	await create_tween().tween_property(flash, "modulate:a", 0.0, 0.3).finished
	flash.hide()


func _on_send_pressed() -> void:
	send_button.disabled = true
	status_label.text = "Sending report…"
	var report := {
		"modelType": "SubmodelElementCollection",
		"idShort": "LastInspection",
		"value": [
			_prop("Timestamp", Time.get_datetime_string_from_system(true) + "Z"),
			_prop("Inspector", Session.user_name),
			_prop("Finding", finding.get_item_text(finding.selected)),
			_prop("PhotoTaken", str(_photo_taken)),
		],
	}
	if await _aas.put_submodel_element(AppData.task["operational_id"], report):
		status_label.text = "Report sent."
		await get_tree().create_timer(1.2).timeout
		finish()
	else:
		status_label.text = "Sending failed. Check the connection and try again."
		send_button.disabled = false


static func _prop(id_short: String, value: String) -> Dictionary:
	return {"modelType": "Property", "idShort": id_short, "valueType": "xs:string", "value": value}
