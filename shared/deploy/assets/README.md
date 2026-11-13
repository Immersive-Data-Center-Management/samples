# Demo USD assets

Original models, built with [`blender/build_assets.py`](blender/build_assets.py) (Apache-2.0 like the rest
of the repository):

| File | Model | Size |
|---|---|---|
| `ServerRack.usdc` | 42U rack, open front, perforated rear door | ~370 KB |
| `Server_00.usdc` | 1U server, 8 × 2.5" drives | ~120 KB |
| `Server_2U_00.usdc` | 2U server with bezel | ~190 KB |
| `Server_3U_00.usdc` | 3U storage server, 18 × 3.5" drives | ~210 KB |
| `PowerSupply_00.usdc` | 3U PDU: breakers and LCD in front, C13/C19 outlets in the back | ~260 KB |
| `NetworkSwitch_00.usdc` | 1U switch, 48 × RJ45 + 4 × SFP | ~270 KB |

Each model has a few meshes: the chassis, one merged `details` mesh and a separate `StatusLed`. Port link
LEDs are off, since no cables are plugged in.

## Rebuild

Blender 5.2 LTS (its bundled Python has `pxr`, used to add the select colliders):

```powershell
& "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe" --background --factory-startup --python blender\build_assets.py
```

This overwrites the `.usdc` files in this folder.

## Selection collision

The apps click components with a Godot physics raycast. IDTXFlow only creates physics bodies for prims
that explicitly carry its collision schema; it does not derive colliders from visual meshes. Blender's
USD export can't write that schema, so `build_assets.py` adds select-only box proxies after the export:

```usda
def Cube "select_0" (
    prepend apiSchemas = ["CollisionAPI"]
)
{
    token collision:shape = "Box"
    token[] collision:interactionTypes = ["Select"]
    token collision:type = "Static"
    uniform token purpose = "guide"
    ...
}
```

Components get one box around the model. The rack gets one box per frame part (posts, panels, roof,
plinth, door), so a click inside the rack reaches the component there.

The collider name is irrelevant for selection. The app maps the hit back to the AAS component through
the `AAS_Component_N` payload wrapper (`prim_name`), so the same `Server_00.usdc` can be used for
several components.

## Contract for replacement assets

- Root prim is named `root` and is the default prim. Z-up, meters per unit = 1.
- Front faces −Y; 19" width (0.48 m with the rack ears), depth 0.80 m.
- Rack: feet at Z = 0, slot 0 at Z = 0.098 m (`RackComponents.RACK_SLOT_0_Z_M`). The app places a
  component at `0.098 + PositionFrom * 0.04445` m, so no slot prims are needed.
- Components: bottom at Z = 0, centered in X, aligned with the rack in Y.
- Every clickable asset must contain `CollisionAPI` select proxies.
- Components must be standalone (no relative references), or the HTTP asset resolver must be able to
  fetch their dependencies.

## Cache

IDTXFlow caches downloaded files by URL and does not revalidate them. After replacing a `.usdc` file at
the same URL, clear the app cache or use a new URL. On Windows:

```powershell
Remove-Item -Recurse -Force "$env:APPDATA\Godot\app_userdata\IDTX Experiment 1\usd_cache"
```

Close the app first. The converted scene cache lives in the same directory. Experiment 2 uses
`IDTX Experiment 2` instead of `IDTX Experiment 1`.
