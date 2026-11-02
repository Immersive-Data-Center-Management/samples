# ARCore plugin (source)

Source and Gradle build of the Godot 4 Android plugin that brings Google ARCore to the AR experiments (Experiment 2 and 3).
It is a GDExtension (C++) with a small Kotlin/Java part, based on [GodotVR/godot_arcore](https://github.com/GodotVR/godot_arcore)
and extended for these samples.

> [!NOTE]
> **You don't need to build it to run the experiments.** The built plugin is checked in as
> [`../addons/ARCorePlugin/`](../addons/ARCorePlugin/) (`bin/{debug,release}/*.aar` plus the GDScript wrapper) and the
> experiments link it via `bootstrap.ps1`. Build it only after changing the C++, Kotlin or wrapper code.

## What it provides

The native class `ARCoreInterface` is an `XRInterface` (named "ARCore" in the `XRServer`). The autoload
`ARCoreInterfaceInstance` ([`ARCoreInterface.gd`](plugin/export_scripts_template/ARCoreInterface.gd)) creates and
registers it on Android and wraps the native calls:

| Feature | API (on `ARCoreInterfaceInstance`) |
|---|---|
| Camera feed as background, device pose | `start()`, `get_tracking_status()`, `get_camera_feed()`, `get_camera_rgba_texture()` |
| ARCore's real projection (for picking that matches the image) | `get_projection_matrix()`, `get_camera_fov()` |
| Image tracking | `image_tracker_database_add_image()`, `image_tracker_get_tracked_transform()`, … |
| QR codes (Google ML Kit) | `qr_scanner_start()`, signals `qr_code_found` / `qr_code_lost`, `qr_scanner_get_detected_bounds()` |
| Planes, point cloud, depth, light estimation | `enable_*()`, `plane_tracker_*()`, `point_cloud_get_points()` |
| Hit tests | `raycast()`, `screenRayCast()` |
| Freeze ("inspect mode") | `set_ar_frozen()`: holds pose and image while ARCore keeps tracking |

The higher-level nodes the experiments use (AR rig, image/QR tracked components, inspect camera) are in
[`../addons/sample_framework_ar/`](../addons/sample_framework_ar/).

## Layout

| Path | What it is |
|---|---|
| `plugin/src/main/cpp/` | The GDExtension: `ARCoreInterface` (XR interface), background/plane/point-cloud renderers, image tracker, QR scanner |
| `plugin/src/main/cpp/include/arcore_c_api.h` | Google's ARCore C API header ([see note](plugin/src/main/cpp/include/README.md)) |
| `plugin/src/main/java/` | Android plugin entry point (`ARCorePlugin.kt`) and the ML Kit bridge (`QRScannerBridge.java`) |
| `plugin/export_scripts_template/` | **Source** of the addon's GDScript files (`ARCoreInterface.gd`, `export_plugin.gd`, `plugin.cfg`) |
| `plugin/build.gradle.kts`, `plugin/CMakeLists.txt` | Gradle and CMake build: versions of Android SDK/NDK, ARCore, ML Kit, Godot |
| `godot-cpp/` | Godot C++ bindings (MIT), checked in, so there is no submodule to initialize |

## Prerequisites

- [Android Studio](https://developer.android.com/studio) or the Android command-line tools, with `ANDROID_HOME` set to the
  SDK folder (use an absolute path, not `~`).
- From the SDK Manager: Android SDK Platform 36, Build-Tools 36.1.0, CMake 3.22.1, NDK 29.0.14206865 (used by the plugin,
  see `plugin/build.gradle.kts`) and NDK 28.1.13356709 (the default of godot-cpp; pass `ndk_version=...` to SCons to
  use another one).
- JDK 17.
- Python 3 with [SCons](https://scons.org/) (`pip install scons`) for godot-cpp.
- Gradle comes with the wrapper (`gradlew`, Gradle 8.9). Don't use a system Gradle 9.

## Build

Run these from this folder (`shared/arcore_extension`).

1. Build the godot-cpp static libraries once (they end up in `godot-cpp/bin/`, which CMake links):

   ```shell
   cd godot-cpp
   scons platform=android target=template_debug arch=arm64 -j8     # for debug exports
   scons platform=android target=template_release arch=arm64 -j8   # for release exports
   cd ..
   ```

2. Build the plugin:

   ```shell
   ./gradlew assemble        # Windows: .\gradlew.bat assemble
   ```

   The build puts the complete addon (GDScript files and `bin/{debug,release}/ARCorePlugin-*.aar`) into
   `plugin/demo/addons/ARCorePlugin/` (git-ignored).

3. Copy it over the checked-in addon:

   ```powershell
   Copy-Item -Recurse -Force plugin\demo\addons\ARCorePlugin\* ..\addons\ARCorePlugin\
   ```

4. Test it with Experiment 2 or 3: run the experiment's `bootstrap.ps1`, export the Android preset and run it on an
   [ARCore-supported device](https://developers.google.com/ar/devices).

To change the GDScript wrapper, edit `plugin/export_scripts_template/ARCoreInterface.gd` (not the copy in
`../addons/ARCorePlugin/`, which step 3 overwrites).

**Android Studio:** open this folder (it is the Gradle root) and run the Gradle task `assemble`, from the Gradle tool
window or a "Gradle" run configuration. Step 1 still has to be done once on the command line.

**Only `arm64-v8a` is built.** Running in the Android emulator would also need x86_64 builds: the ABI filters in
`plugin/build.gradle.kts`, godot-cpp with `arch=x86_64`, a per-ABI ARCore library path in `plugin/CMakeLists.txt`
(`ARCORE_LIB_DIR`) and the architecture enabled in the Godot export preset.

## License

The plugin code is MIT ([LICENSE](LICENSE), [CONTRIBUTORS.md](CONTRIBUTORS.md)), as is `godot-cpp/`.
Google's ARCore SDK is **not**: the header `arcore_c_api.h` and the ARCore native libraries packaged into the `.aar`
files are licensed under the [ARCore Additional Terms of Service](https://developers.google.com/ar/develop/terms).
Among other things, an app using ARCore has to tell its users that it includes ARCore and that Google's Terms of
Service and Privacy Policy apply. ARCore and ML Kit themselves are pulled from Google's Maven repository when the
plugin is built and when the app is exported.
