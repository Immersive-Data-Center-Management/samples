[![REUSE status](https://api.reuse.software/badge/github.com/Immersive-Data-Center-Management/samples)](https://api.reuse.software/info/github.com/Immersive-Data-Center-Management/samples)

# Experiment 1

## About this project

Immersive Data Center Management Sample.

**Experiment 1** is a Godot desktop app that logs in via Keycloak, lists the racks from an Asset Administration Shell (AAS) server and
shows the selected rack with its installed components in 3D. Clicking a part shows its nameplate data from the AAS.

The experiment demonstrates three things:

1. **Loading USD with IDTXFlow** – the rack and its components are USD files streamed over HTTP and rendered by the
   IDTXFlow GDExtension.
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
3. **3D viewer** – the app loads the rack's USD file and adds one USD payload per installed component, raised by
   `PositionFrom` rack units (0.04445 m each).
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

**macOS (untested):** the app code has nothing Windows-specific, and IDTXFlow 0.6.0 also ships an Apple Silicon
(arm64) build. Intel Macs are not supported. `bootstrap.ps1` only fetches the Windows build, so install it by hand:
download
[`gdextension-macOS.zip`](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v0.6.0/gdextension-macOS.zip)
and copy its `artifacts/gdextension/IDTXFlow/` folder to `addons/IDTXFlow/`. The zip has a different layout than the
Windows one. If macOS blocks the downloaded libraries, run `xattr -dr com.apple.quarantine addons/IDTXFlow`. For the
demo stack on a Mac, use Docker Desktop.
- An AAS server with Keycloak: the demo stack below, or your own

### Demo stack

[`deploy/`](deploy/README.md) contains a self-contained Keycloak + Eclipse BaSyx + nginx stack with fictional demo
data. It needs Docker with Compose v2 and its ports 8080, 8081 and 8180 reachable from Windows:

- **Docker Engine inside WSL2** (the tested setup): install Docker in your WSL2 distribution and turn on mirrored
  networking. Run the commands below in a WSL shell, e.g. from `/mnt/c/<path to repo>/deploy`. Keep a WSL
  terminal open, otherwise Windows shuts down the idle WSL VM and the containers stop. Step-by-step setup:
  [`deploy/README.md`](deploy/README.md#prerequisites).
- **Docker Desktop** should also work, because it publishes ports to Windows by itself. Not tested.
- **Linux or macOS** can host the stack too. Only the Godot app is Windows-only.

From the repo root:

```bash
cd deploy
docker compose up -d
docker compose logs -f seed   # wait for "[seed] done", then Ctrl+C
```

Check: http://127.0.0.1:8081/shells should answer HTTP 401 (running, needs a login), and
http://127.0.0.1:8080/api/v1/download/ServerRack.usdc should download a file.

What this starts (four containers, all HTTP, local demo only, do not expose to the internet):

| Container | Image | Port | What it is |
|---|---|---|---|
| `keycloak` | `quay.io/keycloak/keycloak:26.8.1` | 8180 | Login server. Imports realm `BaSyx` with public client `basyx-client-api` and user `demo` / `demo` (role `admin`). Keycloak admin console: `admin` / `admin`. |
| `aas-environment` | `eclipsebasyx/aas-environment:2.0.0-milestone-15` | 8081 | AAS REST API (shells and submodels). Accepts only Keycloak tokens; `basyx/rbac_rules.json` gives role `admin` full read/write. Data is **in memory only**. |
| `assets` | `nginx:1.27-alpine` | 8080 | Serves `deploy/assets/*.usdc` read-only at `/api/v1/download/<file>`, no login. |
| `seed` | `python:3.12-alpine` | – | Runs `seed/seed.py` once, then exits. Waits for Keycloak and BaSyx, logs in as `demo` and writes the demo data. |

The seed creates fictional data (manufacturer "Apeirora Demo") for two racks:

- **DemoRack01** – 1U servers at U2 and U3, a 3U server at U4, 3U power supplies at U12 and U15.
- **DemoRack02** – a 3U power supply at U2, 3U servers at U6 and U9, 1U servers at U14, U15 and U16.

That is 13 shells: 2 racks and 11 components. Each shell has a *Nameplate* submodel (manufacturer, product name,
serial number, year) and a *3D assets* submodel with the URL of its USD file. Racks also get a *RackUsage*
submodel that lists their components. The USD URLs start with `ASSET_BASE_URL` (default `http://127.0.0.1:8080`,
set it in `deploy/.env`).

The seed can run any number of times; it overwrites the same ids. Because the AAS keeps data in memory, rerun it
after BaSyx restarts: `docker compose run --rm seed`. To change the demo data, edit `RACKS` in
[`deploy/seed/seed.py`](deploy/seed/seed.py). Prerequisites (Docker Engine in WSL2), LAN/Android access and
troubleshooting are in [`deploy/README.md`](deploy/README.md).

### Run the app

1. Make sure the demo stack (or your own AAS server) is running and the seed has finished. Without it, the login
   fails.
2. Install IDTXFlow (once, and again after changing its version in the script). Close Godot first, because it
   locks the DLLs. From the repo root:
   ```powershell
   powershell -ExecutionPolicy Bypass -File bootstrap.ps1
   ```
   The script only downloads the Windows binary release
   ([`gdextension-Windows.zip`](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/download/v0.6.0/gdextension-Windows.zip)
   from the [idtx-flow v0.6.0 release](https://github.com/Immersive-Data-Center-Management/idtx-flow/releases/tag/v0.6.0)),
   checks its SHA256 and unzips it to `addons/IDTXFlow/`. You can skip it and do this by hand: the zip contains an
   `IDTXFlow/` folder, so unzip it into `addons/`.
3. Open `project.godot` in Godot 4.7.2 and run the project (F5), or export it as a Windows executable.
   In the editor's embedded Game view, switch to **Input** mode, otherwise clicks go to the editor.
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

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/Immersive-Data-Center-Management/samples/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/Immersive-Data-Center-Management/samples/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/Immersive-Data-Center-Management/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2026 SAP SE or an SAP affiliate company and samples contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/Immersive-Data-Center-Management/samples).

IDTXFlow (`addons/IDTXFlow/`) and the Docker images of the demo stack (Keycloak, Eclipse BaSyx, nginx, Python) are not part of this repository; they are downloaded at setup time and come with their own licenses.
