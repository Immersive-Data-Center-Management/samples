# Experiment 3 – Take the rack with you

## About this experiment

> [!IMPORTANT]
> Sample code for demonstration only, **not intended for productive use of any kind**. See the
> [repository README](../README.md#about-this-project).

An Android AR app. The technician points the phone at a server rack (here: a printed image target stands in for the
real rack). The rack's components appear as 3D models exactly on top of it, and an overheating server is marked with
a warning. The technician can **freeze** the AR view to lower the phone and keep tapping parts, or open the **3D
view** to walk back to the desk or to a colleague and keep exploring the rack: orbit around it, tap parts, watch the
live values. The data keeps updating in both.

<img src="docs/1_warning.png" alt="Rack found, one part warns" width="30%"> <img src="docs/2_selected_live_data.png" alt="Warning and live data" width="30%"> <img src="docs/3_3d_view.png" alt="3D view, orbiting around the rack" width="30%">

What it shows:

1. **The ARCore plugin** – image tracking with a real-size target, the camera feed as the scene background, and the
   freeze mode (pose and image held while ARCore keeps tracking underneath, so resuming is seamless), and a 3D
   view of the tracked content that returns to the AR view it was opened from.
2. **USD content with IDTXFlow** – the rack and its parts are USD files placed relative to the image target.
3. **Interaction in AR** – taps are unprojected through ARCore's real projection, so picks line up even near the
   screen edges; parts show hint/highlight states and a generic warning status.

The data is fake on purpose (`scripts/fake_telemetry.gd`): this experiment is about AR. Experiment 2 shows the same
kind of live data coming from an AAS.

### The flow

1. **Find the rack** – "Point the camera at the rack target" until the image target is recognised.
2. **See the problem** – Server_02 heats up past 55 °C, gets an orange tint and a "!" marker; the *⚠ 1 warning* chip
   appears.
3. **Tap** a part (or the chip) – the bottom panel shows its data, with the temperature counting live.
4. **Freeze** – the camera image and the models stop following the phone; parts stay tappable.
5. **3D view** – the rack without the camera image. One finger orbits, pinch zooms, two fingers pan. *Center on
   selected* reframes the part. Turning it off returns to live or frozen AR, whichever was on. Values keep updating.

## Requirements and Setup

- Windows, Godot 4.7.2
- An Android phone with ARCore support (arm64), and the image target: print
  [`docs/full_image_target.jpg`](docs/full_image_target.jpg) at **19 cm width**, fits on A4
  portrait (or show it on a monitor at that width). ARCore only tracks its middle part,
  [`cropped_tracking_target.jpg`](assets/textures/cropped_tracking_target.jpg) (PDU to power supplies), which is then
  9.27 cm wide, the `physical_width` of the `ImageTrackedComponent`. If the sizes don't match, the models drift. Tracking
  only the middle is on purpose: a technician holds the phone close to the relevant parts, and a target that fills more
  of the camera view is lost less often.
- The desktop shows a preview (target "found" at its scene position, mouse orbit), enough to try picking and freezing.

### Run

1. Close Godot and run `powershell -ExecutionPolicy Bypass -File bootstrap.ps1` in this folder. It installs IDTXFlow
   (Windows + Android), links the shared addons and downloads `arcoreimg`. Skip it if you ran
   [`bootstrap_all.bat`](../bootstrap_all.bat) in the repository root; otherwise it is needed once (and again after
   changing the IDTXFlow version).
2. Open `project.godot` in Godot 4.7.2. F5 runs the desktop preview.
3. For the phone, export the Android preset (arm64). The ARCore plugin adds its Android dependencies itself.

### Code layout

- `scenes/ar_view_state.tscn` + `scripts/ar_view_state.gd` – the AR view: tracked rack, parts, UI
- `scripts/fake_telemetry.gd` – drifting temperatures, sets the parts' warning status
- `scripts/slide_menu.gd` – bottom info panel content
- `scripts/app_data.gd` – autoload `AppData`: the fake part data
- `assets/` – image target and USD models (`assets/usd/Rack/` is a copy of [`shared/deploy/assets/`](../shared/deploy/assets/)).
  To use your own target, see [placing content on an image target](../shared/README.md#placing-content-on-an-image-target).
- `addons/` – created by `bootstrap.ps1` (IDTXFlow and links to `../shared/addons/`)

## Licensing

See the [repository README](../README.md#licensing). The ARCore plugin uses Google ARCore, downloaded by the Android
build.
