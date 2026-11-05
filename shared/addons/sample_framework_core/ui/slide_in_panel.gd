class_name SlideInPanel
extends Control

## A panel docked to the bottom edge of its parent that slides up to open and down to close.
## While closed, only its top part stays on screen (by default exactly down to the bottom of
## [member handle]), so the handle is always reachable.
##
## Setup: anchor this Control to the bottom of its parent (e.g. the "Bottom Wide" preset), put a
## button at its top as the [member handle], and add your content below it. Horizontal layout is
## up to the scene; the vertical anchors are set to the bottom edge by this script.
##
## Positions are recomputed from the bottom anchor on every update instead of being cached, so
## the panel stays correct when its parent is resized or scaled after startup (e.g. the XR
## viewport resize on Android combined with DPI UI scaling).

signal opened
signal closed

## Height of the fully open panel, in the parent's units.
@export var open_height := 500.0
## Optional button at the top of the panel that toggles it open/closed.
@export var handle: Button
## How much of the panel stays visible while closed. Negative = down to the bottom of [member handle].
@export var peek_height := -1.0
## Duration of the slide animation in seconds.
@export var slide_duration := 0.25
@export var start_open := false
## Optional handle labels per state (the handle text is left unchanged when empty).
@export var handle_text_closed := ""
@export var handle_text_open := ""

var _open := false
var _progress := 0.0 # 0 = closed, 1 = open
var _tween: Tween


func _ready() -> void:
	anchor_top = 1.0
	anchor_bottom = 1.0
	if handle:
		handle.pressed.connect(toggle)
		# The handle's size is only known after container layout (and changes with UI scaling).
		handle.resized.connect(_apply)
	_open = start_open
	_progress = 1.0 if start_open else 0.0
	_update_handle_text()
	_apply()


func open() -> void:
	_slide(true)


func close() -> void:
	_slide(false)


func toggle() -> void:
	_slide(not _open)


func is_open() -> bool:
	return _open


func _slide(to_open: bool) -> void:
	if to_open == _open:
		return
	_open = to_open
	_update_handle_text()
	if _tween:
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_progress, _progress, 1.0 if to_open else 0.0, slide_duration)
	if to_open:
		opened.emit()
	else:
		closed.emit()


func _set_progress(value: float) -> void:
	_progress = value
	_apply()


func _apply() -> void:
	var top := -lerpf(_peek(), open_height, _progress)
	offset_top = top
	offset_bottom = top + open_height


func _peek() -> float:
	if peek_height >= 0.0 or handle == null:
		return maxf(peek_height, 0.0)
	# Bottom edge of the handle in this panel's local space (works through nested containers/scale).
	var handle_bottom := handle.get_global_transform() * Vector2(0.0, handle.size.y)
	return (get_global_transform().affine_inverse() * handle_bottom).y


func _update_handle_text() -> void:
	if handle == null:
		return
	var text := handle_text_open if _open else handle_text_closed
	if not text.is_empty():
		handle.text = text
