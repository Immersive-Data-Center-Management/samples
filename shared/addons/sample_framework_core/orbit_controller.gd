extends Node
class_name OrbitController

## Orbit / zoom / pan a camera around a pivot point, by touch and mouse:
##   • one-finger drag / left mouse drag   → orbit
##   • pinch / mouse wheel                 → zoom
##   • two-finger drag / right or middle drag → pan
## A click or tap without movement is left alone, so pickers ([ObjectPicker], [StageSelection])
## still get it. Input over UI never arrives here (_unhandled_input).
##
## Add it as a child of the [member camera]. By default it moves the camera itself. Under XR the
## XR system owns the camera's local transform, so set [member move_node] to the XROrigin3D: the
## controller then moves the origin so that the camera ends up at the orbit pose (see
## [ARInspectCamera]).

## Emitted on every orbit / zoom / pan made by the user (not by [method focus] or [method set_pivot]).
signal user_moved

## Camera that looks at the pivot. Default: the parent node.
@export var camera: Camera3D
## Node that is actually moved. Default: [member camera]. In AR: the XROrigin3D.
@export var move_node: Node3D
## Ignore input while false (e.g. AR: only active while the view is frozen).
@export var enabled := true:
	set(value):
		enabled = value
		_touches.clear()
		_mouse_orbiting = false
		_mouse_panning = false
@export var min_distance := 1.0
@export var max_distance := 100.0
## Keep the camera above y = 0 and the pivot at y >= 0 (a floor in a 3D viewer; off for AR).
@export var stay_above_floor := true
## Orbit speed in radians per screen pixel.
@export var orbit_speed := 0.005
## Mouse-wheel zoom step per notch, as a fraction of the distance.
@export var zoom_step := 0.1
## How strongly zooming in pulls the pivot onto [member zoom_anchor] (0 = off, 1 = snap).
@export_range(0.0, 1.0) var zoom_recenter_strength := 0.0

const MAX_PITCH := deg_to_rad(80.0)  # look_at breaks at 90
const MIN_CAMERA_HEIGHT := 0.1  # m, with stay_above_floor

var pivot := Vector3.ZERO
var yaw := deg_to_rad(45.0)
var pitch := deg_to_rad(35.0)
var distance := 10.0
## World point zooming in pulls the pivot towards, e.g. the selected object. INF = none.
var zoom_anchor := Vector3.INF

var _touches := {}  # touch index -> position
var _pinch_ready := false
var _last_pinch_dist := 0.0
var _last_centroid := Vector2.ZERO
var _mouse_orbiting := false
var _mouse_panning := false


func _ready() -> void:
	if camera == null:
		camera = get_parent() as Camera3D
	if move_node == null:
		move_node = camera
	if enabled:
		apply()


## Takes the current camera pose as orbit state, with the pivot [param pivot_distance] metres in
## front of the camera. Use it to start orbiting from wherever the camera is (e.g. a frozen AR view).
func sync_from_camera(pivot_distance: float) -> void:
	var cam := camera.global_transform
	set_pivot(cam.origin - cam.basis.z.normalized() * pivot_distance)


## Moves the pivot to [param world_pos] without moving the camera; the next orbit turns around it.
func set_pivot(world_pos: Vector3) -> void:
	pivot = world_pos
	var to_cam := camera.global_position - pivot
	distance = maxf(to_cam.length(), min_distance)
	var dir := to_cam / distance
	yaw = atan2(dir.x, dir.z)
	pitch = asin(clampf(dir.y, -1.0, 1.0))


## Smoothly moves the pivot to the box centre and zooms so the box fits.
func focus(box: AABB) -> void:
	var from_pivot := pivot
	var from_distance := distance
	var to_distance := clampf(box.size.length() * 1.5, min_distance, max_distance)
	create_tween().tween_method(func(t: float) -> void:
		pivot = from_pivot.lerp(box.get_center(), t)
		distance = lerpf(from_distance, to_distance, t)
		apply(), 0.0, 1.0, 0.3).set_trans(Tween.TRANS_SINE)


func orbit(screen_delta: Vector2) -> void:
	yaw -= screen_delta.x * orbit_speed
	pitch += screen_delta.y * orbit_speed
	_user_moved()


## Pans the pivot in the view plane by a screen-space delta (px); the grabbed point follows.
func pan(screen_delta: Vector2) -> void:
	var metres_per_px := 2.0 * distance * tan(deg_to_rad(camera.fov) / 2.0) / camera.get_viewport().get_visible_rect().size.y
	var b := camera.global_basis
	pivot += (b.y * screen_delta.y - b.x * screen_delta.x) * metres_per_px
	_user_moved()


## Zooms by a factor (< 1 = in, > 1 = out).
func zoom(factor: float) -> void:
	distance *= factor
	if factor < 1.0 and zoom_recenter_strength > 0.0 and zoom_anchor != Vector3.INF:
		pivot = pivot.lerp(zoom_anchor, (1.0 - factor) * zoom_recenter_strength)
	_user_moved()


## Places [member move_node] so the camera sits at the current orbit pose.
func apply() -> void:
	distance = clampf(distance, min_distance, max_distance)
	var min_pitch := -MAX_PITCH
	if stay_above_floor:
		pivot.y = maxf(pivot.y, 0.0)
		min_pitch = maxf(min_pitch, asin(clampf((MIN_CAMERA_HEIGHT - pivot.y) / distance, -1.0, 1.0)))
	pitch = clampf(pitch, min_pitch, MAX_PITCH)
	var offset := distance * Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	var cam_pose := Transform3D(Basis(), pivot + offset).looking_at(pivot, Vector3.UP)
	# The camera's pose relative to move_node stays fixed (identity when moving the camera itself).
	var cam_local := move_node.global_transform.affine_inverse() * camera.global_transform
	move_node.global_transform = cam_pose * cam_local.affine_inverse()


func _user_moved() -> void:
	apply()
	user_moved.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
		_pinch_ready = false  # new baseline whenever the finger count changes
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			orbit(event.relative)
		elif _touches.size() >= 2:
			_pinch_pan()
	# Ignore mouse events synthesised from touches, or a pinch would also orbit.
	elif not _touches.is_empty():
		return
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					zoom(1.0 - zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					zoom(1.0 + zoom_step)
			MOUSE_BUTTON_LEFT:
				_mouse_orbiting = event.pressed
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_mouse_panning = event.pressed
	elif event is InputEventMouseMotion:
		if _mouse_orbiting:
			orbit(event.relative)
		elif _mouse_panning:
			pan(event.relative)


func _pinch_pan() -> void:
	var keys := _touches.keys()
	var p0: Vector2 = _touches[keys[0]]
	var p1: Vector2 = _touches[keys[1]]
	var centroid := (p0 + p1) * 0.5
	var dist := p0.distance_to(p1)
	if not _pinch_ready:  # first two-finger frame: seed the baseline, avoids a jump
		_last_centroid = centroid
		_last_pinch_dist = dist
		_pinch_ready = true
		return
	if _last_pinch_dist > 0.0 and dist > 0.0:
		distance *= _last_pinch_dist / dist
	pan(centroid - _last_centroid)
	_last_centroid = centroid
	_last_pinch_dist = dist
