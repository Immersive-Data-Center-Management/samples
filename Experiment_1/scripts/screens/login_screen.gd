extends FlowState

## Step 1: log in. Gets a Keycloak access token (password grant) for the entered AAS server
## (Session), then continues with the rack list. Enter in any field submits.

@onready var url_input: LineEdit = $MarginContainer/VBoxContainer/UrlInput
@onready var username_input: LineEdit = $MarginContainer/VBoxContainer/UsernameInput
@onready var password_input: LineEdit = $MarginContainer/VBoxContainer/PasswordInput
@onready var login_button: Button = $MarginContainer/VBoxContainer/LoginButton
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel

func _ready() -> void:
	login_button.pressed.connect(_on_login_pressed)
	for input in [url_input, username_input, password_input]:
		input.text_submitted.connect(func(_text): if not login_button.disabled: _on_login_pressed())


func enter_state() -> void:
	status_label.text = Session.take_message()
	login_button.disabled = false
	# Without IDTXFlow the 3D viewer cannot work, so block the login.
	var missing := IdtxFlowCheck.missing_text()
	if not missing.is_empty():
		status_label.text = missing
		login_button.disabled = true


func _on_login_pressed() -> void:
	var base_url := url_input.text.strip_edges().rstrip("/")
	var user_name := username_input.text.strip_edges()
	var user_pass := password_input.text

	if base_url.is_empty() or user_name.is_empty() or user_pass.is_empty():
		status_label.text = "Please fill in all fields."
		return

	login_button.disabled = true
	status_label.text = "Logging in..."
	var ok := await Session.login(base_url, user_name, user_pass)
	login_button.disabled = false
	if not ok:
		status_label.text = Session.error_text
		return
	status_label.text = ""
	finish()
