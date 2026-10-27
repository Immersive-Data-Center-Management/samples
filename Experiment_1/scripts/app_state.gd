extends Node

## Shared application state passed between scenes.
var auth_token: String = ""
var base_url: String = ""
var selected_item_url: String = ""
var selected_shell_id: String = ""
## Shown once on the login screen, e.g. after the session expired.
var login_message: String = ""


## Called on HTTP 401: drops the token and returns to the login screen.
func session_expired() -> void:
	if auth_token.is_empty():
		return  # another request already handled it
	auth_token = ""
	login_message = "Session expired. Please log in again."
	get_tree().change_scene_to_file("res://scenes/screens/login_screen.tscn")
