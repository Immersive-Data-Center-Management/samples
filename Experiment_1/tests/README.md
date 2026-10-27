# Tests

Offline checks for the AAS parsing helpers. They need no server. Run from the experiment folder (`Experiment_1/`):

```bash
godot --headless --path . res://tests/test_aas_service.tscn
godot --headless --path . res://tests/test_rack_components.tscn
```

Each prints `...: OK`, or stops with an assertion error.

- `test_aas_service` – `AasService` static helpers (id encoding, submodel refs, semantic id matching, file values).
- `test_rack_components` – `RackComponents` parsing of `InstalledComponents` and the generated USD session layer.

To check the USD files in `deploy/assets/`, see `python deploy/assets/verify_assets.py`.
