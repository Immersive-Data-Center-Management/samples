extends Node
class_name StateManager

## Runs a linear or branching app flow made of FlowState children: exactly one
## state is active (processing + visible) at a time. States switch by calling
## [method FlowState.finish] / [method FlowState.go_to]; wire the order with each
## state's [member FlowState.next_state] in the scene.

## State to start in. Set to a later state to skip steps while testing.
@export var start_state: FlowState

## Currently active state, kept so its UI can be re-scaled when the viewport size changes
## (e.g. when ARCore enables use_xr and the render target resizes).
var _active_state: FlowState = null

func _ready() -> void:
	get_viewport().size_changed.connect(_on_viewport_resized)
	# Start every state deactivated, then bring up only the start state.
	for child in get_children():
		if child is FlowState:
			child.change_requested.connect(change_state)
			_deactivate_state(child)
		else:
			# Usually a state whose script failed to parse: it would stay visible on top of the others.
			push_error("StateManager: child '%s' is not a FlowState (script missing or failed to load)." % child.name)
	_activate_state(start_state)

## Deactivates the current state and activates [param state].
func change_state(state: FlowState) -> void:
	if state == null or state == _active_state:
		return
	print("StateManager: %s -> %s" % [_active_state.name if _active_state else "-", state.name])
	_deactivate_state(_active_state)
	_activate_state(state)

func _activate_state(state: FlowState) -> void:
	if state == null:
		return

	state.process_mode = Node.PROCESS_MODE_INHERIT
	_set_state_visuals(state, true)
	_active_state = state
	_scale_state_ui(state)
	state.enter_state()


func _deactivate_state(state: FlowState) -> void:
	if state == null:
		return

	state.exit_state()

	_set_state_visuals(state, false)
	state.process_mode = Node.PROCESS_MODE_DISABLED


func _set_state_visuals(node: Node, make_visible: bool) -> void:
	if node is CanvasItem:
		(node as CanvasItem).visible = make_visible
	elif node is Node3D:
		(node as Node3D).visible = make_visible

	# CanvasItem visibility is not derived through non-CanvasItem parents,
	# so keep CanvasItem descendants in sync with the state root.
	_set_canvas_items_visible_recursive(node, make_visible)


func _set_canvas_items_visible_recursive(node: Node, make_visible: bool) -> void:
	for child in node.get_children():
		# CanvasLayer is not a CanvasItem but has its own visible flag (HUDs of 3D states).
		if child is CanvasItem or child is CanvasLayer:
			# Only the topmost ones: their children inherit it. Touching those would show
			# nodes the state hid itself (e.g. a full-screen flash overlay).
			if child.get_parent() is CanvasItem:
				continue
			child.visible = make_visible
		if not (child is CanvasItem or child is CanvasLayer):
			_set_canvas_items_visible_recursive(child, make_visible)


## DPI-scales a state's top-level UI. The Viewport's content_scale_factor is ignored while
## ARCore has use_xr enabled, but a Control's scale is baked into 2D canvas rendering and
## survives XR. We size each top-level Control to viewport/factor and scale it up by factor,
## so anchored children still fill the screen — just at a larger physical size.
func _scale_state_ui(state: FlowState) -> void:
	var f := get_ui_scale()
	var logical := Vector2(get_viewport().get_visible_rect().size) / f
	# A Control state is one screen: scale the state itself, so its own anchored layout (e.g. a
	# top/bottom split) is kept. A Node3D state holds its UI as top-level Control children.
	var node: Node = state  # FlowState extends Node; a scene may still use a Control as the state root
	var roots: Array = [node] if node is Control else node.get_children()
	for child in roots:
		if child is Control:
			var c := child as Control
			c.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
			c.pivot_offset = Vector2.ZERO
			c.scale = Vector2(f, f)
			c.size = logical


func _on_viewport_resized() -> void:
	# use_xr resizes the viewport after startup; re-scale the active state's UI to match.
	if _active_state:
		_scale_state_ui(_active_state)


## DPI the UI was laid out against. The canvas_items stretch only scales by resolution, not
## physical density, so on high-DPI phones the UI is physically tiny. We scale the UI by
## (device_dpi / REFERENCE_DPI) so physical UI size stays consistent across devices.
## Raise this to make the UI smaller, lower it to make the UI bigger.
const REFERENCE_DPI := 240.0
## Clamp so unusual DPI reports can't blow the layout up or shrink it below the design size.
const MIN_SCALE := 1.0
const MAX_SCALE := 3.0

## Returns the UI scale factor for the current display density, so the UI is roughly the same
## physical size on all devices.
static func get_ui_scale() -> float:
	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0:
		return 1.0 # DisplayServer couldn't report a density; don't scale.
	return clampf(float(dpi) / REFERENCE_DPI, MIN_SCALE, MAX_SCALE)
