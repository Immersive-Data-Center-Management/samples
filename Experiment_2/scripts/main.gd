extends Node3D

## Flow: Login -> Task -> Scan -> Inspect -> back to Task (which then shows the new report).
## On an expired session every state returns to Login.

func _ready() -> void:
	Session.expired.connect(func(): $StateManager.change_state($StateManager/Login))
