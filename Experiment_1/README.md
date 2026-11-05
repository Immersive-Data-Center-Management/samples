# Experiment 1

## About this experiment

> [!IMPORTANT]
> Sample code for demonstration only, **not intended for productive use of any kind**. See the
> [repository README](../README.md#about-this-project).

A Godot desktop app that shows how to load **USD (Universal Scene Description) files in Godot with
[IDTXFlow](https://github.com/Immersive-Data-Center-Management/idtx-flow)**. Godot has no built-in USD support;
IDTXFlow is a GDExtension that adds it.

The app logs in via Keycloak, lists the racks from an Asset Administration Shell (AAS) server and shows the selected
rack in 3D. The server rack and every installed component are **USD assets that IDTXFlow downloads over HTTP and
loads at runtime**. None of the 3D models are imported into the Godot project. Clicking a part shows its nameplate
data and live values from the AAS.

<img src="docs/login.png" alt="Login screen" width="49%"> <img src="docs/3d_viewer.png" alt="3D viewer with a rack, the hierarchy and the details panel" width="49%">

The experiment demonstrates three things:

1. **Loading USD with IDTXFlow** (the main focus) – the rack and its components are `.usdc` files. The app only
   knows their URLs; IDTXFlow downloads, caches and renders them, and composes the components into the rack as USD
   payloads.
2. **Using the AAS as the source of truth** – which components sit in which rack slot, which 3D model belongs to
   which asset, and the master data shown in the details panel all come from the AAS at runtime. Nothing is baked into
   the USD files.
3. **Hosting assets on a server** – the USD files are hosted on an asset server and downloaded from there at
   runtime. The demo stack uses a plain nginx server; idtx-core could be used instead (see below).

### How it works

1. **Login** – the app gets an access token from Keycloak (password grant, realm `BaSyx`, client `basyx-client-api`).
   The token URL is derived from the AAS URL: same host, port `8180`. Every AAS request sends the token as a bearer
   token. On HTTP 401 the app returns to the login screen.
2. **Rack list** – every shell with a *HierarchicalStructures* (bill of material) submodel is a rack. The label is
   the shell's `idShort`, the `ManufacturerProductDesignation` from its *Nameplate* submodel, and the number of
   installed components and rack units from the bill of material.
3. **3D viewer** – the app loads the rack's USD file and adds one USD payload per installed component, placed at
   the rack slot given by its `PositionFrom` value.
4. **Details** – clicking a component shows its rack height and position, plus the top-level elements of the
   *Nameplate* submodel of that component's shell (multi-language texts in English), and its live `Status`,
   `Temperature` and `PowerDraw` from *OperationalData*, re-read every 3 s (the demo stack's simulator changes them).

#### Data read from the AAS

| Submodel (semantic id) | Read from | Used for |
|---|---|---|
| HierarchicalStructures (IDTA 02011) | rack shell | per installed component (Node entity) the asset id, `HeightUnits`, `PositionFrom` |
| Models3D (IDTA 02026) | rack and component shells | `DigitalFile` = URL of the USD file |
| Nameplate (IDTA 02006) | rack and component shells | list label and details panel |
| OperationalData (own) | component shells | live values in the details panel (polled) |

A component is linked to its shell by matching the component's `globalAssetId` with the shell's
`assetInformation.globalAssetId`. Semantic ids and structure: [AAS data model](../shared/deploy/README.md#aas-data-model).

#### USD files

The USD files live in [`shared/deploy/assets/`](../shared/deploy/assets/) and are served over HTTP. The AAS only stores their URLs.
The committed models are our own, built with a Blender script, and a few hundred KB each. The app makes no
assumptions about the geometry, so any USD file that follows the asset contract works, including detailed CAD models.
See [`shared/deploy/assets/README.md`](../shared/deploy/assets/README.md) for the contract (root prim, Z-up, slot 0 height,
select colliders) and how to rebuild the models.

#### Asset hosting

The `assets` service in the demo stack is nginx serving `shared/deploy/assets/` read-only under `/api/v1/download/<file>`.
It has no authentication, no upload and no versioning. idtx-core can be used as an alternative asset host, since it
uses the same download URL shape, but this sample does not use it.

## Requirements and Setup

### Prerequisites

- Windows (tested). macOS on Apple Silicon should work too, but is not tested; see below.
- Godot 4.7.2
- IDTXFlow 0.6.1, installed into `addons/IDTXFlow` by `bootstrap.ps1` (not checked in)
- An AAS server with Keycloak: the demo stack below, or your own

**macOS (untested):** the app code has nothing Windows-specific, and IDTXFlow 0.6.1 also ships an Apple Silicon
(arm64) build. Intel Macs are not supported. `bootstrap.ps1` only fetches the Windows build, so install it by hand:
download
[`gdextension-macOS.zip`](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v0.6.1/gdextension-macOS.zip)
and copy its `artifacts/gdextension/IDTXFlow/` folder to `addons/IDTXFlow/`. The zip has a different layout than the
Windows one. If macOS blocks the downloaded libraries, run `xattr -dr com.apple.quarantine addons/IDTXFlow`.

### Demo stack

[`shared/deploy/`](../shared/deploy/README.md) contains a self-contained Keycloak + Eclipse BaSyx + nginx stack with
fictional demo data (three racks with 30 components). Experiment 2 uses the same stack. It needs Docker with
Compose v2; on Windows the tested setup is Docker Engine inside WSL2. From the repository root (on Windows in a WSL
shell):

```bash
cd shared/deploy
docker compose up -d
```

Docker setup, the services and seed data, stopping and reseeding are described in
[`shared/deploy/README.md`](../shared/deploy/README.md).

### Run the app

1. Make sure the demo stack (or your own AAS server) is running and the seed has finished. Without it, the login
   fails.
2. Install IDTXFlow and link the shared addons. Skip it if you ran [`bootstrap_all.bat`](../bootstrap_all.bat) in the
   repository root; otherwise it is needed once (and again after changing the IDTXFlow version). Close Godot first,
   because it locks the DLLs. From this folder (`Experiment_1/`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File bootstrap.ps1   # Bypass: Windows blocks unsigned scripts by default
   ```
   The script calls [`shared/bootstrap.ps1`](../shared/bootstrap.ps1). It links `addons/sample_framework_core` and
   `addons/sample_framework_aas` to `shared/addons/` and downloads the Windows binary release
   ([`gdextension-Windows.zip`](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v0.6.1/gdextension-Windows.zip)
   from the [idtx-flow v0.6.1 release](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/tag/v0.6.1)),
   checks its SHA256 and unzips it to `addons/IDTXFlow/`. You can also skip it and do this by hand.
3. Open `Experiment_1/project.godot` in Godot 4.7.2 and run the project (F5), or export it as a Windows executable.
4. Log in. The server URL `http://127.0.0.1:8081` and user `demo` are prefilled; the password is `demo`.
   For your own server, enter its AAS URL. Keycloak must be on the same host at port 8180.
5. Double-click a rack in the list to open the 3D viewer. Click a component to see its details.

### Viewer controls

| Input | Action |
|---|---|
| Left click | Select rack or component (also in the hierarchy); empty space clears. The camera then orbits around it. |
| F | Zoom to the selection |
| Left drag / Right or middle drag / Wheel | Orbit / pan / zoom |
| Touch: drag / two-finger drag / pinch | Orbit / pan / zoom |

The hierarchy and details panels can be moved and resized.

### Code layout

- `scenes/main.tscn` + `scripts/main.gd` – the `StateManager` with the three screens in order
- `scripts/screens/` + `scenes/screens/` – login, rack list, 3D viewer (each a `FlowState`)
- `scripts/app_data.gd` – autoload `AppData`: the rack picked in the list (the login is the shared `Session`)
- `scripts/ui/` + `scenes/ui/` – hierarchy and details panels
- `scripts/viewer/grid_floor.gd`, `materials/grid.tres` – the floor grid
- `addons/` – created by `bootstrap.ps1`: IDTXFlow, and links to the shared `sample_framework_aas` (`AasService`,
  `KeycloakLogin`, `RackComponents`) and `sample_framework_core` (orbit camera, picking/highlighting, floating
  panel), see
  [`shared/README.md`](../shared/README.md)

## Licensing

See the [repository README](../README.md#licensing). [IDTXFlow](https://github.com/Immersive-Data-Center-Management/idtx-flow)
0.6.1 is downloaded by `bootstrap.ps1` into `addons/IDTXFlow/` and comes with its own licenses (see its release, incl.
`LICENSES-THIRD-PARTY/`). The demo stack's components are listed in
[`shared/deploy/README.md`](../shared/deploy/README.md#licensing).
