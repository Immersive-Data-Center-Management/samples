# USD Decimate/Remesh Script Guide

This guide explains how to use `usd_decimate_recalc_normals.py` for reducing USD mesh complexity with Blender in headless mode.

Script file:
- `shared/tools/usd_decimate_recalc_normals.py` (from the repository root)

## What The Script Does

The script can:
- Import a USD stage.
- Optionally merge mesh objects (all, or only meshes with an identical material-slot list).
- Optionally apply voxel remesh (with thin-wall protection).
- Apply decimation (`COLLAPSE` or `DISSOLVE`).
- Optionally remove small disconnected mesh islands (floaters).
- Optionally recalculate normals.
- Export a new USD file.

It also includes quality guards:
- Skip remesh for multi-material meshes (to avoid losing face-material separation).
- Protect thin walls before remesh via `thin_wall_safety` (temporary Solidify).
- Skip decimate on ultra-low-face meshes to avoid noisy warnings.
- Restore the original mesh if processing did not actually reduce triangle count.

## Help Output

Show built-in help:

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- --help
```

## Command Shape

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- <input_usd> [output_usd] [ratio] [named overrides...]
```

Run from the repository root. Prefer named overrides for settings; this avoids
depending on the legacy positional option order:

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- "C:\Temp\Server_03.usdc" -thin_wall_safety=1.5 -remove_floaters=1
```

Named option format:
- `-name=value` or `--name=value`
- Dashes and underscores are both accepted in names.

### Parameters

Required:
- `input_usd`: Source `.usd/.usda/.usdc`.

Optional leading arguments:
- `output_usd`: Output USD path. If omitted, script auto-generates one in `%TEMP%`.
- `ratio` (default `0.35`): Decimate ratio for `COLLAPSE` mode.

Optional positional parameters:
- `merge_mode` (default `none`): `none` keeps objects separate, `all` joins every mesh into one, `material` joins only meshes with an identical material-slot list (same materials in the same slot order; objects with the same materials in a different slot order are not merged).
- `use_voxel_remesh` (default `0`): `1` enables voxel remesh.
- `voxel_size` (default `0.1`): Voxel remesh grid size. Larger = coarser = smaller output.
- `decimate_mode` (default `COLLAPSE`): `COLLAPSE` or `DISSOLVE`.
- `dissolve_angle_deg` (default `3.0`): Used by `DISSOLVE` mode.
- `recalc_after_process` (default `1`): `1` fixes face winding (make-normals-consistent) after processing, but **only on meshes without authored custom split normals**. Flipping the winding of a custom-normal mesh inverts its authored shading (measured on `Server_03`'s perforated bezel: 99.8% of faces flipped 180°), so custom-normal meshes are left untouched. It **no longer** clears authored custom split normals or sharp edges by default - doing so flattens intentional relief (e.g. an embossed logo reads flat at full res via custom normals, then "pops" as fake geometry once they're cleared). Use the two flags below to restore the old destructive behaviour.
- `clear_custom_normals` (default `0`): `1` clears authored custom split normals during recalc. Destructive; off by default. (Voxel remesh rebuilds the mesh, so custom normals are regenerated on remeshed objects regardless — `usd_auto_find_best.py --reapply-original-normals` transfers the original normals back onto the result.)
- `clear_sharp_edges` (default `0`): `1` clears authored sharp edges during recalc. Destructive; off by default.
- `reapply_original_normals` (default `0`): `1` transfers split normals from each object's **original** onto its reduced result via a Blender Data Transfer modifier (nearest-surface mapping). Restores authored/original shading even after **voxel remesh** (which rebuilds the mesh and otherwise loses it). Opt-in; adds a per-object transfer cost. Where the low-res geometry no longer carries the original relief, this reapplies the original *shading* (a vertex-normal approximation of the detail) rather than the geometry.
- `skip_multimaterial_remesh` (default `1`): `1` skips remesh on meshes with multiple materials.
- `min_faces_for_decimate` (default `4`): Meshes below this face count skip decimate.
- `remesh_disconnected_threshold` (default `1.0`): Threshold used by disconnected-piece removal in the voxel remesh. Set it to `0` or below to disable that removal.
- `thin_wall_safety` (default `0.0`): Thin-wall protection before voxel remesh. When greater than `0`, the script estimates wall thickness and applies a temporary Solidify modifier if the wall is thinner than `voxel_size * thin_wall_safety`. This replaces the old bbox-based remesh guards. See [Artefact Reference](#artefact-reference) for a description of what can happen without this guard.
- `remove_floaters` (default `0`): `1` deletes small disconnected mesh islands.
- `floater_min_face_ratio` (default `0.01`): An island is removed if its face count is below this fraction of the largest island's face count.
- `per_submesh_auto` (default `0`): `1` enables per-submesh adaptive strategy selection (see below).
- `per_submesh_scope` (default `damaged`): `damaged` re-searches submeshes the global pass moved too far (surface error over cap) **or** that are flat panels; `all` searches every submesh.
- `per_submesh_error_cap` (default `0.01`): Max allowed per-submesh geometric (surface-distance) error, as a fraction of the object's world-space bbox diagonal.
- `hole_loss_cap` (default `0.05`): Max fraction of an object's open-boundary length (hole rims / open borders) that a per-submesh variant may lose. Voxel remesh can seal perforations while barely moving the surface, so the distance gate cannot see the damage; this rejects those variants. `1.0` disables the guard.
- `hole_loss_min_ratio` (default `2.0`): Only enforce the hole guard when the object's open-boundary length is at least this multiple of its world-space bbox diagonal. A large panel with a few tiny open rims is not a perforated sheet; keeping it full-res just to preserve those rims costs a lot of size. The `Server_03` bezel (~278) and connector pins (~22) are guarded; flat panels (~0.03-1.3) are not.
- `auto_thin_wall` (default `1`): When a per-submesh remesh variant opens holes (high backward/missing-surface error), automatically re-try it with an escalating `thin_wall_safety` so thin panels survive voxelization — no manual `thin_wall_safety` needed.
- `auto_thin_wall_max` (default `2.0`): Ceiling for the automatic thin-wall escalation (multiple of the voxel size).
- `flat_planarity_threshold` (default `0.85`): Local coplanarity (area-weighted fraction of adjacent faces that stay coplanar) at/above which a mesh is treated as a **flat panel**. Flat panels are routed to voxel remesh (see below), because COLLAPSE/DISSOLVE crumple their shading. Lower = more meshes treated as flat.
- `untouched_name_whitelist` (default empty): Comma-separated object-name fragments. Any mesh whose name contains one of these fragments is skipped entirely.

Whitelist matching is substring-based, so `chassis` matches `chassis_sides.001`.

Mixing rules:
- You can mix positional and named options.
- If the same option is provided both ways, named value wins.

## Recommended Workflow

1. Start with:
   - `merge_mode=none`
   - `skip_multimaterial_remesh=1`
   - `recalc_after_process=1` (default; only repairs winding when safe)
2. With per-submesh auto enabled, automatic thin-wall escalation is on by default. For standalone remesh without per-submesh auto, set a fixed `thin_wall_safety` (e.g. `1.5`) if thin panels develop holes.
3. If loose fragments appear, enable `remove_floaters=1`.
4. Compare 2 to 3 runs and inspect:
   - Holes on thin panels.
   - Material-region preservation.
   - File size.

## Example Commands

Guarded remesh run with thin-wall protection:

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- "C:\Temp\Server_03.usdc" 0.35 -use_voxel_remesh=1 -voxel_size=0.22 -thin_wall_safety=1.5
```

Merge only same-material meshes, then collapse-decimate:

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- "C:\Temp\Server_03.usdc" 0.35 -merge_mode=material
```

Remove floater artifacts:

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- "C:\Temp\Server_03.usdc" 0.35 -remove_floaters=1 -floater_min_face_ratio=0.02
```

Whitelist example (keep outer hull untouched):

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- "C:\Temp\Server_03.usdc" -untouched_name_whitelist=server_hull,outer_shell
```

## Per-Submesh Adaptive Mode

A single global voxel size / ratio is often wrong for a heterogeneous model: chunky
panels survive while thin, detailed parts get broken by the same setting. Whole-scene
image scoring can't see this because a small broken feature is diluted across the frame.

`per_submesh_auto=1` fixes this by choosing the best strategy **per submesh**, driven by a
**flatness policy** that was validated by rendering, not by a fragile geometric shading score:

- **Flat panels** — local coplanarity ≥ `flat_planarity_threshold`. COLLAPSE *and* DISSOLVE
  both shatter a flat panel's smooth shading into a diamond/foil crumple (confirmed by
  rendering); only **voxel remesh** rebuilds clean flat topology. So flat panels are routed to
  remesh only, trying `voxel*1.8` / `voxel` / `voxel*0.7` (+ collapse) with automatic thin-wall
  escalation. The most-reduced variant whose surface error is under `per_submesh_error_cap`
  (and that actually reduces the face count) wins. If no remesh variant qualifies — or the panel
  is multi-material and remesh is skipped — the panel is left **untouched** (full-res but
  artefact-free) rather than crumpled by a collapse fallback.
- **Detailed / curved meshes** — collapse triangulation is hidden by the detail, so the usual
  remesh + collapse + gentle-collapse set is tried and gated on **surface distance** only.

Surface distance is a symmetric 95th-percentile point-to-surface distance (candidate→original
and original→candidate, so removed features / holes are caught), normalized by the bbox
diagonal. No rendering is involved in the per-submesh search, so it stays fast.

That distance gate is blind to **sealed perforations**: voxel remesh closes small holes while
almost every sampled point still lands on the (barely moved) plate. Every variant therefore also
reports `boundary_loss` - the fraction of the original open-boundary length it lost - and variants
above `hole_loss_cap` (default 5%) are rejected. The guard is only active when the original open
boundary is large relative to the object (`hole_loss_min_ratio`, default `2.0` x bbox diagonal),
so a big panel with a few tiny open rims is still free to remesh. A perforated panel whose remesh
candidates all seal its holes falls back to **untouched** instead of melting.

> Why policy and not a shading metric? The crumple is a smooth-shading effect over an irregular
> triangulation. Cheap geometric proxies (candidate-vs-original face normals, face coplanarity)
> either flag every reduction or miss it entirely — verified against renders. Detecting *flatness*
> is reliable; deciding *what to do* with a flat panel (remesh, else leave it) is not something
> that needs a per-variant shading score.

When `auto_thin_wall=1` (default), a remesh variant whose **backward** (missing-surface) error
signals holes is automatically re-tried with an escalating `thin_wall_safety` (up to
`auto_thin_wall_max`) until the holes close — so you no longer need to set `thin_wall_safety`
by hand for thin panels.

Notes:
- Multi-material objects skip the remesh strategies when `skip_multimaterial_remesh=1`
  (remesh would merge materials). A flat multi-material panel therefore has no clean reduction
  available and is left untouched — safe, but it will not shrink.
- A manual `thin_wall_safety > 0` takes precedence over auto escalation; `remove_floaters`
  applies to remesh variants as normal.
- `per_submesh_scope=damaged` (default) runs the global pass, then re-searches objects whose
  result exceeds the surface cap, lost boundary/hole length, **or** that are flat panels — so
  crumpled panels and sealed perforations are always caught. `per_submesh_scope=all` searches
  every object.
- A `<output>.psa.json` sidecar records the chosen strategy, planarity, surface/backward error,
  and any auto thin-wall value per object.

Example (let the tool auto-adapt per submesh — no manual thin-wall needed):

```powershell
"C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" -b --python "shared\tools\usd_decimate_recalc_normals.py" -- "C:\Temp\Server_03.usdc" 0.35 -use_voxel_remesh=1 -voxel_size=0.22 -per_submesh_auto=1 -per_submesh_scope=damaged -per_submesh_error_cap=0.01
```

## Artefact Reference

The following failure modes were observed in a real sweep of `Server_03.usdc` (a server chassis with large flat side panels and thin edge details). Screenshots are not bundled with this shared tool folder.

### Baseline (original)

The flat side panels are smooth and uniformly shaded. Keep this as the visual reference.

---

### Failure mode 1 — COLLAPSE decimate on flat panels (normals break)

**Parameters:** `use_voxel_remesh=0`, `decimate_mode=COLLAPSE`, `ratio=0.35`, `recalc_after_process=1`

**What you see:** The large flat panels are covered in a salt-and-pepper / crumpled-foil pattern — random black and white speckles from micro-triangles pointing in the wrong direction. `recalc_normals` cannot fix this because the triangulation itself is broken; COLLAPSE creates degenerate triangles that cancel each other's normals out.

**Fix (now automatic):** `per_submesh_auto=1` classifies this as a **flat panel** (high local coplanarity) and routes it to **voxel remesh** with automatic thin-wall protection, which rebuilds clean flat topology — verified by rendering (side-view RMSE dropped ~0.24 → ~0.085 on `Server_03`). COLLAPSE and DISSOLVE both crumple flat panels, so neither is used for them. If a flat panel is multi-material (remesh skipped) it is left untouched rather than crumpled. On by default in `usd_auto_find_best.py`.

---

### Failure mode 2 — Voxel remesh without `thin_wall_safety` (surface deformation / missing detail)

**Parameters:** `use_voxel_remesh=1`, `voxel_size=0.25`, `thin_wall_safety=0.0` (default)

**What you see:** The flat side panels look "hammered" — rounded dents and uneven shading — and thin features / small holes get eaten. Thin-wall meshes (panels whose wall thickness is smaller than `voxel_size`) get collapsed into the voxel grid, so the voxelizer merges the front and back face of the panel into a single voxel shell, which then doesn't reconstruct the flat surface correctly.

**Fix (now automatic):** With `per_submesh_auto=1` and `auto_thin_wall=1` (both default in `usd_auto_find_best.py`), a remesh variant that opens holes is detected via its backward (missing-surface) error and re-tried with an escalating `thin_wall_safety` until the holes close — no manual value required. To force a fixed value instead, set `thin_wall_safety` explicitly, which takes precedence:

```powershell
-use_voxel_remesh=1 -voxel_size=0.22 -thin_wall_safety=1.1
```

---

## Auto-Find Best (Multi-Run Search)

There is a helper script that runs multiple candidates and picks the best result
by size, visual similarity, or value (bang-for-byte). It can also generate LOD sets:
- `shared/tools/usd_auto_find_best.py` (see `shared/tools/usd_auto_find_best.md`).

Behavior notes:
- Aggressive candidates are **off by default** (safer for thin parts). Use `--include-aggressive` to enable.
- Each candidate run has a timeout (`--per-run-timeout-sec`, default 420s).
- Outputs are written into a timestamped run folder:
  - `%TEMP%/<input_stem>_YYYYMMDD_HHMMSS/`
- Optional preview PNGs can be rendered per candidate (`_x/_y/_z/_oblique/_oblique_bottom`).
- All candidate outputs are kept by default. Use `--delete-non-best` for automatic cleanup.

Example (target 30 MB, with previews + HTML report):

```powershell
python shared\tools\usd_auto_find_best.py --blender "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" --process-script shared\tools\usd_decimate_recalc_normals.py --input "C:\Temp\Server_03.usdc" --target-size-mb 30 --max-runs 10 --render-previews
```
