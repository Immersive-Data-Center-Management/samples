# usd_auto_find_best.py

Auto-search wrapper for `usd_decimate_recalc_normals.py`.

It runs multiple candidate parameter sets, optionally renders preview images, scores them against baseline previews from the original mesh, and picks the best result. It can also generate a multi-level LOD set from a single sweep.

## Quick example

```powershell
python shared\tools\usd_auto_find_best.py `
  --blender "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe" `
  --process-script shared\tools\usd_decimate_recalc_normals.py `
  --input C:\Temp\Server_03.usdc `
  --target-size-mb 30 `
  --max-runs 30 `
  --render-previews `
  --preview-size 320 `
  --best-mode value `
  --remesh-policy allow `
  --untouched-whitelist "server_hull,outer_shell"
```

## Selection behavior (`--best-mode`)

- `size`: closest to target size.
- `visual_under_target` (default): lowest visual score among candidates under target size.
- `visual_any`: lowest visual score regardless of size.
- `value`: best "P/L" (price/performance) — lowest `size_bytes * visual_score` (both lower-is-better), preferring candidates under target. This rewards small files that also stay visually close to the original.

Visual score is lower-is-better and uses foreground-only pixel comparison by default.
Background-only pixels are ignored by design.
The default score is the weighted RGB/normal/silhouette blend described below; it is not
directly comparable to scores from older RGB-only versions.

### Multi-signal visual score (`--score-passes`)

Plain RGB RMSE mixes geometry with studio lighting/material colour and dilutes small but
important defects. The score is therefore a **weighted blend of up to three render passes**
(default `rgb,normal,silhouette`, weights `0.25 / 0.40 / 0.35` — normal and silhouette matter
most for hard-surface assets):

| Pass | Detects | How |
|---|---|---|
| `rgb` | general appearance | studio-lit material render, foreground-masked RMSE |
| `normal` | shading / normal breakage (the flat-panel crumple) | matcap (view-space normal) render, foreground-masked RMSE |
| `silhouette` | holes, missing parts, outline drift | flat render on transparent bg → alpha-mask **IoU** (scored as `1 − IoU`) |

All passes render inside the **single** USD import per candidate, so extra passes cost only
re-renders, not another load. Each candidate's `_score.json` stores the combined `score_value`,
the per-pass `score_components`, the `score_weights`, and `per_view_by_pass` details; `mean_rmse`
(the RGB component) is kept for backward compatibility. The HTML report shows the combined score
with the per-pass breakdown beneath it. Pass `--score-passes rgb` to restore the old RGB-only
behaviour, or e.g. `--score-passes rgb,silhouette` to drop the matcap pass.

## LOD generation (`--lod-levels N`)

With `--lod-levels 3` and a 50 MB target, the script produces three LOD outputs at
roughly 50 MB, 25 MB, and 12.5 MB (`target / 2^i`). It runs the candidate sweep once
and, for each LOD target, selects the best candidate for that target using the active
`--best-mode`. Chosen files are copied into the run folder as `lod0_*.usdc`,
`lod1_*.usdc`, etc. (with their preview PNGs).

With `--lod-levels > 1`, the candidate list includes an aggressive tail (coarser voxel
sizes + lower ratios). Because the list is capped by `--max-runs`, increase that limit
when you want to ensure the aggressive tail is included. If no candidate can reach a
small LOD target, the closest available candidate is used and a warning is printed.

## Remesh policy

- `--remesh-policy allow`: mixed candidate set (no-remesh + remesh).
- `--remesh-policy force`: remesh-only candidates.
- `--remesh-policy skip`: no-remesh-only candidates.

Additional controls forwarded to the process script:
- `--merge-mode {none,all,material}`: forward `merge_mode` (default `none`). `material` merges only meshes with an identical material-slot list (same materials in the same slot order).
- `--remove-floaters` + `--floater-min-face-ratio`: delete small disconnected islands.
- **`--per-submesh-auto` (ON by default) / `--no-per-submesh-auto`**: pick the best reduction strategy per submesh (see the process-script guide's "Per-Submesh Adaptive Mode"). Flat panels are routed to voxel remesh (COLLAPSE/DISSOLVE crumple them); detailed meshes are gated on surface distance. This is what prevents the crumpled-panel and hole artefacts. In `--per-submesh-scope damaged` (default) the cheap global pass runs first and only over-cap or flat-panel objects are re-searched, so cost across a sweep stays bounded. Use `--per-submesh-scope all` to search every object.
- `--per-submesh-error-cap` (default `0.01`): max per-submesh surface distance, as a fraction of the object bbox diagonal.
- `--hole-loss-cap` (default `0.05`): max fraction of significant open-boundary length a strategy may lose; `1` disables the guard.
- `--hole-loss-min-ratio` (default `2.0`): apply the hole-loss guard only when original boundary length is at least this multiple of the object's bbox diagonal.
- **`--auto-thin-wall` (ON by default) / `--no-auto-thin-wall`** + `--auto-thin-wall-max` (default `2.0`): auto-escalate `thin_wall_safety` on remesh variants that open holes, so thin panels survive voxelization without a manual value.
- `--flat-planarity-threshold` (default `0.85`): area-weighted fraction of locally coplanar adjacent faces at/above which a mesh is treated as a flat panel and routed to remesh. Lower = more meshes treated as flat.
- `--remesh-disconnected-threshold`: threshold used for REMESH disconnected-piece removal; `<= 0` disables it.
- `--thin-wall-safety`: a fixed thin-wall value before voxel remesh; `0` = rely on `--auto-thin-wall`. A non-zero value takes precedence over auto escalation.
- `--clear-custom-normals` / `--clear-sharp-edges`: **off by default.** Recalc now only fixes face winding and preserves authored custom split normals / sharp edges (clearing them flattens intentional relief such as an embossed logo). Pass these to restore the old destructive behaviour.
- `--reapply-original-normals`: **off by default.** After reduction, transfer split normals from each object's original onto its result (Data Transfer, nearest-surface). Restores authored shading even after voxel remesh; adds a per-object transfer cost.
- `--untouched-whitelist`: comma-separated object-name fragments to skip entirely (kept pristine — the surest way to protect a hero detail like a logo plate).

Whitelist matching is substring-based, so `chassis` matches `chassis_sides.001`.

The wrapper passes all options to the process script as named `--name=value` overrides,
so it does not depend on the process script's positional argument order.

## Normals recalculation

Candidates toggle `recalc_after_process` internally:
- no-remesh candidates: recalc enabled
- remesh candidates: recalc disabled

This behavior is reflected in console output and score JSON files.

## HTML report

A `results.html` report is written by default (disable with `--no-html-report`). It contains:
- A candidate table with size, under-target flag, visual score, value (P/L), and a **psa** column summarizing per-submesh activity (objects reprocessed, flat panels routed to remesh, thin-wall-guarded, left untouched).
- Visual-score cells graded green (best) → red (worst).
- Best-by-size / visual-under / visual-any / value rows highlighted with a colored left border.
- A LOD-levels table when `--lod-levels > 1`.
- Baseline and per-candidate preview thumbnails when `--render-previews` is used.

## Outputs

Per run, outputs are written into one timestamped folder.

- Candidate USD files (`auto_*.usdc`)
- LOD copies (`lod0_*.usdc`, `lod1_*.usdc`, ...) when `--lod-levels > 1`
- Preview PNGs (`_x`, `_y`, `_z`, `_oblique`, `_oblique_bottom`), plus `_normal` and `_silhouette` variants per view when those score passes are enabled
- Score JSON per candidate (`_score.json`) with candidate parameters, the combined score + per-pass `score_components`/`score_weights`, and a folded-in `per_submesh` block (counters + strategy counts)
- Per-submesh diagnostics sidecar (`.psa.json`) per candidate when `--per-submesh-auto` is active
- Baseline preview PNGs from original mesh (`baseline_original_*`)
- HTML report (`results.html`) unless `--no-html-report` is passed

## Console output

Each candidate prints a colored header with human-readable parameters, then one compact
result line, e.g.:

```
[3/17]  ratio 0.55  ·  no remesh  ·  DISSOLVE  ·  angle 2.0°  ·  recalc yes
  → 142.15 MB   target OVER   score 0.0529 [rgb=0.081 nor=0.041 sil=0.006]   proc 46.2s · preview 8.1s
    auto_03_r55_...usdc
```

- **Timings**: each candidate shows `proc` (Blender processing) vs `preview` (render+score)
  seconds, and the sweep ends with a total + per-candidate average. The process script
  also prints a phase breakdown per run — `Timings: import Xs · process Ys · export Zs` —
  so you can see whether time goes to geometry work or USD I/O.
- `--verbose` adds the preview file paths (suppressed by default to cut noise).
- `--no-color` disables ANSI colour (also auto-disabled when output is not a terminal).

## Notes

- If `--delete-non-best` is used, non-best USD outputs and companion preview/score files are removed. Files chosen for any LOD level are kept.
- The script expects Blender to be callable with the provided executable path.
- The Summary console block lists each candidate's output filename alongside its size, visual score, and value.
