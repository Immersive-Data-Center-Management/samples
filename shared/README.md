# Shared building blocks

Everything the experiments have in common lives here once: Godot addons, the native ARCore plugin, the demo
backend and a few tools. [`bootstrap_all.bat`](../bootstrap_all.bat) in the repository root links the addons each
experiment needs into its own `addons/` folder, so the experiments stay small and only contain their app logic.

> [!IMPORTANT]
> Sample code for demonstration only, **not intended for productive use of any kind**. See the
> [repository README](../README.md#about-this-project).

## Contents

| Folder | What it is | Used by |
|---|---|---|
| [`addons/sample_framework_core/`](addons/sample_framework_core/) | App flow, UI widgets, 3D interaction (orbit camera, picking, highlight/warning status) | Exp 1, 2, 3 |
| [`addons/sample_framework_aas/`](addons/sample_framework_aas/) | AAS (BaSyx) REST client, Keycloak login, rack → USD session layer | Exp 1, 2 |
| [`addons/sample_framework_ar/`](addons/sample_framework_ar/) | AR rig and components on top of the ARCore plugin | Exp 2, 3 |
| [`addons/ARCorePlugin/`](addons/ARCorePlugin/) | The built ARCore Android plugin (`.aar`) and its GDScript wrapper | Exp 2, 3 |
| [`arcore_extension/`](arcore_extension/README.md) | C++/Kotlin source and Gradle build of the ARCore plugin | – |
| [`idtxflow_android/`](idtxflow_android/) | IDTXFlow 0.6.0 Android arm64 binaries, copied into `addons/IDTXFlow` by `bootstrap.ps1 -Android`. Temporary: not in the public IDTXFlow release yet. Not an addon of its own. | Exp 2, 3 |
| [`deploy/`](deploy/README.md) | Demo backend: Keycloak + Eclipse BaSyx + asset server, seed data, live-data simulator | Exp 1, 2 |
| [`tools/`](tools/) | Blender scripts to shrink high-poly USD meshes | – |
| [`tests/`](tests/README.md) | How to run the offline tests of the addons | – |
| [`bootstrap.ps1`](bootstrap.ps1) | Downloads IDTXFlow and links the addons into an experiment (called by each experiment's `bootstrap.ps1` and by `bootstrap_all.bat` in the root) | all |

## Sample framework

Three plain Godot addons (scripts with `class_name`, nothing to enable). They are split by what they need, so a
project without ARCore can still use the other two.

### `sample_framework_core` – Godot only

| Class | Does |
|---|---|
| `StateManager`, `FlowState` (`flow/`) | One-screen-at-a-time app flow, used by all experiments. States call `finish()` / `go_to(state)`; the order is wired in the scene. Scales the UI by screen density. |
| `IdtxFlowCheck` | `missing_text()` returns a message when the IDTXFlow extension is not installed (the experiments show it on their first screen). |
| `OrbitController` | Orbit / zoom / pan around a pivot: left drag or one finger orbits, wheel or pinch zooms, right/middle drag or two fingers pan. A click without movement is left to the pickers. `set_pivot()`, `focus(aabb)`. Moves the camera, or (AR) the XROrigin3D. |
| `StageSelection` | Picks and highlights the components of a USD stage that `RackComponents` composed (prims from the AAS, no nodes per part). |
| `PickableObject`, `ObjectPicker` | Pickable scene content, a node per part (Exp 3): per-state visuals (hint, highlight, collider box), a box collider fitted to the meshes at runtime (assets need no authored colliders) or baked in the editor, generic `status` (`NORMAL` / `WARNING` with a "!" marker). The picker uses ARCore's projection under XR and the camera's otherwise. |
| `FloatingPanel`, `SlideInPanel`, `PropertyList`, `StatusChip`, `ScreenCapture` (`ui/`) | Movable/resizable panel, bottom slide-in panel, "Key: Value" list (temperatures green → red), "⚠ N warnings" button cycling through warning objects, screenshot helper (`await ScreenCapture.capture(viewport, [ui])`). |

Two pickers on purpose: `StageSelection` for a stage composed from the AAS (Exp 1, 2). `PickableObject` for parts placed
in the editor as separate USD files with local data, plus what AR needs: a tap ray through ARCore's projection, boxes over
the camera image, a status per part (Exp 3).

How to set up a `PickableObject` (collider fitting, visual flags) is described in the doc comments of
[`pickable_object.gd`](addons/sample_framework_core/pickable_object.gd); the inspector shows them too.

### `sample_framework_aas` – Godot only

| Class | Does |
|---|---|
| `AasSession` | The logged-in session, meant as autoload `Session`: `login()`, `new_aas_service()` (clients follow later logins), user name from the token, signal `expired` on HTTP 401. |
| `AasService` | Minimal authenticated AAS V3 client: shells, submodels (by id or semantic id), `$value` reads, element writes, paging, base64url ids. Emits `unauthorized` on HTTP 401. `reachable_url()` rewrites `127.0.0.1` asset URLs to the server host so a phone can load them. |
| `KeycloakLogin` | Password-grant login; derives the token URL from the AAS URL (same host, port 8180). Plain-language error texts. `token_claim()` reads e.g. the user's name from the token. |
| [`RackComponents`](#how-rackcomponents-assembles-a-rack) | Turns the AAS rack inventory into one assembled 3D rack: reads installed parts and slots, finds their model URLs, and tells IDTXFlow how to load and position them. |

#### How RackComponents assembles a rack

The AAS describes **what is installed and where**, while the USD files describe **what each part looks like**.
[`RackComponents`](addons/sample_framework_aas/rack_components.gd) connects the two, so Experiments 1 and 2
do not need a hand-placed Godot node for every server or power supply.

1. **Read the inventory — `fetch()`.** Given a rack's AAS shell id, read its bill of material
   (`HierarchicalStructures`, see [AAS data model](deploy/README.md#aas-data-model)). Each Node entity
   under the `EntryNode` becomes a dictionary containing its identifier, asset id, `HeightUnits` and
   `PositionFrom` (slot index).
2. **Find the models — `resolve_models()`.** Match each asset id to a component's AAS shell, then read
   the model URL from the `DigitalFile` element of its `Models3D` submodel. Add `shell_id` and `model_url`
   to the same dictionaries. Localhost URLs are rewritten to the AAS server's host so phones can reach them.
3. **Describe the assembly — `session_layer()`.** Generate a small USDA text layer containing an
   `AAS_Component_N` transform per placeable part. Each transform references the part's USD file as a
   *payload* and positions it inside the rack. A session layer adds instructions over the rack model
   at load time; it does **not** rewrite the rack or component files.
4. **Request the load — `load_rack()`.** This calls `session_layer()`, passes its text to IDTXFlow through
   the stage's `USD_OVERRIDE_LAYER` metadata, then reloads the supplied rack URL. IDTXFlow performs the
   actual asynchronous model loading and USD composition.

Typical call sequence (the caller has an `AasService`, a rack shell id, the rack's own model URL,
a `UsdStageNode3D` and a `StageSelection`):

```gdscript
var components := await RackComponents.fetch(aas, rack_shell_id)
await RackComponents.resolve_models(aas, components)
selection.components = components
RackComponents.load_rack(stage, rack_url, components)
```

The generated prim name is also stored as `prim_name` in each placed component's dictionary.
`StageSelection` uses it to turn a click on the 3D geometry back into the component's identifier,
which the app uses to show its AAS data.

**Placement follows the sample assets' conventions:** the rack root prim is `root`, Z points up,
and slot 0 starts 0.098 m above the rack's feet. One rack unit is 0.04445 m, so `PositionFrom = 2`
places a component's bottom at `0.098 + 2 * 0.04445 = 0.1869 m`. `HeightUnits` is retained as data,
not used to resize models or detect overlaps. Components without a model URL or position remain in
the inventory but are omitted from the 3D assembly. See the [asset conventions](deploy/assets/README.md).

### `sample_framework_ar` – needs `ARCorePlugin`

| Class / scene | Does |
|---|---|
| `XRSetup.tscn` + `ARCoreInit` | The AR rig. Requests the camera permission, starts ARCore, renders the camera feed as the sky and turns features on via a bitmask (image tracking, QR scanning, planes, point cloud). Off-device it switches to a desktop preview. |
| [`ImageTrackedComponent`](#placing-content-on-an-image-target) | Follows a printed image target. Content is added as children. Editor preview of the target at its real size; *Evaluate target quality* button (Google's `arcoreimg`, downloaded by `bootstrap.ps1`). |
| `QRCodeTrackedComponent` | Emits `matched_found(data)` for QR codes matching a filter. |
| `ARInspectCamera` | Freeze the AR view and orbit/zoom/pan the frozen scene (an `OrbitController` moving the XROrigin3D), orbiting around the picked object. |
| `ARPlaneManager`, `ARPointCloud` | Detected planes and feature points, for debugging tracking. |

#### Placing content on an image target

`ImageTrackedComponent` shows its target image in the editor, at its real size and exactly where ARCore will report it
on the device. So content is placed by eye, no measuring:

1. Set `tracked_texture` (at least 300 px wide, with sharp detail and no large plain areas) and `physical_width` (the
   printed width in metres). Press *Evaluate target quality* for Google's score: a rough guide, it jumps by tens of
   points on small crops; a low score can still track fine.
2. Add a `Node3D` under it as a helper and put the 3D content under that helper.
3. Look at the target from the front (orthographic) and move, rotate and scale the helper until the models cover their
   counterparts in the image. Lower `preview_opacity` to see models behind the image plane.

<img src="../Experiment_3/docs/4_target_preview.png" alt="Rack models aligned to the target preview in the editor" width="60%">

The preview exists only in the editor, it is never saved or rendered on the device.

## Use it in your own project

The addons are plain Godot addons. They only depend on each other as listed:

- `sample_framework_core` – Godot only (IDTXFlow for USD content; `StageSelection` works with `sample_framework_aas` data).
- `sample_framework_aas` – Godot only.
- `sample_framework_ar` – `sample_framework_core` and `ARCorePlugin` (registered as autoload `ARCoreInterfaceInstance`).

**Inside this repository** add a `bootstrap.ps1` to your experiment folder like the existing ones, e.g.

```powershell
& (Join-Path $PSScriptRoot "..\shared\bootstrap.ps1") -Project $PSScriptRoot -Link sample_framework_core, sample_framework_aas
```

Add `-Android` (and `sample_framework_ar, ARCorePlugin`) for an Android AR app. The script downloads IDTXFlow and creates
directory junctions `addons/<name>` → `shared/addons/<name>`. Junctions need no admin rights. Edits you make in the
Godot editor land in `shared/` directly.

**In a project elsewhere** copy the addon folders you need into your project's `addons/`. Then:

1. Enable the editor plugins `ARCorePlugin` and `IDTXFlow` (Project Settings → Plugins), if you use them.
2. For AR: instance `res://addons/sample_framework_ar/XRSetup.tscn`, add an `ImageTrackedComponent` or `QRCodeTrackedComponent`,
   put your content under it. Export for Android arm64 with the GL Compatibility renderer and the camera permission.
3. For AAS: register `addons/sample_framework_aas/aas_session.gd` as autoload `Session`, then
   `await Session.login(url, user, password)` and `var aas := Session.new_aas_service(); add_child(aas)`.

### Removing a link

`cmd /c rmdir addons\<name>` removes the junction and keeps the files in `shared/`. Do not delete a junction with
Explorer or `Remove-Item -Recurse`: older tools follow it and delete the shared files. On macOS/Linux there are no
junctions; create symlinks (`ln -s ../../shared/addons/sample_framework_core addons/sample_framework_core`) or copy the folders.

## The ARCore plugin

`addons/ARCorePlugin/bin/` holds the built `.aar` files, so the experiments run without an Android build setup.
Rebuild them only after changing the native code in [`arcore_extension/`](arcore_extension/README.md#build):
`./gradlew assemble` there assembles the complete addon in `plugin/demo/addons/ARCorePlugin/`, which you copy over
`addons/ARCorePlugin/`. The wrapper `ARCoreInterface.gd` exists twice: edit
`arcore_extension/plugin/export_scripts_template/ARCoreInterface.gd`, the copy in `addons/ARCorePlugin/` is overwritten
by the next build.
