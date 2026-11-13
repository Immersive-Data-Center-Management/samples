# ARCore plugin: our patches and how to build it

The experiments use the built plugin checked in as [`../addons/ARCorePlugin/`](../addons/ARCorePlugin/)
(`bin/{debug,release}/*.aar`). **You only need this page to build the `.aar` files yourself**, for example after
changing the plugin.

The plugin source is [tGautot/godot_arcore](https://github.com/tGautot/godot_arcore) (a fork of
[GodotVR/godot_arcore](https://github.com/GodotVR/godot_arcore)), included as the git submodule
[`../arcore_extension/`](../arcore_extension/) and pinned to one upstream commit. Our changes are the `*.patch` files in
this folder:

| Patch | What it changes |
|---|---|
| `0001-…` | Google's ARCore C API header, updated to SDK 1.57.0 |
| `0002-…` | godot-cpp updated to `10.0.0-stable` (we build against the Godot 4.6 API, so the plugin runs on Godot 4.6+) |
| `0003-…` | Everything else, see below |

## What the patches change

Compared with upstream (`tGautot/godot_arcore`, commit `a738cab`):

**Current Godot and Android versions**
- Builds against the Godot 4.6 API with godot-cpp 10.0.0 and runs on Godot 4.6 and later (upstream: Godot 4.2).
  Uses the Godot Android library 4.7.2, which passes a nullable `Activity` to plugins.
- ARCore SDK 1.57.0 (upstream: 1.44.0), Android SDK 36, NDK 29, Android Gradle Plugin 8.6, Kotlin 2.1.
- Only `arm64-v8a`; the x86/x86_64 entries are removed.

**New features**
- **QR scanning** with Google ML Kit (QR, Data Matrix, Aztec): scans run asynchronously, off the render thread;
  signals `qr_code_found` / `qr_code_lost`, bounds in camera-image and screen pixels, optional capture of the detected
  image. It can be switched off (`arcore_features.h` and `FEATURE_QR_SCANNER` in `export_plugin.gd`) to save
  about 10 MB in the APK.
- **Freeze ("inspect mode")**: `set_ar_frozen()` holds the displayed pose and camera image while ARCore keeps tracking,
  or pauses the session completely.
- **ARCore's projection** (`get_projection_matrix()`, `get_camera_fov()`), so that picking matches the camera image.
- **Camera image as a Godot texture** (`get_camera_rgba_texture()`), copied on the GPU, without a CPU readback.
- **Point cloud data** (points and confidence values, with a threshold) instead of only rendering it.
- **Plane queries** filtered by tracking state and by planes merged into a larger one.
- Light estimation can be enabled independently of plane detection.

**Fixes**
- The native code receives the real Android `Activity`, not the plugin object.
- JNI calls from other threads (QR scanning) attach the thread to the JVM.
- Checks for a missing or failed ARCore session, unknown image names and missing parent planes, which used to
  dereference null pointers.
- Image tracking uses the image's center pose instead of creating a new anchor every frame (leak).
- The camera image fills the screen after a rotation to landscape.

**Removed**
- `InstancesRenderer` and `TrackedToImageComponent.gd`; the experiments use the nodes in
  [`../addons/sample_framework_ar/`](../addons/sample_framework_ar/) instead.

## Build

Prerequisites (Windows; versions as in `plugin/build.gradle.kts`):

- Git, PowerShell
- [Android Studio](https://developer.android.com/studio) or the command-line tools, `ANDROID_HOME` set to the SDK folder,
  and from the SDK Manager: SDK Platform 36, Build-Tools 36.1.0, CMake 3.22.1, NDK 29.0.14206865 and NDK 28.1.13356709
- JDK 17
- Python 3 with SCons (`pip install scons`)

Run from the repository root:

```powershell
.\shared\arcore_extension_patches\apply.ps1      # submodule at the pinned commit + our patches + godot-cpp

cd shared\arcore_extension\godot-cpp
scons platform=android target=template_debug   arch=arm64 api_version=4.6 -j8
scons platform=android target=template_release arch=arm64 api_version=4.6 -j8

cd ..
.\gradlew.bat assemble
Copy-Item -Recurse -Force -Exclude *.uid plugin\demo\addons\ARCorePlugin\* ..\addons\ARCorePlugin\
```

The godot-cpp step is needed once (and again after a godot-cpp update). Then export Experiment 2 or 3 for Android to
test. After `apply.ps1`, [`../arcore_extension/README.md`](../arcore_extension/README.md) describes the plugin's API,
layout and build in detail.

## Changing the plugin

`apply.ps1` puts the patches as commits on the local branch `samples` in the submodule. Change the code there and
commit in the submodule: a new commit becomes a new patch, `git commit --amend` changes the last one. Then run
`.\shared\arcore_extension_patches\export.ps1`, which rewrites the `*.patch` files from these commits, and commit them in
the samples repository. The submodule pointer itself stays on the upstream commit (`.gitmodules` has `ignore = all`).

`apply.ps1` rebuilds the branch `samples` from the patches: it discards uncommitted changes and commits that are not
exported yet. So export first.
