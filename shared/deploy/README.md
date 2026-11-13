# Standalone demo stack

Keycloak + Eclipse BaSyx AAS with fictional seed data, plus a static HTTP
server for the USD assets and a simulator for live data. Experiments 1 and 2
talk to this stack.

All HTTP, demo credentials, in-memory AAS: for a local demo only. Do not
expose this stack to the internet.

## Services

| Service | Image | Host URL | Purpose |
| --- | --- | --- | --- |
| `keycloak` | `quay.io/keycloak/keycloak:26.8.1` | http://127.0.0.1:8180 | Login server (realm `BaSyx`) |
| `aas-environment` | `eclipsebasyx/aas-environment:2.0.0-milestone-15` | http://127.0.0.1:8081 | AAS REST API (shells and submodels) |
| `assets` | `nginx:1.30-alpine` | http://127.0.0.1:8080/api/v1/download/ | Serves the USD files |
| `seed` | `python:3.15-alpine` | – | Fills the AAS with the demo data, then exits |
| `simulator` | `python:3.15-alpine` | – | Updates the live `OperationalData` values every 5 s |

**keycloak**: imports the realm `BaSyx` from
[`keycloak/realm-export.json`](keycloak/realm-export.json) at startup, with the
public client `basyx-client-api` and two users:

| User / password | Role | May | Used by |
|---|---|---|---|
| `demo` / `demo` | `admin` | read and write everything | Experiment 1, seed, simulator |
| `technician_1` / `technician_1` ("Alex Technician") | `technician` | read everything, write only `LastInspection` | Experiment 2 |

Keycloak admin console: `admin` / `admin`.

**aas-environment**: Eclipse BaSyx AAS environment. Every request needs a
Keycloak bearer token, and access is checked against
[`basyx/rbac_rules.json`](basyx/rbac_rules.json), which gives role `admin`
full read/write. Data is kept **in memory only**.

**assets**: nginx serving the files in [`assets/`](assets/) read-only under
`/api/v1/download/<file>`, no login. The files are the rack model
(`ServerRack.usdc`) and the component models (`Server_00.usdc`,
`Server_2U_00.usdc`, `Server_3U_00.usdc`, `PowerSupply_00.usdc`, `NetworkSwitch_00.usdc`). The app downloads them through
IDTXFlow by the URLs stored in the AAS.

**seed**: the Python script [`seed/seed.py`](seed/seed.py). It waits until
Keycloak and BaSyx are ready, logs in as `demo` and writes fictional data
(manufacturer "Apeirora Demo") into the AAS via REST (`PUT`) for three racks:

- **DemoRack01**: 1U servers at U2 and U3, a 3U server at U4, 3U power
  supplies at U12 and U15.
- **DemoRack02**: a 3U power supply at U2, 3U servers at U6 and U9, 1U servers
  at U14, U15 and U16.
- **DemoRack03**: well filled (32 of 42 U): two 3U power supplies, two 3U, five 2U
  and eight 1U servers, two 1U network switches at the top.

That is 33 shells: 3 racks and 30 components. Their submodels are described in
[AAS data model](#aas-data-model) below.

The racks and components are defined in `RACKS` at the top of `seed.py`. The
USD URLs are absolute and built from `ASSET_BASE_URL` (default
`http://127.0.0.1:8080`, override it in `.env`). The seed overwrites the
same ids, so you can rerun it at any time.

## AAS data model

Each rack and each component is one AAS shell. Its `assetInformation.globalAssetId`
(e.g. `urn:apeirora.eu:asset:demo:server-01`) is how the rack's bill of material
points to it. Where an official IDTA submodel template exists, the seed uses it;
the rest is our own, under the `urn:apeirora.eu:smt:` namespace.

| Submodel | Template (semantic id) | On | Contents |
|---|---|---|---|
| `Nameplate` | IDTA 02006 Digital Nameplate 3.0 (`https://admin-shell.io/idta/nameplate/3/0/Nameplate`) | every shell | `ManufacturerName`, `ManufacturerProductDesignation` (multi-language), `SerialNumber`, `YearOfConstruction`, `URIOfTheProduct` |
| `Models3D` | IDTA 02026 Provision of 3D Models (`https://admin-shell.io/idta/Models3D/1/0`) | every shell | `Model3D[0].File.FileVersion[0].DigitalFile` = URL of the USD file on the `assets` service, plus the template's mandatory file metadata (format USD, status Released, ...) |
| `HierarchicalStructures` | IDTA 02011 Hierarchical Structures enabling Bills of Material (`https://admin-shell.io/idta/HierarchicalStructures/1/1/Submodel`) | racks | what is installed in the rack (see below) |
| `OperationalData` | **own** (`urn:apeirora.eu:smt:operationalData:0.1`) | components | live `Status`, `Temperature`, `PowerDraw` and the technician's `LastInspection` report (see [Live data](#live-data-simulator)) |

There is no IDTA template for "current live values" (IDTA 02008 Time Series Data stores
recorded history) or for an inspection result, so `OperationalData` is our own.

**Bill of material.** An *Entity* is an element that stands for an asset, named by its
`globalAssetId`. The template's archetype `OneDown` lists only the direct parts: the
`EntryNode` entity is the rack itself, it contains one *Node* entity per installed
component and one `HasPart` relationship from the rack to each Node. The rack slot is not
covered by the template, so each Node carries our own `HeightUnits` and `PositionFrom`
(semantic ids `urn:apeirora.eu:smt:rackSlot:0.1/...`):

```
HierarchicalStructures            (submodel of the shell DemoRack01)
├─ ArcheType     = "OneDown"
└─ EntryNode     Entity → urn:apeirora.eu:asset:demo:rack-01
   ├─ DemoServer01   Entity → urn:apeirora.eu:asset:demo:server-01
   │  ├─ HeightUnits  = 1     (rack units the part occupies)
   │  └─ PositionFrom = 2     (lowest slot)
   ├─ ...one Node per component
   ├─ HasPart_DemoServer01   EntryNode → DemoServer01
   └─ ...one HasPart per component
```

The apps read the Nodes; they find each component's shell by its `globalAssetId` and take
the model URL from that shell's `Models3D`. The authoritative definition is
[`seed/seed.py`](seed/seed.py).

## Prerequisites

Docker with Docker Compose v2.

- **Windows**: Docker Engine inside WSL2 (Ubuntu), the tested setup. WSL2
  forwards ports published inside WSL to `127.0.0.1` on Windows by default, so
  the stack needs no extra network setup. Docker Desktop should also work.
- **macOS**: Docker Desktop or a compatible runtime (e.g. Colima).

### Docker Engine in WSL2 (Ubuntu)

1. Install WSL with Ubuntu, in PowerShell:

   ```powershell
   wsl --install -d Ubuntu
   ```

   Restart Windows if asked. Then start "Ubuntu" from the Start menu and create a Linux user when asked.

2. Install Docker inside Ubuntu. Ubuntu's own packages are enough:

   ```bash
   sudo apt-get update                                  # refresh Ubuntu's package list
   sudo apt-get install -y docker.io docker-compose-v2  # install Docker Engine and the "docker compose" command
   sudo usermod -aG docker "$USER"                      # allow your user to run docker without sudo
   ```

3. Run `wsl --shutdown` in PowerShell and reopen Ubuntu so the `docker` group membership applies. Verify with
   `docker run --rm hello-world`; if Docker is not running, start it with `sudo service docker start`.

## Start

From this folder (`shared/deploy/`; on Windows in a WSL shell, e.g. in `/mnt/c/<path to repo>/shared/deploy`):

```bash
docker compose up -d
```

The seed only starts writing once Keycloak and BaSyx are ready. To
watch it, run `docker compose logs -f seed`; it ends with `[seed] done` (exit
with Ctrl+C). If the app shows an empty item list, the seed is not finished
yet or has failed, and the log shows why.

Check: http://127.0.0.1:8081/shells should answer HTTP 401 (running, needs a
login), and http://127.0.0.1:8080/api/v1/download/ServerRack.usdc should
download a file. The BaSyx Swagger UI is at
http://127.0.0.1:8081/swagger-ui/index.html.

On Windows, keep a WSL terminal open while using the stack. Otherwise Windows
can shut down the idle WSL VM and stop the containers.
The AAS keeps its data in memory, so after such a stop the app finds no rack
("Is the seed finished?"): run `docker compose run --rm seed` again.

## Stop

```bash
docker compose down
```

The AAS keeps its data in memory only. `docker compose down` discards it, and
the next `docker compose up -d` starts with an empty AAS and seeds it again.
A restart of just the `aas-environment` container also clears the data;
reseed with:

```bash
docker compose run --rm seed
```

## Live data (simulator)

Every component has an `OperationalData` submodel (`urn:apeirora.eu:smt:operationalData:0.1`) with `Status`,
`Temperature`, `PowerDraw` and an empty `LastInspection` collection. The `simulator` service
([`seed/simulate.py`](seed/simulate.py)) writes slightly drifting values every 5 s and keeps one component
`unreachable` (`SIMULATE_UNREACHABLE`, default `server-02`). Experiment 2 turns that into its task and writes its
report into `LastInspection`. A reseed empties `LastInspection` again.

## Phone access

The app on a phone reaches the stack in one of two ways:

- **USB (development):** forward the ports:

  ```
  adb reverse tcp:8180 tcp:8180   # login (Keycloak)
  adb reverse tcp:8081 tcp:8081   # AAS (BaSyx)
  adb reverse tcp:8080 tcp:8080   # 3D models (asset server)
  ```

  `127.0.0.1` on the phone is then the PC, nothing else to change. Only while the phone is connected, and lost when
  the adb server restarts (e.g. after `adb kill-server` or a new USB connection): run the three commands again.
- **Wi-Fi:** use `http://<PC LAN IP>:8081` as server URL in the app (`ipconfig` shows the IP). The seed stores asset
  URLs on `127.0.0.1`; `AasService.reachable_url()` rewrites them to the server host, so no reseed is needed. The PC
  must accept incoming connections:
  - WSL2 needs `networkingMode=mirrored` in `%UserProfile%\.wslconfig` (then `wsl --shutdown`).
  - Allow the ports in the Windows firewall, and for mirrored WSL also in the Hyper-V firewall (elevated PowerShell):
    ```powershell
    # Windows firewall: let the phone reach the three ports of the stack
    New-NetFirewallRule -DisplayName "IDTX demo stack" -Direction Inbound -Protocol TCP -LocalPort 8080,8081,8180 -Action Allow
    # Hyper-V firewall of WSL (that GUID is WSL's fixed id): allow incoming connections to WSL
    Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
    ```

No TLS is configured. Android blocks cleartext HTTP unless the app allows it; check this before relying on Wi-Fi,
and add TLS before distributing a release.

## Authorization rules

BaSyx authorizes direct repository calls against separate target types. The
`basyx/rbac_rules.json` file therefore grants the `admin` role for `aas`,
`submodel`, `concept-description`, and the combined `aas-environment` target.
A single `aas-environment` rule is not enough for `PUT /submodels/...` and
`PUT /shells/...`; seeding would fail with HTTP 403.

The `technician` role may `READ` everything and `UPDATE` only the element path
`LastInspection`. BaSyx checks a `POST` of a new submodel element as `UPDATE` on
`*`, so the technician cannot create elements; that is why the seed creates an
empty `LastInspection` and the app replaces it with `PUT`.

Keycloak imports the realm only when it does not exist yet. After changing
`keycloak/realm-export.json`, recreate the stack: `docker compose down -v`.

## Replacing assets

See [`assets/README.md`](assets/README.md) for the contract replacement models
must follow. IDTXFlow caches assets by URL and does not revalidate them. After
replacing a file at the same URL, close the app and clear its cache:

```powershell
Remove-Item -Recurse -Force "$env:APPDATA\Godot\app_userdata\IDTX Experiment 1\usd_cache"
Remove-Item -Recurse -Force "$env:APPDATA\Godot\app_userdata\IDTX Experiment 2\usd_cache"
```

On macOS the cache is in
`~/Library/Application Support/Godot/app_userdata/IDTX Experiment 1/usd_cache`.

## Licensing

The stack's components are not part of this repository. They are downloaded at setup time and come with their own
licenses:

| Component | Used for | Obtained via | License |
|---|---|---|---|
| [Keycloak](https://www.keycloak.org/) 26.8.1 | login server (demo stack) | Docker image | Apache-2.0 |
| [Eclipse BaSyx](https://eclipse.dev/basyx/) AAS environment 2.0.0-milestone-15 | AAS server (demo stack) | Docker image | MIT |
| [nginx](https://nginx.org/) 1.30 | asset server (demo stack) | Docker image | BSD-2-Clause |
| [Python](https://www.python.org/) 3.15 | runs the seed script (demo stack) | Docker image | PSF-2.0 |
| [Blender](https://www.blender.org/) 5.2 LTS | only to rebuild the USD models | install separately | GPL-2.0-or-later (the models it outputs are ours, Apache-2.0) |

The Docker images also contain a base OS (Alpine or UBI) with further packages under their own licenses. The licenses
listed are those of the main projects.
