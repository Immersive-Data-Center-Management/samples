extends Node

## Fake live data for the demo: every [member interval] seconds each part's temperature drifts a
## little, and [member hot_object_id] slowly heats up past [member warning_threshold]. Writes the
## values into AppData.object_data and sets the matching PickableObject's status. Keeps running
## while the AR view is frozen, which is the point: the user took the rack along, the data stays live.

## Emitted after each update, so the UI can refresh what it shows.
signal updated

@export var interval := 1.0
## Part that overheats in this demo.
@export var hot_object_id := "Server_02_usdc"
@export var warning_threshold := 55.0

var _temps := {}
var _elapsed := 0.0

func _ready() -> void:
	for id in AppData.object_data:
		_temps[id] = randf_range(32.0, 40.0)
	_temps[hot_object_id] = warning_threshold - 3.0  # warns a few seconds after start
	_publish()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < interval:
		return
	_elapsed = 0.0
	for id in _temps:
		var drift := randf_range(-0.3, 0.3)
		var low := 28.0
		if id == hot_object_id:
			if _temps[id] < warning_threshold + 4.0:
				drift = randf_range(0.2, 0.8)  # heats up into the warning zone...
			else:
				drift = randf_range(-0.6, 0.6)  # ...then keeps fluctuating there
				low = warning_threshold + 1.0
		_temps[id] = clampf(_temps[id] + drift, low, 64.0)
	_publish()

func _publish() -> void:
	for id in _temps:
		var hot: bool = _temps[id] >= warning_threshold
		var data: Dictionary = AppData.object_data[id]
		data["Temperature"] = "%.1f °C" % _temps[id]
		data["Status"] = "Overheating" if hot else "Operational"
		for obj in get_tree().get_nodes_in_group("pickable_object"):
			if obj.object_id == id:
				obj.status = PickableObject.Status.WARNING if hot else PickableObject.Status.NORMAL
	updated.emit()
