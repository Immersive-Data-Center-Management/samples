class_name IdtxFlowCheck
extends RefCounted

## All samples render USD with IDTXFlow, a GDExtension that is not in the repository:
## bootstrap.ps1 downloads it into the experiment's addons/ folder. Without it a sample still
## starts but every UsdStageNode3D stays empty. Call [method missing_text] where the app starts
## (e.g. the login screen) to tell the user instead.


## Returns "" when IDTXFlow is loaded, otherwise what to do about it. The message is also
## logged as an error, so it shows up in the Output panel or logcat.
static func missing_text() -> String:
	if ClassDB.class_exists("UsdStageNode3D"):
		return ""
	var text := "IDTXFlow extension is missing. Close Godot, run bootstrap_all.bat in the repository root and restart."
	push_error(text)
	return text
