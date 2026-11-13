@tool
extends EditorPlugin

## Editor side of the ARCore plugin: registers the ARCoreInterfaceInstance autoload and, on
## Android export, adds the plugin .aar and its Maven dependencies (ARCore, appcompat, ML Kit).

# A class member to hold the editor export plugin during its lifecycle.
var export_plugin : AndroidExportPlugin

func _enter_tree():
	# Initialization of the plugin goes here.
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)

	# Add an autoload for the actual interface
	add_autoload_singleton(
			"ARCoreInterfaceInstance",
			"res://addons/ARCorePlugin/ARCoreInterface.gd")


func _exit_tree():
	# Clean-up of the plugin goes here.
	remove_export_plugin(export_plugin)
	export_plugin = null

	# The autoload stays registered on purpose: project scenes and scripts reference it.


class AndroidExportPlugin extends EditorExportPlugin:
	# Optional features that can be toggled to reduce APK size.
	# Must match the C++ defines in arcore_features.h
	const FEATURE_QR_SCANNER = true  # Requires Google ML Kit (adds ~10MB to APK)
	
	var _plugin_name = "ARCorePlugin"

	func _supports_platform(platform):
		if platform is EditorExportPlatformAndroid:
			return true
		return false

	func _get_android_libraries(platform, debug):
		if debug:
			return PackedStringArray([_plugin_name + "/bin/debug/" + _plugin_name + "-debug.aar"])
		else:
			return PackedStringArray([_plugin_name + "/bin/release/" + _plugin_name + "-release.aar"])

	func _get_android_dependencies(platform, debug):
		var deps = PackedStringArray(["com.google.ar:core:1.57.0", "androidx.appcompat:appcompat:1.8.0"])
		if FEATURE_QR_SCANNER:
			deps.append("com.google.mlkit:barcode-scanning:17.3.0")
		return deps

	func _get_name():
		return _plugin_name
