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

## Requirements and Setup

The 3D models, images and Android libraries are stored with [Git LFS](https://git-lfs.com/). Install it once
(`git lfs install`; it is included in Git for Windows) **before** you clone. A clone without Git LFS, or a ZIP
download from GitHub, contains small text pointers instead of these files, and Godot reports import errors. Fix an
existing clone with `git lfs pull`.

Close Godot and double-click [`bootstrap_all.bat`](bootstrap_all.bat) (Windows). It downloads IDTXFlow and links the
shared addons into every experiment. To set up a single experiment, run its `bootstrap.ps1` instead. See the
experiment's README for requirements and setup.

Experiments 1 and 2 also need the demo backend (Keycloak, BaSyx AAS and a file server for the 3D models), which runs in
Docker. On Windows, open a WSL shell (e.g. Ubuntu) and start it:

```bash
cd /mnt/c/<path to repo>/shared/deploy   # Windows drive C: is /mnt/c in WSL
docker compose up -d                     # start all services in the background
```

Keep the WSL terminal open while you use it. No WSL or Docker yet? Follow
[Docker Engine in WSL2](shared/deploy/README.md#docker-engine-in-wsl2-ubuntu) once. For checks, stopping and reseeding see
[Start](shared/deploy/README.md#start) and [Stop](shared/deploy/README.md#stop).

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/Immersive-Data-Center-Management/samples/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure

If you find any bug that may be a security problem, please follow the instructions in the [SAP security policy](https://github.com/SAP/.github/blob/main/SECURITY.md) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/SAP/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2026 SAP SE or an SAP affiliate company and samples contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/Immersive-Data-Center-Management/samples).

Experiments may download third-party components at setup time (for example GDExtensions or Docker images). These are not part of this repository and come with their own licenses; see each experiment's README.

Some third-party files are included in this repository and keep their own licenses (listed in [REUSE.toml](REUSE.toml), license texts in [LICENSES/](LICENSES/)): the ARCore plugin (MIT, based on the Godot Android plugin template), Google's ARCore SDK header and native libraries inside it ([ARCore Additional Terms of Service](https://developers.google.com/ar/develop/terms); apps using ARCore must tell their users so; the SDK's `arcoreimg` tool falls under the same terms and is downloaded by `bootstrap.ps1`, not included), and the IDTXFlow Android build in `shared/idtxflow_android` with OpenUSD and oneTBB.
