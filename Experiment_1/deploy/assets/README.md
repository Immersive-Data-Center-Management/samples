# Demo USD assets

The committed files are generated placeholders:

- `ServerRack.usdc` – open 45U rack frame, Z-up, meters.
- `Server_00.usdc` – 1U server, bottom at Z=0, centered in X.
- `Server_3U_00.usdc` – 3U server with a two-row drive face, bottom at Z=0.
- `PowerSupply_00.usdc` – 3U power supply, bottom at Z=0, centered in X.

Both scripts need OpenUSD's Python bindings (`pxr`), from the PyPI package
[`usd-core`](https://pypi.org/project/usd-core/) 26.11 (Python 3.11 to 3.14). Install it with:

```bash
pip install -r requirements.txt
```

Regenerate them with:

```bash
python generate_placeholders.py
```

Verify the committed assets with:

```bash
python verify_assets.py
```

To use other models, replace these files with any USD that follows the
contract below. The app translates each component by `PositionFrom * 0.04445` m
(one rack unit), so no slot prims are needed.

## Selection collision

The app clicks components with a Godot physics raycast. IDTXFlow only creates
physics bodies for prims that explicitly carry its collision schema; it does not
derive colliders from visual meshes.

Every USD asset therefore contains select-only box proxies:

```usda
def Cube "select_1" (
    prepend apiSchemas = ["CollisionAPI"]
)
{
    token collision:shape = "Box"
    token[] collision:interactionTypes = ["Select"]
    token collision:type = "Static"
    double size = 1
    double3 xformOp:translate = (...)
    float3 xformOp:scale = (...)
    uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:scale"]
}
```

`CollisionAPI` is the schema token stored in `apiSchemas`; `IDTXCollisionAPI` is
only the C++/GDExtension class name. The app does not add colliders at runtime.

The collider primitive name is irrelevant for component selection. The app maps
the hit back to the AAS component through the `AAS_Component_N` payload wrapper
(`prim_name`), so the same `Server_00.usdc` can be used for several components.

## Contract for replacement assets

- Root prim is named `root` and is the default prim.
- Z-up, meters per unit = 1.
- Rack: bottom at Z=0; no `Server_Slots` prims required.
- Components: bottom at Z=0; X/Y already aligned with the rack.
- Every clickable asset must contain `CollisionAPI` select proxies.
- Components must be standalone (no relative references), or the HTTP asset
  resolver must be able to fetch their dependencies.

## Cache

IDTXFlow caches downloaded files by URL and does not revalidate them. After
replacing a `.usdc` file at the same URL, clear the app cache or use a new URL.
On Windows:

```powershell
Remove-Item -Recurse -Force "$env:APPDATA\Godot\app_userdata\IDTXFlowExperiment1\usd_cache"
```

Close the app first. The converted scene cache lives in the same directory.
