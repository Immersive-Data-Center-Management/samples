extends FlowState

## The AR view with two independent toggles: "Freeze" holds the camera image (parts stay
## tappable), "3D view" shows the rack without the camera image to orbit around it; closing it
## returns to live or frozen AR, whichever was on. Both live on the inspect camera
## (ar_inspect_camera.gd), found via the "ar_inspect_controller" group.
##
## Also acts as the controller for object picking: it listens to the ObjectPicker (found via
## the "ar_object_picker" group), looks the selected object's data up in AppData, and drives
## the bottom slide-in menu (which only handles the display).
##
## Picking uses PickableObject + ObjectPicker, not StageSelection like Experiments 1 and 2: the
## parts are separate USD files with local data (no AAS), and AR needs ARCore's tap ray, hint
## boxes over the camera image and a status per part. Details at the top of pickable_object.gd.

@onready var toggle_freeze_ar: CheckButton = %Toggle_FreezeAR
@onready var toggle_3d_view: CheckButton = %Toggle_3DView
@onready var menu = $UI/BottomSlideInMenu
@onready var mode_label: Label = %ModeLabel
@onready var scan_hint: Label = $UI/ScanHint
@onready var status_chip: StatusChip = %StatusChip
@onready var tracked: ImageTrackedComponent = $ImageTrackedComponent
@onready var telemetry = $FakeTelemetry

var _shown_id := ""  # object currently shown in the menu, refreshed on each telemetry update
var _setup_error := ""  # e.g. IDTXFlow missing; shown instead of the scan hint

func _ready() -> void:
	# Without IDTXFlow the rack models stay empty: keep saying why instead of hiding the hint.
	_setup_error = IdtxFlowCheck.missing_text()
	if not _setup_error.is_empty():
		scan_hint.text = _setup_error

	toggle_freeze_ar.toggled.connect(_on_toggle_freeze_toggled)
	toggle_3d_view.toggled.connect(_on_toggle_3d_view_toggled)
	tracked.image_found.connect(func(_t): scan_hint.visible = not _setup_error.is_empty())
	# The chip counts only visible parts, so recount when the rack appears or disappears.
	tracked.image_found.connect(func(_t): status_chip.refresh())
	tracked.image_lost.connect(status_chip.refresh)
	tracked.image_lost.connect(func(): scan_hint.visible = not (toggle_freeze_ar.button_pressed or toggle_3d_view.button_pressed))
	telemetry.updated.connect(_on_telemetry_updated)
	status_chip.focused.connect(func(_obj): _on_center_pressed())

	# "Center" button in the bottom menu → reframe the selected object.
	if menu and menu.has_signal("center_pressed"):
		menu.center_pressed.connect(_on_center_pressed)
		# Centring only moves the 3D view camera; enabled while that view is open.
		menu.set_center_enabled(false)

	# The picker lives in XRSetup, which may not be in the tree yet — try now and again on enter.
	_connect_picker.call_deferred()

func enter_state() -> void:
	_connect_picker()
	# Desktop / editor run (no ARCore): show the image-tracked content at its scene position so
	# picking and the 3D view can be tried without a phone.
	scan_hint.show()
	if ARCoreInterfaceInstance.get_interface() == null:
		# ARCore reports an image target with its normal as +Y, so at the identity transform the
		# target lies flat and the rack lies on the floor. Stand it up facing the preview camera,
		# like the printed target on a wall or monitor.
		tracked.basis = Basis(Vector3.RIGHT, PI / 2)
		tracked.simulate_found()
	if menu:
		menu.set_center_enabled(toggle_3d_view.button_pressed)

func _connect_picker() -> void:
	var picker := get_tree().get_first_node_in_group("ar_object_picker")
	if picker == null:
		return
	if not picker.object_selected.is_connected(_on_object_selected):
		picker.object_selected.connect(_on_object_selected)
	if not picker.selection_cleared.is_connected(_on_selection_cleared):
		picker.selection_cleared.connect(_on_selection_cleared)

func _controller() -> ARInspectCamera:
	return get_tree().get_first_node_in_group("ar_inspect_controller") as ARInspectCamera

## "AR", "AR frozen" or "3D view": what the screen currently shows.
func _update_mode() -> void:
	if toggle_3d_view.button_pressed:
		mode_label.text = "3D view"
	else:
		mode_label.text = "AR frozen" if toggle_freeze_ar.button_pressed else "AR"

func _on_object_selected(object_id: String) -> void:
	_shown_id = object_id
	if menu:
		menu.show_object_info(object_id, AppData.get_object_data(object_id))

func _on_selection_cleared() -> void:
	_shown_id = ""
	if menu:
		menu.show_nothing_selected()
		menu.close()

## Live values: re-render the open menu so the selected part's temperature keeps counting.
func _on_telemetry_updated() -> void:
	if menu and menu.is_open() and not _shown_id.is_empty():
		menu.show_object_info(_shown_id, AppData.get_object_data(_shown_id))

func _on_toggle_freeze_toggled(frozen: bool) -> void:
	_controller().set_frozen(frozen)
	_update_mode()

func _on_toggle_3d_view_toggled(active: bool) -> void:
	_controller().set_3d_view(active)
	# Freezing is about the camera image, which the 3D view does not show.
	toggle_freeze_ar.disabled = active
	if menu:
		menu.set_center_enabled(active)
	_update_mode()

## Center button / status chip: reframe the selected object. Only has an effect in the 3D view
## (the inspect camera ignores it otherwise).
func _on_center_pressed() -> void:
	_controller().center_on_selected()
