extends Camera3D
class_name OrbitCamera

## Orbits around `pivot`: right-drag rotates, middle-drag pans, wheel zooms,
## W/S raise/lower and A/D pan the pivot sideways, F focuses the `selection`.
## Uses _unhandled_input, so events over UI panels (e.g. wheel scrolling a
## list) do not move the camera. A child light follows the view direction.

const MOUSE_SENSITIVITY := 0.003
const ZOOM_STEP := 0.05
const MIN_DISTANCE := 1.0
const MAX_DISTANCE := 100.0
const MAX_PITCH := deg_to_rad(80.0)  # both directions; look_at breaks at 90
const MIN_CAMERA_HEIGHT := 0.1  # m above the floor
const PAN_SPEED := 1.0  # m/s
const MAX_PIVOT_HEIGHT := 20.0

var yaw := deg_to_rad(45.0)
var pitch := deg_to_rad(35.0)
var distance := 10.0
var pivot := Vector3.ZERO

@export var selection: StageSelection


func _ready() -> void:
	_update()


func _process(delta: float) -> void:
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move.y += 1.0
	if Input.is_key_pressed(KEY_S):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_A):
		move -= right
	if Input.is_key_pressed(KEY_D):
		move += right
	if move == Vector3.ZERO:
		return
	pivot += move * PAN_SPEED * delta
	pivot.y = clampf(pivot.y, 0.0, MAX_PIVOT_HEIGHT)
	_update()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		if selection != null and selection.has_selection():
			focus(selection.selected_bounds())
		return
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				distance -= ZOOM_STEP
			MOUSE_BUTTON_WHEEL_DOWN:
				distance += ZOOM_STEP
			_:
				return
		distance = clampf(distance, MIN_DISTANCE, MAX_DISTANCE)
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch += event.relative.y * MOUSE_SENSITIVITY
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		# Meters per pixel at the pivot, so the grabbed point stays under the cursor.
		var scale := 2.0 * distance * tan(deg_to_rad(fov) / 2.0) / get_viewport().get_visible_rect().size.y
		pivot += (basis.y * event.relative.y - basis.x * event.relative.x) * scale
		pivot.y = clampf(pivot.y, 0.0, MAX_PIVOT_HEIGHT)
	else:
		return
	_update()
	get_viewport().set_input_as_handled()


## Smoothly moves the pivot to the box center and zooms to fit it.
func focus(box: AABB) -> void:
	var from_pivot := pivot
	var from_distance := distance
	var to_distance := clampf(box.size.length() * 1.5, MIN_DISTANCE, MAX_DISTANCE)
	create_tween().tween_method(func(t: float) -> void:
		pivot = from_pivot.lerp(box.get_center(), t)
		distance = lerpf(from_distance, to_distance, t)
		_update(), 0.0, 1.0, 0.3).set_trans(Tween.TRANS_SINE)


func _update() -> void:
	# Lowest pitch that keeps the camera above MIN_CAMERA_HEIGHT.
	var min_pitch := asin(clampf((MIN_CAMERA_HEIGHT - pivot.y) / distance, -1.0, 1.0))
	pitch = clampf(pitch, maxf(min_pitch, -MAX_PITCH), MAX_PITCH)
	position = pivot + distance * Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	look_at(pivot, Vector3.UP)
