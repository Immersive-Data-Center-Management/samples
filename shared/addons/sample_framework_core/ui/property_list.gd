extends VBoxContainer
class_name PropertyList

## A list of "Key: Value" rows, e.g. a part's nameplate or live data. A "Temperature" value
## (a number in °C) is coloured from green (cool) to red (hot).

## Font colour of the rows; leave transparent to use the theme's.
@export var font_color := Color(0, 0, 0, 0)
## Font size of the rows; 0 uses the theme's.
@export var font_size := 0
## Temperatures (°C) shown fully green / fully red.
@export var cool_celsius := 35.0
@export var hot_celsius := 60.0
## Colour and space above of [method add_heading] lines.
@export var heading_color := Color(0.6, 0.66, 0.72)
@export var heading_spacing := 16


## Replaces the rows with one per entry of [param props] (in dictionary order).
func show_props(props: Dictionary) -> void:
	clear()
	for key in props:
		add_row(str(key), str(props[key]))


## Adds a row; an empty [param value] makes it a heading-like line with just the key.
func add_row(key: String, value: String) -> void:
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = key if value.is_empty() else "%s: %s" % [key, value]
	var number := value.get_slice(" ", 0)  # "54.3 °C" or "54.3"
	if key == "Temperature" and number.is_valid_float():
		label.add_theme_color_override("font_color", temperature_color(number.to_float()))
	elif font_color.a > 0.0:
		label.add_theme_color_override("font_color", font_color)
	if font_size > 0:
		label.add_theme_font_size_override("font_size", font_size)
	add_child(label)


## Adds a section heading, e.g. "Nameplate": muted colour, with space above unless it is the first row.
func add_heading(text: String) -> void:
	if get_child_count() > 0:
		var gap := Control.new()
		gap.custom_minimum_size.y = heading_spacing
		add_child(gap)
	add_row(text, "")
	get_child(get_child_count() - 1).add_theme_color_override("font_color", heading_color)


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


## Green at [member cool_celsius], red at [member hot_celsius], amber in between.
func temperature_color(celsius: float) -> Color:
	var t := clampf(inverse_lerp(cool_celsius, hot_celsius, celsius), 0.0, 1.0)
	return Color(0.15, 0.7, 0.25).lerp(Color(0.9, 0.15, 0.1), t)
