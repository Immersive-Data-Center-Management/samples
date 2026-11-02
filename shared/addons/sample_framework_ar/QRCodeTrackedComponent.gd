extends Node
class_name QRCodeTrackedComponent

## Listens for ARCore QR / barcode detections and re-emits them as filtered signals.
##
## Usage:
##   1. Add this node anywhere in the scene tree.
##   2. Set [member filter] to match the QR content you care about ("*" catches all).
##   3. Connect [signal matched_found] and [signal matched_lost] for custom logic.
##   4. Optionally set [member image_target] to an ImageTrackedComponent — the
##      detected QR image will automatically be registered as that component's
##      tracking target, turning the QR code itself into an AR image marker.
##
## The QR scanner is started by InitARCore when ARCoreInit.FEAT_QR_SCANNING is enabled.
## This component only listens; it does not start or stop the scanner itself.

## Emitted when a QR code matching [member filter] is detected.
## [param data] is the decoded content;
signal matched_found(data: String)

## Emitted when the previously matched QR code is no longer tracked.
signal matched_lost(data: String)

## Filter pattern for QR code content (case-sensitive, no regex).[br]
## Supported wildcards:[br]
## - "*" (or empty) → match any QR code[br]
## - "xxx*" → starts with "xxx"[br]
## - "*xxx" → ends with "xxx"[br]
## - "*xxx*" → contains "xxx"[br]
## - "xxx" → exact match
@export var filter: String = "*"

## Optional: when set, registers the detected QR image as the tracking target
## in this ImageTrackedComponent. Allows using the QR code itself as an AR marker.[br]
## Requires [code]ARCoreInterfaceInstance.qr_scanner_set_capture_detected_images(true)[/code],
## otherwise no cropped detection image is cached for the image tracker.
@export var image_target: NodePath = NodePath("")

func _ready() -> void:
	ARCoreInterfaceInstance.qr_code_found.connect(_on_qr_code_found)
	ARCoreInterfaceInstance.qr_code_lost.connect(_on_qr_code_lost)

func _exit_tree() -> void:
	if ARCoreInterfaceInstance.qr_code_found.is_connected(_on_qr_code_found):
		ARCoreInterfaceInstance.qr_code_found.disconnect(_on_qr_code_found)
		ARCoreInterfaceInstance.qr_code_lost.disconnect(_on_qr_code_lost)

## Returns true if [param content] matches [member filter].
func matches(content: String) -> bool:
	if filter == "*" or filter.is_empty():
		return true
	if filter.begins_with("*") and filter.ends_with("*") and filter.length() > 1:
		return content.contains(filter.substr(1, filter.length() - 2))
	if filter.begins_with("*"):
		return content.ends_with(filter.substr(1))
	if filter.ends_with("*"):
		return content.begins_with(filter.substr(0, filter.length() - 1))
	return content == filter

func _on_qr_code_found(data: String, format: String) -> void:
	if not matches(data):
		print("[QR] Ignored by filter '%s': %s" % [filter, data])
		return
	matched_found.emit(data)

	print("QR code found: ", data, " format: ", format)
	
	# If an ImageTrackedComponent is linked, register the captured QR image as its target.
	var target := _get_image_target()
	if target != null:
		# ImageTrackedComponent integration requires qr_scanner_set_capture_detected_images(true).
		var img: Image = ARCoreInterfaceInstance.qr_scanner_get_detected_image(data)
		if img != null:
			target.track_dynamic(img, data)

func _on_qr_code_lost(data: String) -> void:

	print("QR code lost: ", data)

	if matches(data):
		matched_lost.emit(data)

func _get_image_target() -> ImageTrackedComponent:
	if image_target.is_empty():
		return null
	return get_node_or_null(image_target) as ImageTrackedComponent
