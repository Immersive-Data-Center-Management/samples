# Standalone demo stack

Keycloak + Eclipse BaSyx AAS with fictional seed data, plus a static HTTP
server for the USD assets. This is the stack the Godot app talks to.

All HTTP, demo credentials, in-memory AAS: for a local demo only. Do not
expose this stack to the internet.

## Services

| Service | Image | Host URL | Purpose |
| --- | --- | --- | --- |
| `keycloak` | `quay.io/keycloak/keycloak:26.8.1` | http://127.0.0.1:8180 | Login server (realm `BaSyx`) |
| `aas-environment` | `eclipsebasyx/aas-environment:2.0.0-milestone-15` | http://127.0.0.1:8081 | AAS REST API (shells and submodels) |
| `assets` | `nginx:1.30-alpine` | http://127.0.0.1:8080/api/v1/download/ | Serves the USD files |
| `seed` | `python:3.15-alpine` | – | Fills the AAS with the demo data, then exits |

**keycloak**: imports the realm `BaSyx` from
[`keycloak/realm-export.json`](keycloak/realm-export.json) at startup, with the
public client `basyx-client-api` and the user `demo` / `demo` (role `admin`).
Keycloak admin console: `admin` / `admin`.

**aas-environment**: Eclipse BaSyx AAS environment. Every request needs a
Keycloak bearer token, and access is checked against
[`basyx/rbac_rules.json`](basyx/rbac_rules.json), which gives role `admin`
full read/write. Data is kept **in memory only**.

**assets**: nginx serving the files in [`assets/`](assets/) read-only under
`/api/v1/download/<file>`, no login. The files are the rack model
(`ServerRack.usdc`) and the component models (`Server_00.usdc`,
`Server_3U_00.usdc`, `PowerSupply_00.usdc`). The app downloads them through
IDTXFlow by the URLs stored in the AAS.

**seed**: the Python script [`seed/seed.py`](seed/seed.py). It waits until
Keycloak and BaSyx are ready, logs in as `demo` and writes fictional data
(manufacturer "Apeirora Demo") into the AAS via REST (`PUT`) for two racks:

- **DemoRack01**: 1U servers at U2 and U3, a 3U server at U4, 3U power
  supplies at U12 and U15.
- **DemoRack02**: a 3U power supply at U2, 3U servers at U6 and U9, 1U servers
  at U14, U15 and U16.

That is 13 shells: 2 racks and 11 components. Each shell has a `Nameplate`
submodel (manufacturer, product name, serial number, year) and a 3D submodel
whose `USDFile` element points to its model on the `assets` service. Each rack
also gets a `RackUsage` submodel. Its `InstalledComponents` list references the
component assets with their height units (`HeightUnits`) and lowest rack slot
(`PositionFrom`), which the app uses to place the models in the rack.

The racks and components are defined in `RACKS` at the top of `seed.py`. The
USD URLs are absolute and built from `ASSET_BASE_URL` (default
`http://127.0.0.1:8080`, override it in `deploy/.env`). The seed overwrites the
same ids, so you can rerun it at any time.

## Prerequisites

Docker with Docker Compose v2.

- **Windows**: Docker Engine inside WSL2 (Ubuntu), the tested setup. WSL2
  forwards ports published inside WSL to `127.0.0.1` on Windows by default, so
  the stack needs no extra network setup. Docker Desktop should also work.
- **macOS**: Docker Desktop or a compatible runtime (e.g. Colima).

### Docker Engine in WSL2 (Ubuntu)

Ubuntu's own packages are enough:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker "$USER"
```

Then run `wsl --shutdown` in PowerShell and reopen Ubuntu so the `docker`
group membership applies. Verify with `docker run --rm hello-world`; if Docker
is not running, start it with `sudo service docker start`.

## Start

From this folder (`Experiment_1/`; on Windows in a WSL shell, e.g. in `/mnt/c/<path to repo>/Experiment_1`):

```bash
cd deploy
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

## Stop

```bash
cd deploy   # from `Experiment_1/`
docker compose down
```

The AAS keeps its data in memory only. `docker compose down` discards it, and
the next `docker compose up -d` starts with an empty AAS and seeds it again.
A restart of just the `aas-environment` container also clears the data;
reseed with:

```bash
docker compose run --rm seed
```

## Authorization rules

BaSyx authorizes direct repository calls against separate target types. The
`basyx/rbac_rules.json` file therefore grants the `admin` role for `aas`,
`submodel`, `concept-description`, and the combined `aas-environment` target.
A single `aas-environment` rule is not enough for `PUT /submodels/...` and
`PUT /shells/...`; seeding would fail with HTTP 403.

## Replacing assets

See [`assets/README.md`](assets/README.md) for the contract replacement models
must follow. IDTXFlow caches assets by URL and does not revalidate them. After
replacing a file at the same URL, close the app and clear its cache:

```powershell
Remove-Item -Recurse -Force "$env:APPDATA\Godot\app_userdata\IDTXFlowExperiment1\usd_cache"
```

On macOS the cache is in
`~/Library/Application Support/Godot/app_userdata/IDTXFlowExperiment1/usd_cache`.
