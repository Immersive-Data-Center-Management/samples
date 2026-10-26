# Standalone demo stack

Keycloak + Eclipse BaSyx AAS with fictional seed data, plus a static HTTP
server for the USD assets. This is the stack the Godot app talks to; it has no
dependency on SAP-internal or Kyma infrastructure.

## Services

| Service | Host URL | Purpose |
| --- | --- | --- |
| `assets` | http://127.0.0.1:8080/api/v1/download/ | Serves the USD files |
| `aas-environment` | http://127.0.0.1:8081 | AAS/submodel REST API (BaSyx) |
| `keycloak` | http://127.0.0.1:8180 | OIDC token endpoint (realm `BaSyx`) |
| `seed` | one-shot | Creates the demo shells/submodels |

Demo login: user `demo`, password `demo`. Keycloak admin: `admin` / `admin`.
These credentials, the HTTP-only setup and the in-memory AAS are for a local
demo only. Do not expose this stack to the internet.

## Prerequisites

- Windows with WSL2 and **Docker Engine inside WSL2** (no Docker Desktop).
- Mirrored WSL networking, or a port proxy, so the Windows host and other
  devices on the LAN can reach the published ports.

### Docker Engine in WSL2 (Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Start Docker (`sudo service docker start`, or `sudo systemctl enable --now
docker` if systemd is enabled), then log out and back in so the `docker` group
membership applies. Verify with `docker run --rm hello-world`.

### Mirrored networking

Add this to `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Then run `wsl --shutdown` once and restart Docker/Ubuntu. Without mirrored
networking, ports published inside WSL2 are not reachable from the Windows host
or the LAN. As a fallback, forward the ports from an elevated PowerShell (re-run
this after the WSL IP changes):

```powershell
$wslIp = (wsl hostname -I).Trim() -split '\s+' | Select-Object -First 1
foreach ($port in 8080,8081,8180) {
  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 `
    listenport=$port connectaddress=$wslIp connectport=$port
}
```

Allow the ports through Windows Firewall from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "IDTX demo stack" -Direction Inbound `
  -Protocol TCP -LocalPort 8080,8081,8180 -Action Allow
```

## Start

```bash
cd deploy
docker compose up -d
docker compose logs -f seed
```

Docker Engine runs inside WSL2. Keep a WSL terminal open while using the
stack, or start a background keep-alive process, otherwise Windows can shut
down the idle WSL VM and stop the containers:

```powershell
wsl -d Ubuntu -- sleep infinity
```

The seed waits for Keycloak and BaSyx, obtains a token and creates the demo
data. It is idempotent; rerun it with:

```bash
docker compose run --rm seed
```

In the Godot app use:

- Server URL: `http://127.0.0.1:8081`
- Username: `demo`
- Password: `demo`

The app derives the Keycloak token URL from the server host and port `8180`.

## LAN / Android

The seed stores absolute USD URLs. To use the stack from another device:

1. Find the Windows host's LAN IPv4 address (`ipconfig`).
2. Create `deploy/.env` (copy `.env.example`) and set:
   `ASSET_BASE_URL=http://<host-ip>:8080`
3. Recreate the seed so the new URLs are stored:
   `docker compose up -d --force-recreate seed`
4. Use `http://<host-ip>:8081` as the server URL in the app.

No TLS is configured; Android release builds reject cleartext HTTP. Use a debug
build for the demo, or add TLS before distributing a release.

## Useful endpoints

- AAS shells: http://127.0.0.1:8081/shells
- BaSyx Swagger UI: http://127.0.0.1:8081/swagger-ui/index.html
- Assets: http://127.0.0.1:8080/api/v1/download/ServerRack.usdc

## Authorization rules

BaSyx authorizes direct repository calls against separate target types. The
`basyx/rbac_rules.json` file therefore grants the `admin` role for `aas`,
`submodel`, `concept-description`, and the combined `aas-environment` target.
A single `aas-environment` rule is not enough for `PUT /submodels/...` and
`PUT /shells/...`; seeding would fail with HTTP 403.

The AAS is in-memory. `docker compose down` removes the data; the next
`docker compose up -d` starts with an empty AAS and runs the seed again. A
restart of just the `aas-environment` container also clears the data; rerun
the seed with `docker compose run --rm seed`.

## Assets

The committed USD files are small generated placeholders. They are
deliberately license-safe and make the sample work out of the box. Every asset
contains `CollisionAPI` select proxies; the app does not generate colliders at
runtime. See [`assets/README.md`](assets/README.md) for the asset contract
replacement models must follow.

IDTXFlow caches assets by URL and does not revalidate them. After replacing a
file at the same URL, clear the app cache:

```powershell
Remove-Item -Recurse -Force "$env:APPDATA\Godot\app_userdata\IDTXFlowExperiment1\usd_cache"
```

Close the Godot app first.
