[![REUSE status](https://api.reuse.software/badge/github.com/Immersive-Data-Center-Management/samples)](https://api.reuse.software/info/github.com/Immersive-Data-Center-Management/samples)

# Samples

## About this project

Immersive Data Center Management Samples: small, complete apps that show how the IDTX tools work together –
**IDTXFlow** (USD in Godot), the **Asset Administration Shell** (AAS) as data source, and our **ARCore plugin** for
Godot. Each experiment lives in its own folder with its own README; the parts they share are in
[`shared/`](shared/README.md).

> [!IMPORTANT]
> The code in this repository is sample code for demonstration and experimentation only. It is **not intended for
> productive use of any kind**. It is not hardened, tested or supported for production: demo credentials, plain HTTP
> and in-memory data stores are used on purpose.

## Experiments

| Folder | User story | Shows | Platform |
|---|---|---|---|
| [`Experiment_1/`](Experiment_1/README.md) | *Browse the data center:* pick a rack from a list and look at it in 3D, with the nameplate data and live values of every part. | IDTXFlow (USD downloaded at runtime, composed from AAS data), AAS read, Keycloak | Windows desktop |
| [`Experiment_2/`](Experiment_2/README.md) | *On-site check:* the app finds a server that does not respond, the technician scans QR codes at the rack until the right one is found, checks it and sends a report back. | AAS read + write with role-based access, live data, USD from the AAS, QR scanning (ARCore plugin) | Android (desktop for testing) |
| [`Experiment_3/`](Experiment_3/README.md) | *Take the rack with you:* point the phone at a rack, see its parts in AR with a warning on the overheating one, freeze the view and keep exploring at your desk. | ARCore plugin (image tracking, freeze), 3D view of the AR content, USD in AR, AR picking | Android (desktop preview) |
| [`shared/`](shared/README.md) | Reusable Godot addons, the ARCore plugin source, the demo backend (Keycloak + BaSyx) | – | – |

## Quick start

Step by step from a fresh PC to all three experiments running. Each step links to the details for when something
goes wrong.

### What you need

| | Exp 1 | Exp 2 | Exp 3 |
|---|---|---|---|
| Windows, [Godot 4.7.2](https://godotengine.org/download), Git with [Git LFS](https://git-lfs.com/) | ✓ | ✓ | ✓ |
| Docker in WSL2, for the demo backend (Keycloak, AAS, 3D models) | ✓ | ✓ | – |
| Android phone with ARCore (arm64), USB debugging on | – | ✓, the desktop is a fallback without camera | ✓, the desktop is only a preview |
| Something to point the phone at | – | [`rack_01.jpg`](Experiment_2/qr_codes/rack_01.jpg) on a monitor, or printed QR codes | [image target](Experiment_3/docs/full_image_target.jpg) printed at **19 cm width** |

### Steps

1. **Clone with Git LFS.** Run `git lfs install` once, **before** you clone. Without it, or with a ZIP download, the
   3D models, images and Android libraries are small text pointers and Godot reports import errors. Already cloned:
   `git lfs pull`.
2. **Bootstrap.** Close Godot and double-click [`bootstrap_all.bat`](bootstrap_all.bat). It downloads IDTXFlow and
   links the shared addons into every experiment. Without it the projects open with missing addons.
3. **Start the demo backend** (Exp 1 and 2). These two apps have no built-in data: after a Keycloak login they read
   the racks and live values from the AAS and download the 3D models (USD) from an asset server. The backend runs
   all three locally with fictional demo data.

   <details>
   <summary>No WSL or Docker yet? One-time setup, about 10 minutes</summary>

   In PowerShell: `wsl --install -d Ubuntu`, restart Windows if asked. Start "Ubuntu" from the Start menu and create
   a Linux user. Then in Ubuntu:
   ```bash
   sudo apt-get update                                  # refresh Ubuntu's package list
   sudo apt-get install -y docker.io docker-compose-v2  # install Docker Engine and the "docker compose" command
   sudo usermod -aG docker "$USER"                      # allow your user to run docker without sudo
   ```
   Run `wsl --shutdown` in PowerShell and reopen Ubuntu, so the group change applies. Details:
   [Docker Engine in WSL2](shared/deploy/README.md#docker-engine-in-wsl2-ubuntu).
   </details>

   In a WSL shell (e.g. Ubuntu):
   ```bash
   cd /mnt/c/<path to repo>/shared/deploy   # Windows drive C: is /mnt/c in WSL
   docker compose up -d                     # start all services in the background
   docker compose logs -f seed              # wait for "[seed] done", then Ctrl+C
   ```
   Keep the WSL terminal open. If WSL stops, the data is gone and the app finds no rack: run
   `docker compose run --rm seed` again.

   Docker Desktop already installed? It should work too (not tested): run the same commands in PowerShell in
   `shared/deploy`, no WSL shell needed. Check its license terms first; larger companies need a paid subscription.

   *Problems:* Docker not running → `sudo service docker start`; checks and reseeding →
   [Start](shared/deploy/README.md#start).
4. **Run on the desktop.** Open the experiment's `project.godot` in Godot 4.7.2 and press F5. The login is prefilled
   (Exp 1: `demo` / `demo`, Exp 2: `technician_1` / `technician_1`). Exp 2 and 3 are made
   for the phone; the desktop is a quick check without camera (Exp 2: Enter in the text field "scans" the prefilled
   QR code).
5. **Run on the phone** (Exp 2 and 3), once per PC:
   - Set up Godot's Android export: export templates, Android SDK and Java (Editor Settings → Export → Android), see
     [Exporting for Android](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html).
   - In each project: **Project → Install Android Build Template** (the presets use a Gradle build, and the `android/`
     folder is not checked in).
   - Connect the phone and use the one-click deploy button (top right) or **Project → Export → Android**.
   - Exp 2 only, after every USB reconnect: let the phone reach the backend on the PC.
     ```
     adb reverse tcp:8180 tcp:8180   # login (Keycloak)
     adb reverse tcp:8081 tcp:8081   # AAS (BaSyx)
     adb reverse tcp:8080 tcp:8080   # 3D models (asset server)
     ```
     "Status unknown" or a failing login on the phone means this is missing.

   *Problems:* Wi-Fi instead of USB → [Phone access](shared/deploy/README.md#phone-access); what to scan or aim at →
   [Experiment 2](Experiment_2/README.md#run), [Experiment 3](Experiment_3/README.md#requirements-and-setup).

Each experiment has a more detailed README: how it works, the full requirements and setup (including a single
experiment and macOS) and the code layout: [Experiment 1](Experiment_1/README.md),
[Experiment 2](Experiment_2/README.md), [Experiment 3](Experiment_3/README.md). The shared addons and the demo backend
are described in [`shared/`](shared/README.md) and [`shared/deploy/`](shared/deploy/README.md).

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/Immersive-Data-Center-Management/samples/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure

If you find any bug that may be a security problem, please follow the instructions in the [security policy](SECURITY.md) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2026 SAP SE or an SAP affiliate company and samples contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/Immersive-Data-Center-Management/samples).

Experiments may download third-party components at setup time (for example GDExtensions or Docker images). These are not part of this repository and come with their own licenses; see each experiment's README.

Some third-party files are included in this repository and keep their own licenses (listed in [REUSE.toml](REUSE.toml), license texts in [LICENSES/](LICENSES/)): the ARCore plugin (MIT, based on the Godot Android plugin template), Google's ARCore SDK header and native libraries inside it ([ARCore Additional Terms of Service](https://developers.google.com/ar/develop/terms); apps using ARCore must tell their users so; the SDK's `arcoreimg` tool falls under the same terms and is downloaded by `bootstrap.ps1`, not included), and the IDTXFlow Android build in `shared/idtxflow_android` with OpenUSD and oneTBB.
