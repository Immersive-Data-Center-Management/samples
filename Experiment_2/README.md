# Experiment 2 – On-site check

## About this experiment

> [!IMPORTANT]
> Sample code for demonstration only, **not intended for productive use of any kind**. See the
> [repository README](../README.md#about-this-project).

An Android app for a technician in the data center. The app reads the live status of a rack's components from the
Asset Administration Shell (AAS), notices a server that does not respond and sends the technician there. The
technician scans the QR codes on the rack until the app confirms the right server, checks it and sends a short
report back into the AAS. The next person who opens the app sees that report.

The point of the experiment: the technician is standing in front of the real hardware anyway. A QR code on each part
is enough to link it to its digital twin. No search in a list, no wrong server pulled.

<img src="docs/2_task.png" alt="Task" width="19%"> <img src="docs/3_scan_wrong_part.png" alt="Wrong part scanned" width="19%"> <img src="docs/4_inspect.png" alt="Inspection" width="19%"> <img src="docs/5_task_with_report.png" alt="Task with report" width="19%">

What it shows:

1. **AAS as the source of truth, read and write** – the task is derived from `OperationalData` (no separate task
   object), the rack layout comes from its bill of material (`HierarchicalStructures`), and the report is written into `LastInspection`.
2. **Role-based access** – the technician (`technician_1`) may read everything but only write `LastInspection`;
   BaSyx enforces this (`shared/deploy/basyx/rbac_rules.json`).
3. **USD models from the AAS with IDTXFlow** – the task screen shows the rack with all components in their slots,
   loaded at runtime from the URLs in the AAS, with the server to check marked. The technician knows where to go
   before walking to the rack.
4. **QR scanning with the ARCore plugin** – ML Kit barcode scanning on the ARCore camera feed.

### The flow

1. **Login** as `technician_1` (Keycloak).
2. **Task** – the app reads every component of DemoRack01 and its `OperationalData`. The demo stack's simulator keeps
   DemoServer02 `unreachable`, so the technician gets a (fictional) service ticket: "Check DemoServer02 · Go to Rack
   01, U 3". Below it the rack in 3D, DemoServer02 marked. *Last report* shows the previous report, if there is one.
3. **Scan** – scan the QR codes. A wrong part shows where the right one is ("This is DemoServer01 (U 2). You are
   looking for DemoServer02, 1 U above."). The right one opens the inspection.
4. **Inspect** – the camera image of the real server on top, its nameplate and live values (polled every 3 s) below,
   a visual finding from a dropdown and a photo of the server. *Send report* writes `LastInspection` (time,
   technician name, finding, whether a photo was taken). The photo itself is not uploaded.
5. Back at the task, *Last report* now shows the new report. The server stays `unreachable`: checking is not fixing.

To start over, reseed the demo stack (`docker compose run --rm seed` in `shared/deploy`); that empties the reports.

### Data in the AAS

| Submodel | Read / written | Used for |
|---|---|---|
| HierarchicalStructures (IDTA 02011) | read | components of the rack, their slots |
| Models3D (IDTA 02026) | read | USD URLs of rack and components (`DigitalFile`) |
| Nameplate (IDTA 02006) | read | product name, serial number |
| OperationalData (own) | read (polled) | `Status`, `Temperature`, `PowerDraw` (written by the simulator) |
| OperationalData → `LastInspection` | **written** | the report |

Semantic ids and structure: [AAS data model](../shared/deploy/README.md#aas-data-model).
A QR code holds the AAS shell id of its part, e.g. `urn:apeirora.eu:aas:demo:server-02`.

## Requirements and Setup

- Windows, Godot 4.7.2
- An Android phone with ARCore support (arm64) for scanning; the desktop runs the whole flow too (see below)
- The demo stack from [`shared/deploy`](../shared/deploy/README.md), running

### Run

1. Start the demo stack (`docker compose up -d` in `shared/deploy`) and wait for the seed to finish.
2. Close Godot and run `powershell -ExecutionPolicy Bypass -File bootstrap.ps1` in this folder. It installs IDTXFlow
   (Windows + Android), links the shared addons and downloads `arcoreimg`. Skip it if you ran
   [`bootstrap_all.bat`](../bootstrap_all.bat) in the repository root; otherwise it is needed once (and again after
   changing the IDTXFlow version).
3. Open `project.godot` in Godot 4.7.2+.
4. Get the QR codes to scan. Without a real rack, open [`qr_codes/rack_01.jpg`](qr_codes/rack_01.jpg) on a monitor:
   DemoRack01 as it looks in the app, with a QR sticker on every part. Zoom in until one sticker fills about a third
   of the screen, then scan it with the phone (or print the image large). For real hardware, print the single labels
   in [`qr_codes/`](qr_codes/) or [`all_labels.png`](qr_codes/all_labels.png) (A4) and stick them on. The app does not
   use these images.

**Desktop:** press F5. There is no camera, so the scan screen has a text field: Enter submits it as a scanned QR code
(it is prefilled with the right one).

**Phone:** export the Android preset (arm64, debug). The phone has to reach the demo stack:

- **USB:** forward the three ports of the demo stack (login, AAS, 3D models) to the PC:

  ```
  adb reverse tcp:8180 tcp:8180   # login (Keycloak)
  adb reverse tcp:8081 tcp:8081   # AAS (BaSyx)
  adb reverse tcp:8080 tcp:8080   # 3D models (asset server)
  ```

  Then `127.0.0.1` on the phone is the PC and the prefilled URL works. Only while the phone is connected; repeat after
  reconnecting. If the task screen shows "Status unknown", the forwarding is gone.
- **Wi-Fi:** enter `http://<PC LAN IP>:8081` as server URL. The app rewrites the asset URLs the seed stores for
  `127.0.0.1` to that host. The PC must accept connections on 8080, 8081 and 8180; see
  [`shared/deploy/README.md`](../shared/deploy/README.md#phone-access).

### Code layout

- `scripts/app_data.gd` – autoload `AppData`: rack components, the current task (the login is the shared `Session`)
- `scripts/login_state.gd`, `task_state.gd`, `scan_state.gd`, `inspect_state.gd` + `scenes/` – the four steps
- `scenes/main.tscn` – AR rig (from `sample_framework_ar`) and the `StateManager` with the steps in order
- `qr_codes/` – the rack image with QR stickers (`render_rack.py`, renders the sample models in Blender) and the
  printable labels (`generate_qr_codes.py`)
- `addons/` – created by `bootstrap.ps1` (IDTXFlow and links to `../shared/addons/`)

## Licensing

See the [repository README](../README.md#licensing) and [`shared/deploy/README.md`](../shared/deploy/README.md#licensing)
for the components of the demo stack. The ARCore plugin uses Google ARCore and ML Kit, downloaded by the Android build.
