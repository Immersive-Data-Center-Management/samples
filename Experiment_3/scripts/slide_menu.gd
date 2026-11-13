extends SlideInPanel

## Bottom info menu of the AR view: shows the picked object's data and a "Center on selected"
## button. The slide behaviour comes from [SlideInPanel]; this script only fills the content.

## Optional button that re-centres the camera on the selected object. The AR view listens to
## [signal center_pressed]; this node just relays the click (it owns no camera logic).
@export var button_center: Button
## List (inside a ScrollContainer) that shows the object's data.
@export var content_container: PropertyList

## Emitted when the "Center" button is pressed (wired only if [member button_center] is assigned).
signal center_pressed

## Font colour for generated info labels.
const INFO_COLOR := Color(0.18, 0.18, 0.18, 1.0)
## Shown while no part is selected, e.g. when the user opens the panel by its handle.
const NOTHING_SELECTED := "Nothing selected. Tap a part of the rack to see its data."

func _ready() -> void:
	super._ready()
	if button_center:
		button_center.pressed.connect(func(): center_pressed.emit())
	show_nothing_selected()


## Replace the content with the "nothing selected" hint (does not open or close the panel).
func show_nothing_selected() -> void:
	if content_container:
		content_container.clear()
		content_container.add_row(NOTHING_SELECTED, "")


## Show/hide the "Center" button (no-op if none is assigned). The AR view shows it only in the
## 3D view: the AR camera follows the phone, so there is nothing to re-centre.
func set_center_enabled(enabled: bool) -> void:
	if button_center:
		button_center.visible = enabled


## Populate the menu from an object's data and open it. [param title] is shown as a heading,
## [param props] is rendered as one "Key: Value" label per entry (in dictionary order).
func show_object_info(title: String, props: Dictionary) -> void:
	if content_container == null:
		push_error("slide_menu: content_container not assigned.")
		return

	content_container.show_props(props)
	if not title.is_empty():
		var heading := Label.new()
		heading.text = str(props.get("Name", title))  # readable name rather than the node id
		heading.add_theme_color_override("font_color", INFO_COLOR)
		heading.add_theme_font_size_override("font_size", 28)
		content_container.add_child(heading)
		content_container.move_child(heading, 0)

	if props.is_empty():
		content_container.add_row("No data available.", "")

	open()
