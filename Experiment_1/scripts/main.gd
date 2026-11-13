extends Node

## Flow: Login -> Racks -> Viewer -> back to Racks (Back buttons). On an expired session every
## screen returns to Login, which shows the message.

func _ready() -> void:
	Session.expired.connect(func(): $StateManager.change_state($StateManager/Login))
