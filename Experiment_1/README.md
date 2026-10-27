# Experiment 1

## About this experiment

A Godot desktop app that shows how to load **USD (Universal Scene Description) files in Godot with
[IDTXFlow](https://github.com/Immersive-Data-Center-Management/idtx-flow)**. Godot has no built-in USD support;
IDTXFlow is a GDExtension that adds it.

The app logs in via Keycloak, lists the racks from an Asset Administration Shell (AAS) server and shows the selected
rack in 3D. The server rack and every installed component are **USD assets that IDTXFlow downloads over HTTP and
loads at runtime**. None of the 3D models are imported into the Godot project. Clicking a part shows its nameplate
data from the AAS.

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
2. **Rack list** – every shell with a *RackUsage* submodel is a rack. The label is the shell's `idShort` plus the
   `ManufacturerProductDesignation` from its *Nameplate* submodel.
3. **3D viewer** – the app loads the rack's USD file and adds one USD payload per installed component, placed at
   the rack slot given by its `PositionFrom` value.
4. **Details** – clicking a component shows its rack height and position, plus the top-level elements of the
   *Nameplate* submodel of that component's shell (multi-language texts in English).

#### Data read from the AAS

| Submodel (semantic id) | Read from | Used for |
|---|---|---|
| RackUsage (`urn:apeirora.eu:smt:rackUsage:0.1`) | rack shell | `InstalledComponents`: per component the asset id (`Entity.globalAssetId`), `HeightUnits`, `PositionFrom` |
| 3D assets (`urn:apeirora.eu:smt:3dAssets:0.1`) | rack and component shells | first `File` element = URL of the USD file |
| Nameplate (`https://admin-shell.io/idta/nameplate/3/0/Nameplate`) | rack and component shells | list label and details panel |

A component is linked to its shell by matching the component's `globalAssetId` with the shell's
`assetInformation.globalAssetId`.

#### USD files

The USD files live in [`deploy/assets/`](deploy/assets/) and are served over HTTP. The AAS only stores their URLs.
The committed files are simple, generated placeholders on purpose: they are license-safe and only a few KB. The app
makes no assumptions about the geometry, so any USD file that follows the asset contract works, including detailed
CAD models. See [`deploy/assets/README.md`](deploy/assets/README.md) for the contract (root prim, Z-up, bottom at
Z=0, select colliders) and the script that generates the placeholders.

#### Asset hosting

The `assets` service in the demo stack is nginx serving `deploy/assets/` read-only under `/api/v1/download/<file>`.
It has no authentication, no upload and no versioning. idtx-core can be used as an alternative asset host, since it
uses the same download URL shape, but this sample does not use it.

## Requirements and Setup

### Prerequisites

- Windows (tested). macOS on Apple Silicon should work too, but is not tested; see below.
- Godot 4.7.2
- IDTXFlow 0.6.0, installed into `addons/IDTXFlow` by `bootstrap.ps1` (not checked in)
- An AAS server with Keycloak: the demo stack below, or your own

**macOS (untested):** the app code has nothing Windows-specific, and IDTXFlow 0.6.0 also ships an Apple Silicon
(arm64) build. Intel Macs are not supported. `bootstrap.ps1` only fetches the Windows build, so install it by hand:
download
[`gdextension-macOS.zip`](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v0.6.0/gdextension-macOS.zip)
and copy its `artifacts/gdextension/IDTXFlow/` folder to `addons/IDTXFlow/`. The zip has a different layout than the
Windows one. If macOS blocks the downloaded libraries, run `xattr -dr com.apple.quarantine addons/IDTXFlow`.

### Demo stack

[`deploy/`](deploy/README.md) contains a self-contained Keycloak + Eclipse BaSyx + nginx stack with fictional demo
data (two racks with eleven components). It needs Docker with Compose v2; on Windows the tested setup is Docker
Engine inside WSL2. From this folder (`Experiment_1/`; on Windows in a WSL shell):

```bash
cd deploy
docker compose up -d
```

Docker setup, the services and seed data, stopping and reseeding are described in
[`deploy/README.md`](deploy/README.md).

### Run the app

1. Make sure the demo stack (or your own AAS server) is running and the seed has finished. Without it, the login
   fails.
2. Install IDTXFlow (once, and again after changing its version in the script). Close Godot first, because it
   locks the DLLs. From this folder (`Experiment_1/`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
   ```
   The script only downloads the Windows binary release
   ([`gdextension-Windows.zip`](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v0.6.0/gdextension-Windows.zip)
   from the [idtx-flow v0.6.0 release](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/tag/v0.6.0)),
   checks its SHA256 and unzips it to `addons/IDTXFlow/`. You can also skip it and do this by hand.
3. Open `Experiment_1/project.godot` in Godot 4.7.2 and run the project (F5), or export it as a Windows executable.
4. Log in. The server URL `http://127.0.0.1:8081` and user `demo` are prefilled; the password is `demo`.
   For your own server, enter its AAS URL. Keycloak must be on the same host at port 8180.
5. Double-click a rack in the list to open the 3D viewer. Click a component to see its details.

Tests: see [`tests/README.md`](tests/README.md).

### Viewer controls

| Input | Action |
|---|---|
| Left click | Select rack or component (also in the hierarchy); empty space clears |
| F | Focus the camera on the selection |
| Right drag / Middle drag / Wheel | Orbit / pan / zoom |
| W / S, A / D | Move the orbit center up / down, sideways |

The hierarchy and details panels can be moved and resized.

### Code layout

- `scripts/app_state.gd` – autoload: AAS URL and access token
- `scripts/aas/` – `AasService` (REST client) and `RackComponents` (reads RackUsage, resolves models, builds the USD
  session layer)
- `scripts/screens/` + `scenes/screens/` – login, rack list, 3D viewer
- `scripts/ui/` + `scenes/ui/` – floating panels: hierarchy and details
- `scripts/viewer/` – orbit camera, picking and highlighting, grid floor; `materials/` holds their materials
- `addons/IDTXFlow/` – USD loading GDExtension, downloaded by `bootstrap.ps1`
- `deploy/` – demo stack, seed data and USD assets
- `tests/` – offline checks for the AAS parsing

## Licensing

See the [repository README](../README.md#licensing). IDTXFlow (`addons/IDTXFlow/`) and the Docker images of the demo
stack (Keycloak, Eclipse BaSyx, nginx, Python) are not part of this repository; they are downloaded at setup time and
come with their own licenses.
