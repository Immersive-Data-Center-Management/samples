extends FlowState

## Step 1: log in as the technician. Server URL and user are prefilled for the demo stack.

@onready var url_input: LineEdit = %UrlInput
@onready var username_input: LineEdit = %UsernameInput
@onready var password_input: LineEdit = %PasswordInput
@onready var login_button: Button = %LoginButton
@onready var status_label: Label = %StatusLabel


func _ready() -> void:
	login_button.pressed.connect(_on_login_pressed)
	password_input.text_submitted.connect(func(_t): _on_login_pressed())


func enter_state() -> void:
	status_label.text = Session.take_message()
	login_button.disabled = false
	# Without IDTXFlow the rack models cannot be shown, so block the login.
	var missing := IdtxFlowCheck.missing_text()
	if not missing.is_empty():
		status_label.text = missing
		login_button.disabled = true


func _on_login_pressed() -> void:
	if login_button.disabled:
		return
	var base_url := url_input.text.strip_edges().rstrip("/")
	login_button.disabled = true
	status_label.text = "Logging in..."
	var ok := await Session.login(base_url, username_input.text.strip_edges(), password_input.text)
	login_button.disabled = false
	if not ok:
		status_label.text = Session.error_text
		return
	finish()
