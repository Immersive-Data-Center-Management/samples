extends Control
class_name FloatingPanel

## Base for overlay panels: titled frame, drag by the header, resize by the
## bottom-right grip. Subclass scenes inherit floating_panel.tscn and put their
## UI under %Content.

@export var title := "":
	set(value):
		title = value
		if is_node_ready():
			_header.text = value
## Scale all text with the panel width (relative to the size in the scene).
@export var scale_text := false
@export var base_font_size := 16
@export var min_size := Vector2(200, 120)

@onready var _header: Label = %Header
@onready var _grip: Control = %Grip

var _base_width := 0.0


func _ready() -> void:
	_header.text = title
	_header.gui_input.connect(_on_header_input)
	_grip.gui_input.connect(_on_grip_input)
	_grip.draw.connect(_draw_grip)
	if scale_text:
		_base_width = size.x
		theme = Theme.new()  # only default_font_size is set; the rest falls through
		resized.connect(_update_font_size)
		_update_font_size()


func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		position = (position + event.relative).clamp(Vector2.ZERO, get_parent_area_size() - size)


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		size = (size + event.relative).clamp(min_size, get_parent_area_size() - position)


func _update_font_size() -> void:
	theme.default_font_size = roundi(base_font_size * clampf(size.x / _base_width, 0.75, 3.0))


func _draw_grip() -> void:
	var s := _grip.size
	var color := Color(1, 1, 1, 0.4)
	for i in 3:
		var d := 4.0 + i * 4.0
		_grip.draw_line(Vector2(s.x - d, s.y - 2), Vector2(s.x - 2, s.y - d), color, 1.5)
