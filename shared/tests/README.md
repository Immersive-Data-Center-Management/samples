# Tests

Offline checks for the shared addons. They need no server, AR device or USD assets. The tests live next to the
code they check (`shared/addons/<addon>/tests/`) and run inside any experiment that links the addon. Experiment 1
links both `sample_framework_core` and `sample_framework_aas`, so all of them run from there.

From the repository root, after `bootstrap_all.bat` (or the experiment's `bootstrap.ps1`):

```bash
godot --headless --path Experiment_1 res://addons/sample_framework_aas/tests/test_aas_service.tscn
godot --headless --path Experiment_1 res://addons/sample_framework_aas/tests/test_rack_components.tscn
godot --headless --path Experiment_1 res://addons/sample_framework_core/tests/test_pickable_object.tscn
```

Each prints `...: OK` and exits with code 0, or prints every failed check and exits with code 1.

| Test | Checks |
|---|---|
| `sample_framework_aas/tests/test_aas_service` | `AasService` helpers (id encoding, submodel refs, semantic id matching, file values, multi-language texts), Keycloak token URL and claims, `reachable_url()`, `AasSession` expiry on HTTP 401 |
| `sample_framework_aas/tests/test_rack_components` | `RackComponents`: parsing the rack's bill of material, the generated USD session layer |
| `sample_framework_core/tests/test_pickable_object` | `PickableObject` / `ObjectPicker`: automatic and async collider fitting, authored colliders kept, visual states, warning markers, visibility gating, box picking, tap vs. gesture |
