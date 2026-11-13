import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from dataclasses import dataclass
from typing import List, Optional, Tuple
from html import escape


# --- console formatting -----------------------------------------------------
_USE_COLOR = False  # set in main() from --no-color and tty detection

_ANSI = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "cyan": "\033[36m", "green": "\033[32m", "yellow": "\033[33m",
    "red": "\033[31m", "grey": "\033[90m",
}


def color(text: str, *codes: str) -> str:
    if not _USE_COLOR or not codes:
        return text
    prefix = "".join(_ANSI.get(c, "") for c in codes)
    return f"{prefix}{text}{_ANSI['reset']}"


def fmt_secs(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    if seconds < 60:
        return f"{seconds:.1f}s"
    m, s = divmod(int(round(seconds)), 60)
    return f"{m}m{s:02d}s"


def describe_candidate(cand: "Candidate") -> str:
    """Human-readable one-liner of the candidate parameters."""
    parts = [f"ratio {cand.ratio}"]
    if cand.use_voxel_remesh:
        parts.append(f"remesh voxel {cand.voxel_size}")
    else:
        parts.append("no remesh")
    parts.append(cand.decimate_mode)
    if cand.decimate_mode == "DISSOLVE":
        parts.append(f"angle {cand.dissolve_angle_deg}°")
    parts.append(f"recalc {'yes' if cand.recalc_after_process else 'no'}")
    return "  ·  ".join(parts)


@dataclass
class Candidate:
    ratio: float
    use_voxel_remesh: bool
    voxel_size: float
    decimate_mode: str
    dissolve_angle_deg: float
    recalc_after_process: bool
    skip_multimaterial_remesh: bool


@dataclass
class Result:
    candidate: Candidate
    output_path: str
    output_size: int
    ok: bool
    error: Optional[str] = None
    visual_score: Optional[float] = None
    score_path: Optional[str] = None
    psa_summary: Optional[str] = None
    score_components: Optional[str] = None


def fmt_size(num_bytes: int) -> str:
    return f"{num_bytes / (1024 * 1024):.2f} MB"


def value_metric(r: "Result") -> Optional[float]:
    # Bang-for-byte: smaller file AND smaller visual deviation both lower this.
    # Lower is better. score is floored to a small epsilon to avoid a perfect
    # (0.0) match collapsing the product regardless of size.
    if r.visual_score is None:
        return None
    return r.output_size * max(r.visual_score, 1e-4)


def build_output_path(input_usd: str, cand: Candidate, idx: int, out_dir: str) -> str:
    tag = (
        f"auto_{idx:02d}_r{int(cand.ratio * 100)}"
        f"_remesh{1 if cand.use_voxel_remesh else 0}"
        f"_vox{str(cand.voxel_size).replace('.', 'p')}"
        f"_mode{cand.decimate_mode.lower()}"
        f"_ang{str(cand.dissolve_angle_deg).replace('.', 'p')}"
        f"_recalc{1 if cand.recalc_after_process else 0}"
        f"_skipmm{1 if cand.skip_multimaterial_remesh else 0}"
    )
    return os.path.join(out_dir, f"{tag}.usdc")


def build_run_dir(input_usd: str, out_root: str) -> str:
    stem = os.path.splitext(os.path.basename(input_usd))[0]
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(out_root, f"{stem}_{stamp}")
    os.makedirs(run_dir, exist_ok=True)
    return run_dir


def run_candidate(
    blender_exe: str,
    process_script: str,
    input_usd: str,
    output_usd: str,
    cand: Candidate,
    timeout_sec: int,
    merge_mode: str,
    remesh_disconnected_threshold: float,
    thin_wall_safety: float,
    remove_floaters: bool,
    floater_min_face_ratio: float,
    per_submesh_auto: bool,
    per_submesh_scope: str,
    per_submesh_error_cap: float,
    hole_loss_cap: float,
    hole_loss_min_ratio: float,
    auto_thin_wall: bool,
    auto_thin_wall_max: float,
    flat_planarity_threshold: float,
    clear_custom_normals: bool,
    clear_sharp_edges: bool,
    reapply_original_normals: bool,
    untouched_name_whitelist: str,
) -> Result:
    # All options are passed as named overrides (--name=value) so this wrapper is
    # independent of the process script's positional argument order.
    cmd = [
        blender_exe,
        "-b",
        "--python",
        process_script,
        "--",
        input_usd,
        output_usd,
        str(cand.ratio),
        f"--merge_mode={merge_mode}",
        f"--use_voxel_remesh={1 if cand.use_voxel_remesh else 0}",
        f"--voxel_size={cand.voxel_size}",
        f"--decimate_mode={str(cand.decimate_mode).upper()}",
        f"--dissolve_angle_deg={cand.dissolve_angle_deg}",
        f"--recalc_after_process={1 if cand.recalc_after_process else 0}",
        f"--clear_custom_normals={1 if clear_custom_normals else 0}",
        f"--clear_sharp_edges={1 if clear_sharp_edges else 0}",
        f"--reapply_original_normals={1 if reapply_original_normals else 0}",
        f"--skip_multimaterial_remesh={1 if cand.skip_multimaterial_remesh else 0}",
        "--min_faces_for_decimate=4",
        f"--remesh_disconnected_threshold={float(remesh_disconnected_threshold)}",
        f"--thin_wall_safety={float(thin_wall_safety)}",
        f"--remove_floaters={1 if remove_floaters else 0}",
        f"--floater_min_face_ratio={float(floater_min_face_ratio)}",
        f"--per_submesh_auto={1 if per_submesh_auto else 0}",
        f"--per_submesh_scope={per_submesh_scope}",
        f"--per_submesh_error_cap={float(per_submesh_error_cap)}",
        f"--hole_loss_cap={float(hole_loss_cap)}",
        f"--hole_loss_min_ratio={float(hole_loss_min_ratio)}",
        f"--auto_thin_wall={1 if auto_thin_wall else 0}",
        f"--auto_thin_wall_max={float(auto_thin_wall_max)}",
        f"--flat_planarity_threshold={float(flat_planarity_threshold)}",
    ]
    if untouched_name_whitelist.strip():
        cmd.append(f"--untouched_name_whitelist={untouched_name_whitelist}")

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        return Result(
            cand,
            output_usd,
            0,
            False,
            error=f"Timed out after {timeout_sec}s",
        )
    except Exception as ex:
        return Result(cand, output_usd, 0, False, error=str(ex))

    if proc.returncode != 0:
        err = (proc.stderr or "") + "\n" + (proc.stdout or "")
        return Result(cand, output_usd, 0, False, error=err[-4000:])

    if not os.path.exists(output_usd):
        return Result(cand, output_usd, 0, False, error="Output file missing")

    size = os.path.getsize(output_usd)
    return Result(cand, output_usd, size, True)


def candidate_key(c: Candidate):
    return (
        c.ratio,
        c.use_voxel_remesh,
        c.voxel_size,
        c.decimate_mode,
        c.dissolve_angle_deg,
        c.recalc_after_process,
        c.skip_multimaterial_remesh,
    )


def build_candidates(include_aggressive: bool) -> List[Candidate]:
    return build_candidates_with_policy(include_aggressive, remesh_policy="allow")


def build_candidates_with_policy(
    include_aggressive: bool,
    remesh_policy: str,
    aggressive_tail: bool = False,
) -> List[Candidate]:
    # Build a diverse ordered candidate list so early runs cover meaningfully different strategies.
    # Strategy A: No remesh, collapse decimate (best chance to preserve hull silhouette).
    if include_aggressive:
        collapse_ratios = [0.30, 0.35, 0.40, 0.45, 0.50]
    else:
        collapse_ratios = [0.35, 0.40, 0.45, 0.50, 0.55]

    cands: List[Candidate] = []
    for r in collapse_ratios:
        cands.append(
            Candidate(
                ratio=r,
                use_voxel_remesh=False,
                voxel_size=0.22,
                decimate_mode="COLLAPSE",
                dissolve_angle_deg=3.0,
                recalc_after_process=True,
                skip_multimaterial_remesh=True,
            )
        )

    # Strategy B: No remesh, dissolve for planar simplification with boundary protection.
    dissolve_angles = [1.0, 2.0, 3.0, 5.0] if include_aggressive else [1.0, 2.0, 3.0]
    for ang in dissolve_angles:
        cands.append(
            Candidate(
                ratio=0.55,
                use_voxel_remesh=False,
                voxel_size=0.22,
                decimate_mode="DISSOLVE",
                dissolve_angle_deg=ang,
                recalc_after_process=True,
                skip_multimaterial_remesh=True,
            )
        )

    # Strategy C: Remesh path (ratios x voxel sizes) with multi-material protection.
    remesh_ratios = [0.30, 0.35, 0.40] if include_aggressive else [0.35, 0.40, 0.45]
    remesh_voxels = [0.28, 0.25, 0.22, 0.20] if include_aggressive else [0.25, 0.22, 0.20]
    for r in remesh_ratios:
        for v in remesh_voxels:
            cands.append(
                Candidate(
                    ratio=r,
                    use_voxel_remesh=True,
                    voxel_size=v,
                    decimate_mode="COLLAPSE",
                    dissolve_angle_deg=3.0,
                    recalc_after_process=False,
                    skip_multimaterial_remesh=True,
                )
            )

    # Aggressive tail for multi-LOD runs: coarser voxels + lower ratios drive
    # much smaller file sizes so small LOD targets are reachable.
    if aggressive_tail:
        for r in [0.20, 0.25]:
            for v in [0.32, 0.40]:
                cands.append(
                    Candidate(
                        ratio=r,
                        use_voxel_remesh=True,
                        voxel_size=v,
                        decimate_mode="COLLAPSE",
                        dissolve_angle_deg=3.0,
                        recalc_after_process=False,
                        skip_multimaterial_remesh=True,
                    )
                )
        for r in [0.15, 0.20]:
            cands.append(
                Candidate(
                    ratio=r,
                    use_voxel_remesh=False,
                    voxel_size=0.22,
                    decimate_mode="COLLAPSE",
                    dissolve_angle_deg=3.0,
                    recalc_after_process=True,
                    skip_multimaterial_remesh=True,
                )
            )

    rp = str(remesh_policy).lower().strip()
    if rp == "force":
        cands = [c for c in cands if c.use_voxel_remesh]
    elif rp == "skip":
        cands = [c for c in cands if not c.use_voxel_remesh]

    # De-duplicate while preserving order.
    deduped: List[Candidate] = []
    seen = set()
    for c in cands:
        key = candidate_key(c)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(c)

    return deduped


def render_previews(
    blender_exe: str,
    preview_script: str,
    input_usd: str,
    output_usd: str,
    preview_prefix: str,
    size: int,
    timeout_sec: int,
    camera_center: Optional[Tuple[float, float, float]] = None,
    camera_dist: Optional[float] = None,
    compare_to_prefix: Optional[str] = None,
    score_out: Optional[str] = None,
    meta_out: Optional[str] = None,
    score_passes: str = "rgb",
) -> Optional[str]:
    cmd = [
        blender_exe,
        "-b",
        "--python",
        preview_script,
        "--",
        input_usd,
        output_usd,
        preview_prefix,
        "--size",
        str(size),
    ]
    if camera_center is not None:
        cmd.append(
            "--camera-center="
            f"{camera_center[0]},{camera_center[1]},{camera_center[2]}"
        )
    if camera_dist is not None:
        cmd.append(f"--camera-dist={camera_dist}")
    if compare_to_prefix:
        cmd.extend(["--compare-to-prefix", compare_to_prefix])
    if score_out:
        cmd.extend(["--score-out", score_out])
    if meta_out:
        cmd.extend(["--meta-out", meta_out])
    cmd.extend(["--score-mask-mode", "foreground"])
    cmd.extend(["--score-passes", score_passes])
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        return f"Preview timed out after {timeout_sec}s"
    except Exception as ex:
        return str(ex)

    if proc.returncode != 0:
        err = (proc.stderr or "") + "\n" + (proc.stdout or "")
        return err[-2000:]
    return None


def pick_best_by_size(results: List[Result], target_bytes: int) -> Optional[Result]:
    ok = [r for r in results if r.ok]
    if not ok:
        return None

    under = [r for r in ok if r.output_size <= target_bytes]
    if under:
        # Best under target: closest from below.
        return min(under, key=lambda r: target_bytes - r.output_size)

    # Otherwise closest above target.
    return min(ok, key=lambda r: r.output_size - target_bytes)


def pick_best_by_visual(results: List[Result], target_bytes: int, under_target_only: bool) -> Optional[Result]:
    ok = [r for r in results if r.ok and r.visual_score is not None]
    if not ok:
        return None

    if under_target_only:
        under = [r for r in ok if r.output_size <= target_bytes]
        if under:
            return min(under, key=lambda r: r.visual_score)
        return None
    return min(ok, key=lambda r: r.visual_score)


def pick_best_by_value(
    results: List[Result],
    target_bytes: Optional[int] = None,
    under_target_only: bool = False,
) -> Optional[Result]:
    ok = [r for r in results if r.ok and value_metric(r) is not None]
    if not ok:
        return None
    if under_target_only and target_bytes is not None:
        under = [r for r in ok if r.output_size <= target_bytes]
        if under:
            return min(under, key=value_metric)
        return None
    return min(ok, key=value_metric)


def select_for_target(
    results: List[Result], target_bytes: int, best_mode: str
) -> Optional[Result]:
    if best_mode == "size":
        return pick_best_by_size(results, target_bytes)
    if best_mode == "visual_any":
        return pick_best_by_visual(results, target_bytes, under_target_only=False) or pick_best_by_size(
            results, target_bytes
        )
    if best_mode == "value":
        return (
            pick_best_by_value(results, target_bytes, under_target_only=True)
            or pick_best_by_value(results)
            or pick_best_by_size(results, target_bytes)
        )
    # visual_under_target (default)
    return (
        pick_best_by_visual(results, target_bytes, under_target_only=True)
        or pick_best_by_visual(results, target_bytes, under_target_only=False)
        or pick_best_by_size(results, target_bytes)
    )


def score_cell_style(
    visual_score: Optional[float], score_min: Optional[float], score_max: Optional[float]
) -> str:
    # Grade green (best/lowest) -> red (worst/highest) for the visual-score cell.
    if visual_score is None or score_min is None or score_max is None:
        return ""
    if score_max <= score_min:
        t = 0.0
    else:
        t = (visual_score - score_min) / (score_max - score_min)
        t = max(0.0, min(1.0, t))
    hue = int(round(120.0 * (1.0 - t)))  # 120=green .. 0=red
    return f" style='background: hsl({hue}, 55%, 28%);'"


def copy_lod_outputs(chosen: Result, lod_index: int, out_dir: str) -> str:
    base = os.path.basename(chosen.output_path)
    dst = os.path.join(out_dir, f"lod{lod_index}_{base}")
    shutil.copy2(chosen.output_path, dst)

    src_prefix = os.path.splitext(chosen.output_path)[0]
    dst_prefix = os.path.splitext(dst)[0]
    for suf in ["_x.png", "_y.png", "_z.png", "_oblique.png", "_oblique_bottom.png"]:
        sp = src_prefix + suf
        if os.path.exists(sp):
            try:
                shutil.copy2(sp, dst_prefix + suf)
            except Exception:
                pass
    return dst


def generate_results_html(
    out_dir: str,
    input_usd: str,
    target_bytes: int,
    best_mode: str,
    results: List[Result],
    baseline_prefix: Optional[str],
    lod_rows: Optional[List[dict]] = None,
) -> str:
    html_path = os.path.join(out_dir, "results.html")

    def rel(p: Optional[str]) -> str:
        if not p:
            return ""
        try:
            return os.path.relpath(p, out_dir).replace("\\", "/")
        except Exception:
            return p.replace("\\", "/")

    best_size = pick_best_by_size(results, target_bytes)
    best_visual_under = pick_best_by_visual(results, target_bytes, under_target_only=True)
    best_visual_any = pick_best_by_visual(results, target_bytes, under_target_only=False)
    best_value = pick_best_by_value(results, target_bytes, under_target_only=True) or pick_best_by_value(results)

    scored = [r.visual_score for r in results if r.ok and r.visual_score is not None]
    score_min = min(scored) if scored else None
    score_max = max(scored) if scored else None

    rows = []
    for idx, r in enumerate(results, start=1):
        if not r.ok:
            rows.append(
                f"<tr><td>{idx}</td><td>{escape(os.path.basename(r.output_path))}</td>"
                f"<td colspan='17'><b>FAILED</b>: {escape(r.error or 'unknown error')}</td></tr>"
            )
            continue

        prefix = os.path.splitext(r.output_path)[0]
        imgs = {
            "x": rel(prefix + "_x.png"),
            "y": rel(prefix + "_y.png"),
            "z": rel(prefix + "_z.png"),
            "oblique": rel(prefix + "_oblique.png"),
            "oblique_bottom": rel(prefix + "_oblique_bottom.png"),
        }

        def img_cell(src: str) -> str:
            if src and os.path.exists(os.path.join(out_dir, src)):
                return f"<a href='{escape(src)}'><img src='{escape(src)}' loading='lazy' /></a>"
            return "-"

        under = "yes" if r.output_size <= target_bytes else "no"
        style = ""
        if best_value is not None and r.output_path == best_value.output_path:
            style = " class='best-value'"
        elif best_visual_under is not None and r.output_path == best_visual_under.output_path:
            style = " class='best-visual-under'"
        elif best_visual_any is not None and r.output_path == best_visual_any.output_path:
            style = " class='best-visual-any'"
        elif best_size is not None and r.output_path == best_size.output_path:
            style = " class='best-size'"

        score_txt = f"{r.visual_score:.6f}" if r.visual_score is not None else "-"
        if r.score_components:
            score_txt += f"<br/><span style='font-size:10px;color:#9fb0c8'>{escape(r.score_components)}</span>"
        vm = value_metric(r)
        value_txt = f"{vm:.3e}" if vm is not None else "-"
        score_style = score_cell_style(r.visual_score, score_min, score_max)
        rows.append(
            "<tr" + style + ">"
            f"<td>{idx}</td>"
            f"<td>{escape(os.path.basename(r.output_path))}</td>"
            f"<td>{fmt_size(r.output_size)}</td>"
            f"<td>{under}</td>"
            f"<td{score_style}>{score_txt}</td>"
            f"<td>{value_txt}</td>"
            f"<td>{escape(r.psa_summary or '-')}</td>"
            f"<td>{r.candidate.ratio}</td>"
            f"<td>{'yes' if r.candidate.use_voxel_remesh else 'no'}</td>"
            f"<td>{r.candidate.voxel_size}</td>"
            f"<td>{escape(r.candidate.decimate_mode)}</td>"
            f"<td>{r.candidate.dissolve_angle_deg}</td>"
            f"<td>{'yes' if r.candidate.recalc_after_process else 'no'}</td>"
            f"<td>{'yes' if r.candidate.skip_multimaterial_remesh else 'no'}</td>"
            f"<td>{img_cell(imgs['x'])}</td>"
            f"<td>{img_cell(imgs['y'])}</td>"
            f"<td>{img_cell(imgs['z'])}</td>"
            f"<td>{img_cell(imgs['oblique'])}</td>"
            f"<td>{img_cell(imgs['oblique_bottom'])}</td>"
            "</tr>"
        )

    lod_block = ""
    if lod_rows:
        lod_tr = []
        for lr in lod_rows:
            lod_tr.append(
                "<tr>"
                f"<td>lod{lr['index']}</td>"
                f"<td>{fmt_size(lr['target_bytes'])}</td>"
                f"<td>{escape(lr.get('output_name', '-'))}</td>"
                f"<td>{fmt_size(lr['output_size']) if lr.get('output_size') else '-'}</td>"
                f"<td>{('%.6f' % lr['visual_score']) if lr.get('visual_score') is not None else '-'}</td>"
                f"<td>{'yes' if lr.get('under_target') else 'no'}</td>"
                "</tr>"
            )
        lod_block = (
            "<h2>LOD levels</h2>"
            "<table><thead><tr>"
            "<th>lod</th><th>target</th><th>file</th><th>size</th><th>visual score</th><th>under target</th>"
            "</tr></thead><tbody>" + "".join(lod_tr) + "</tbody></table>"
        )

    baseline_block = ""
    if baseline_prefix:
        b = {
            "x": rel(baseline_prefix + "_x.png"),
            "y": rel(baseline_prefix + "_y.png"),
            "z": rel(baseline_prefix + "_z.png"),
            "oblique": rel(baseline_prefix + "_oblique.png"),
            "oblique_bottom": rel(baseline_prefix + "_oblique_bottom.png"),
        }
        baseline_block = (
            "<h2>Baseline</h2>"
            "<div class='baseline'>"
            + "".join(
                f"<a href='{escape(src)}'><figure><img src='{escape(src)}' loading='lazy'/><figcaption>{name}</figcaption></figure></a>"
                for name, src in b.items()
                if src and os.path.exists(os.path.join(out_dir, src))
            )
            + "</div>"
        )

    html = f"""<!doctype html>
<html lang='en'>
<head>
  <meta charset='utf-8' />
  <meta name='viewport' content='width=device-width, initial-scale=1' />
  <title>USD Auto Find Best Results</title>
  <style>
    body {{ font-family: Segoe UI, Arial, sans-serif; margin: 16px; background: #0f1115; color: #e7ebf3; }}
    a {{ color: #9dc1ff; }}
    h1, h2 {{ margin: 8px 0 12px; }}
    .meta {{ margin-bottom: 12px; color: #c6cfdd; }}
    .legend span {{ display: inline-block; padding: 4px 8px; margin-right: 8px; border-radius: 6px; }}
    .best-size {{ box-shadow: inset 4px 0 0 #4f8bff; }}
    .best-visual-under {{ box-shadow: inset 4px 0 0 #3ad07a; }}
    .best-visual-any {{ box-shadow: inset 4px 0 0 #d08a3a; }}
    .best-value {{ box-shadow: inset 4px 0 0 #d84fff; }}
    table {{ border-collapse: collapse; width: 100%; font-size: 12px; margin-bottom: 16px; }}
    th, td {{ border: 1px solid #2a3040; padding: 6px; vertical-align: top; }}
    th {{ position: sticky; top: 0; background: #131a29; }}
    td img {{ width: 170px; height: 170px; object-fit: contain; background: #090b10; border: 1px solid #293041; }}
    .baseline {{ display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; }}
    figure {{ margin: 0; }}
    figcaption {{ text-align: center; margin-top: 4px; color: #c6cfdd; font-size: 12px; }}
  </style>
</head>
<body>
  <h1>USD Auto Find Best Results</h1>
  <div class='meta'>
    input: {escape(input_usd)}<br/>
    target: {fmt_size(target_bytes)} ({target_bytes} bytes)<br/>
    best mode: {escape(best_mode)}<br/>
    rows: {len(results)}
  </div>
  <div class='legend'>
    <span class='best-size'>best by size</span>
    <span class='best-visual-under'>best visual under target</span>
    <span class='best-visual-any'>best visual any size</span>
    <span class='best-value'>best value (P/L)</span>
  </div>
  <div class='meta'>Visual-score cells are graded green (best) &rarr; red (worst).</div>
  {baseline_block}
  {lod_block}
  <h2>Candidates</h2>
  <table>
    <thead>
      <tr>
        <th>#</th><th>file</th><th>size</th><th>under target</th><th>visual score</th><th>value (size&times;score)</th>
        <th>psa</th><th>ratio</th><th>remesh</th><th>voxel</th><th>mode</th><th>angle</th>
        <th>recalc</th><th>skip multimat</th>
        <th>x</th><th>y</th><th>z</th><th>oblique</th><th>oblique_bottom</th>
      </tr>
    </thead>
    <tbody>
      {''.join(rows)}
    </tbody>
  </table>
</body>
</html>
"""

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)
    return html_path


def main() -> int:
    ap = argparse.ArgumentParser(description="Auto-search settings for usd_decimate_recalc_normals.py")
    ap.add_argument("--blender", required=True, help="Path to blender.exe")
    ap.add_argument("--process-script", required=True, help="Path to usd_decimate_recalc_normals.py")
    ap.add_argument("--input", required=True, help="Input USD path")
    ap.add_argument("--target-factor", type=float, default=None, help="Target size factor vs input (e.g. 0.5)")
    ap.add_argument("--target-size-mb", type=float, default=None, help="Target absolute size in MB")
    ap.add_argument("--max-runs", type=int, default=12, help="Max candidate runs")
    ap.add_argument("--out-dir", default=None, help="Output directory for candidate USD files")
    ap.add_argument("--delete-non-best", action="store_true", help="Delete non-best candidate outputs (default keeps all)")
    ap.add_argument("--include-aggressive", action="store_true", help="Include more aggressive candidates (may remove thin parts)")
    ap.add_argument("--per-run-timeout-sec", type=int, default=420, help="Timeout per Blender candidate run")
    ap.add_argument("--render-previews", action="store_true", help="Render X/Y/Z preview PNGs for each successful candidate")
    ap.add_argument("--preview-script", default=None, help="Path to preview renderer script")
    ap.add_argument("--preview-size", type=int, default=512, help="Preview resolution (square)")
    ap.add_argument(
        "--score-passes",
        default="rgb,normal,silhouette",
        help="Comma list of render passes used for the visual score: rgb (studio-lit "
        "material RMSE), normal (matcap / view-space-normal RMSE, catches shading "
        "crumple), silhouette (alpha-mask IoU, catches holes / missing parts). The "
        "combined score weights normal and silhouette above rgb. Default uses all three.",
    )
    ap.add_argument("--preview-timeout-sec", type=int, default=180, help="Timeout per preview render batch")
    ap.add_argument(
        "--merge-mode",
        choices=["none", "all", "material"],
        default="none",
        help="Forward merge_mode to candidates: none, join all, or join same-material only",
    )
    ap.add_argument(
        "--remove-floaters",
        action="store_true",
        help="Forward remove_floaters=1 to candidates (delete small disconnected islands)",
    )
    ap.add_argument(
        "--floater-min-face-ratio",
        type=float,
        default=0.01,
        help="Islands below this fraction of the largest island's face count are removed",
    )
    ap.add_argument(
        "--clear-custom-normals",
        action="store_true",
        help="Clear authored custom split normals during recalc (DESTRUCTIVE — off by "
        "default; can flatten embossed relief such as a logo). Restores old behaviour.",
    )
    ap.add_argument(
        "--clear-sharp-edges",
        action="store_true",
        help="Clear authored sharp edges during recalc (DESTRUCTIVE — off by default).",
    )
    ap.add_argument(
        "--reapply-original-normals",
        action="store_true",
        help="After reduction, transfer split normals from each object's original onto "
        "its result (Data Transfer, nearest-surface). Restores authored shading even "
        "after voxel remesh. Off by default; adds a per-object transfer cost.",
    )
    ap.add_argument(
        "--remesh-disconnected-threshold",
        type=float,
        default=1.0,
        help="Threshold for disconnected-piece removal; <= 0 disables it",
    )
    ap.add_argument(
        "--thin-wall-safety",
        type=float,
        default=0.0,
        help="Enable thin-wall protection before remesh; 0 disables it",
    )
    ap.add_argument(
        "--per-submesh-auto",
        dest="per_submesh_auto",
        action="store_true",
        default=True,
        help="Pick the best reduction strategy per submesh using surface-distance and "
        "open-boundary guards, plus a flat-panel policy. ON BY DEFAULT. In scope=damaged "
        "the global pass runs first and only damaged or flat-panel objects are re-searched. "
        "Use --no-per-submesh-auto to disable.",
    )
    ap.add_argument(
        "--no-per-submesh-auto",
        dest="per_submesh_auto",
        action="store_false",
        help="Disable per-submesh adaptive strategy selection.",
    )
    ap.add_argument(
        "--per-submesh-scope",
        choices=["damaged", "all"],
        default="damaged",
        help="damaged: re-search objects over the surface or hole-loss cap, plus flat "
        "panels; all: search every submesh",
    )
    ap.add_argument(
        "--per-submesh-error-cap",
        type=float,
        default=0.01,
        help="Max per-submesh geometric error as a fraction of object bbox diagonal",
    )
    ap.add_argument(
        "--hole-loss-cap",
        type=float,
        default=0.05,
        help="Max fraction of significant open-boundary length a per-submesh variant "
        "may lose; 1 disables this guard.",
    )
    ap.add_argument(
        "--hole-loss-min-ratio",
        type=float,
        default=2.0,
        help="Apply the hole-loss guard only when original open-boundary length is at "
        "least this multiple of the object's bbox diagonal.",
    )
    ap.add_argument(
        "--auto-thin-wall",
        dest="auto_thin_wall",
        action="store_true",
        default=True,
        help="Auto-escalate thin_wall_safety on remesh variants that open holes. "
        "ON BY DEFAULT. Use --no-auto-thin-wall to disable.",
    )
    ap.add_argument(
        "--no-auto-thin-wall",
        dest="auto_thin_wall",
        action="store_false",
        help="Disable automatic per-submesh thin-wall escalation.",
    )
    ap.add_argument(
        "--auto-thin-wall-max",
        type=float,
        default=2.0,
        help="Ceiling for automatic thin-wall escalation (multiple of voxel size).",
    )
    ap.add_argument(
        "--flat-planarity-threshold",
        type=float,
        default=0.85,
        help="Area-weighted fraction of locally coplanar adjacent faces at/above which "
        "a mesh is treated as a flat panel and routed to remesh (not collapse/dissolve).",
    )
    ap.add_argument(
        "--untouched-whitelist",
        default="",
        help="Comma-separated object name fragments to skip processing",
    )
    ap.add_argument(
        "--remesh-policy",
        choices=["allow", "force", "skip"],
        default="allow",
        help="Candidate policy for voxel remesh: allow mixed, force remesh-only, or skip remesh-only",
    )
    ap.add_argument(
        "--no-html-report",
        action="store_true",
        help="Disable results.html (on by default)",
    )
    ap.add_argument(
        "--best-mode",
        choices=["size", "visual_under_target", "visual_any", "value"],
        default="visual_under_target",
        help="How to choose best candidate: closest size, best visual, or best value (P/L: size x visual score)",
    )
    ap.add_argument(
        "--lod-levels",
        type=int,
        default=1,
        help="Generate N LOD outputs at target, target/2, target/4 ... (1 = single best only)",
    )
    ap.add_argument(
        "--no-preview-compare",
        action="store_true",
        help="Disable image comparison to original previews (preview rendering still runs)",
    )
    ap.add_argument(
        "--verbose",
        action="store_true",
        help="Print extra detail per candidate (preview file paths, etc.)",
    )
    ap.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI colour in console output",
    )
    args = ap.parse_args()

    global _USE_COLOR
    _USE_COLOR = (not args.no_color) and sys.stdout.isatty()

    if not os.path.exists(args.blender):
        print(f"Blender not found: {args.blender}")
        return 2
    if not os.path.exists(args.process_script):
        print(f"Process script not found: {args.process_script}")
        return 2
    if not os.path.exists(args.input):
        print(f"Input not found: {args.input}")
        return 2

    preview_script = args.preview_script
    if args.render_previews:
        if not preview_script:
            preview_script = os.path.join(os.path.dirname(__file__), "usd_render_views.py")
        if not os.path.exists(preview_script):
            print(f"Preview script not found: {preview_script}")
            return 2

    input_size = os.path.getsize(args.input)

    if args.target_size_mb is not None:
        target_bytes = int(args.target_size_mb * 1024 * 1024)
    elif args.target_factor is not None:
        target_bytes = int(input_size * args.target_factor)
    else:
        target_bytes = int(input_size * 0.5)

    lod_levels = max(1, args.lod_levels)
    html_enabled = not args.no_html_report

    out_root = args.out_dir or tempfile.gettempdir()
    os.makedirs(out_root, exist_ok=True)
    out_dir = build_run_dir(args.input, out_root)

    print(f"Input: {args.input}")
    print(f"Input size: {fmt_size(input_size)}")
    print(f"Target size: {fmt_size(target_bytes)}")
    print(f"Output dir: {out_dir}")
    print(f"Include aggressive candidates: {args.include_aggressive}")
    print(f"Merge mode: {args.merge_mode}")
    print(f"Remove floaters: {args.remove_floaters} (min face ratio {args.floater_min_face_ratio})")
    if args.per_submesh_auto:
        print(
            f"Per-submesh auto: yes (scope={args.per_submesh_scope}, "
            f"surface cap={args.per_submesh_error_cap})"
        )
        print(
            f"Auto thin-wall: {args.auto_thin_wall} (max {args.auto_thin_wall_max}), "
            f"flat planarity threshold {args.flat_planarity_threshold}"
        )
    else:
        print("Per-submesh auto: no (--no-per-submesh-auto)")
    print(f"Remesh policy: {args.remesh_policy}")
    print(f"Remesh disconnected threshold: {args.remesh_disconnected_threshold}")
    print(f"Thin-wall safety: {args.thin_wall_safety}")
    print(f"LOD levels: {lod_levels}")
    if args.untouched_whitelist.strip():
        print(f"Untouched whitelist: {args.untouched_whitelist}")
    print(f"Per-run timeout: {args.per_run_timeout_sec}s")
    if args.render_previews:
        print(f"Render previews: yes ({args.preview_size}x{args.preview_size})")
        print(f"Preview comparison: {'no' if args.no_preview_compare else 'yes'}")
        print("Score mask mode: foreground")

    preview_compare_enabled = args.render_previews and (not args.no_preview_compare)
    baseline_prefix = os.path.join(out_dir, "baseline_original")
    baseline_meta_path = baseline_prefix + "_meta.json"
    baseline_camera_center: Optional[Tuple[float, float, float]] = None
    baseline_camera_dist: Optional[float] = None

    if args.render_previews:
        _t_base = time.time()
        baseline_err = render_previews(
            args.blender,
            preview_script,
            args.input,
            args.input,
            baseline_prefix,
            size=max(128, args.preview_size),
            timeout_sec=max(30, args.preview_timeout_sec),
            meta_out=baseline_meta_path,
            score_passes=args.score_passes,
        )
        if baseline_err:
            print(color(f"Baseline preview FAILED: {baseline_err}", "red"))
            if preview_compare_enabled:
                print("Disabling preview comparison because baseline render failed.")
            preview_compare_enabled = False
        else:
            print(color(f"Baseline previews rendered ({fmt_secs(time.time() - _t_base)})", "grey"))
            if args.verbose:
                print(f"  {baseline_prefix}_(x|y|z|oblique|oblique_bottom).png")
            try:
                with open(baseline_meta_path, "r", encoding="utf-8") as f:
                    baseline_meta = json.load(f)
                uc = baseline_meta.get("used_center")
                ud = baseline_meta.get("used_dist")
                if isinstance(uc, list) and len(uc) == 3 and ud is not None:
                    baseline_camera_center = (float(uc[0]), float(uc[1]), float(uc[2]))
                    baseline_camera_dist = float(ud)
                else:
                    raise ValueError("baseline meta missing used_center/used_dist")
            except Exception as ex:
                print(f"Failed to read baseline camera metadata: {ex}")
                if preview_compare_enabled:
                    print("Disabling preview comparison because camera metadata is unavailable.")
                preview_compare_enabled = False

    max_runs = max(1, args.max_runs)
    base_candidates = build_candidates_with_policy(
        args.include_aggressive,
        args.remesh_policy,
        aggressive_tail=False,
    )
    if lod_levels > 1:
        # Reserve slots for the aggressive LOD tail so the max-runs truncation
        # does not drop it (it is generated last, after the base candidates).
        full = build_candidates_with_policy(
            args.include_aggressive,
            args.remesh_policy,
            aggressive_tail=True,
        )
        base_keys = {candidate_key(c) for c in base_candidates}
        tail = [c for c in full if candidate_key(c) not in base_keys]
        keep_base = max(1, max_runs - len(tail))
        candidates = (base_candidates[:keep_base] + tail)[:max_runs]
    else:
        candidates = base_candidates[:max_runs]

    results: List[Result] = []
    sweep_t0 = time.time()
    for idx, cand in enumerate(candidates, start=1):
        out_path = build_output_path(args.input, cand, idx, out_dir)
        print(
            color(f"[{idx}/{len(candidates)}]", "bold", "cyan")
            + "  " + color(describe_candidate(cand), "cyan")
        )
        proc_t0 = time.time()
        res = run_candidate(
            args.blender,
            args.process_script,
            args.input,
            out_path,
            cand,
            timeout_sec=max(30, args.per_run_timeout_sec),
            merge_mode=args.merge_mode,
            remesh_disconnected_threshold=args.remesh_disconnected_threshold,
            thin_wall_safety=args.thin_wall_safety,
            remove_floaters=args.remove_floaters,
            floater_min_face_ratio=args.floater_min_face_ratio,
            per_submesh_auto=args.per_submesh_auto,
            per_submesh_scope=args.per_submesh_scope,
            per_submesh_error_cap=args.per_submesh_error_cap,
            hole_loss_cap=args.hole_loss_cap,
            hole_loss_min_ratio=args.hole_loss_min_ratio,
            auto_thin_wall=args.auto_thin_wall,
            auto_thin_wall_max=args.auto_thin_wall_max,
            flat_planarity_threshold=args.flat_planarity_threshold,
            clear_custom_normals=args.clear_custom_normals,
            clear_sharp_edges=args.clear_sharp_edges,
            reapply_original_normals=args.reapply_original_normals,
            untouched_name_whitelist=args.untouched_whitelist,
        )
        proc_secs = time.time() - proc_t0
        prev_secs = 0.0
        results.append(res)
        if res.ok:
            if args.render_previews:
                preview_prefix = os.path.splitext(res.output_path)[0]
                score_path = preview_prefix + "_score.json"
                per_preview_timeout = max(30, args.preview_timeout_sec)
                prev_t0 = time.time()
                err = render_previews(
                    args.blender,
                    preview_script,
                    args.input,
                    res.output_path,
                    preview_prefix,
                    size=max(128, args.preview_size),
                    timeout_sec=per_preview_timeout,
                    camera_center=baseline_camera_center,
                    camera_dist=baseline_camera_dist,
                    compare_to_prefix=baseline_prefix if preview_compare_enabled else None,
                    score_out=score_path if preview_compare_enabled else None,
                    score_passes=args.score_passes,
                )
                prev_secs = time.time() - prev_t0
                res.score_path = score_path if preview_compare_enabled else None
                if err:
                    print(color(f"  → preview FAILED: {err}", "red"))
                else:
                    if preview_compare_enabled and os.path.exists(score_path):
                        try:
                            with open(score_path, "r", encoding="utf-8") as f:
                                score_json = json.load(f)
                            score_value = score_json.get("score_value")
                            if score_value is not None:
                                res.visual_score = float(score_value)
                            comps = score_json.get("score_components")
                            if comps:
                                res.score_components = "  ".join(
                                    f"{k[:3]}={v:.3f}" for k, v in comps.items()
                                )

                            # Persist candidate/run parameters for later manual fine-tuning.
                            score_json["candidate"] = {
                                "ratio": res.candidate.ratio,
                                "use_voxel_remesh": res.candidate.use_voxel_remesh,
                                "voxel_size": res.candidate.voxel_size,
                                "decimate_mode": res.candidate.decimate_mode,
                                "dissolve_angle_deg": res.candidate.dissolve_angle_deg,
                                "recalc_after_process": res.candidate.recalc_after_process,
                                "skip_multimaterial_remesh": res.candidate.skip_multimaterial_remesh,
                            }
                            score_json["output"] = {
                                "usd_path": res.output_path,
                                "size_bytes": res.output_size,
                                "size_mb": res.output_size / (1024.0 * 1024.0),
                            }
                            score_json["target"] = {
                                "target_size_bytes": target_bytes,
                                "target_size_mb": target_bytes / (1024.0 * 1024.0),
                                "is_under_target": res.output_size <= target_bytes,
                            }
                            score_json["run"] = {
                                "input_usd": args.input,
                                "best_mode": args.best_mode,
                                "score_mask_mode": "foreground",
                                "merge_mode": args.merge_mode,
                                "remove_floaters": args.remove_floaters,
                                "per_submesh_auto": args.per_submesh_auto,
                                "per_submesh_scope": args.per_submesh_scope,
                                "per_submesh_error_cap": args.per_submesh_error_cap,
                                "hole_loss_cap": args.hole_loss_cap,
                                "hole_loss_min_ratio": args.hole_loss_min_ratio,
                                "auto_thin_wall": args.auto_thin_wall,
                                "auto_thin_wall_max": args.auto_thin_wall_max,
                                "flat_planarity_threshold": args.flat_planarity_threshold,
                                "remesh_policy": args.remesh_policy,
                                "remesh_disconnected_threshold": args.remesh_disconnected_threshold,
                                "thin_wall_safety": args.thin_wall_safety,
                                "clear_custom_normals": args.clear_custom_normals,
                                "clear_sharp_edges": args.clear_sharp_edges,
                                "reapply_original_normals": args.reapply_original_normals,
                                "untouched_whitelist": args.untouched_whitelist,
                                "preview_size": max(128, args.preview_size),
                                "score_passes": args.score_passes,
                            }

                            # Fold in the per-submesh diagnostics sidecar if present.
                            psa_sidecar_path = preview_prefix + ".psa.json"
                            if os.path.exists(psa_sidecar_path):
                                try:
                                    with open(psa_sidecar_path, "r", encoding="utf-8") as pf:
                                        psa = json.load(pf)
                                    counters = psa.get("counters", {})
                                    score_json["per_submesh"] = {
                                        "counters": counters,
                                        "strategy_counts": psa.get("strategy_counts", {}),
                                    }
                                    res.psa_summary = (
                                        f"reproc {counters.get('reprocessed', 0)}, "
                                        f"flat-routed {counters.get('flat_routed', 0)}, "
                                        f"thinwall {counters.get('thin_wall_auto', 0)}, "
                                        f"untouched {counters.get('untouched_fallback', 0)}"
                                    )
                                except Exception as ex:
                                    print(f"  -> PSA sidecar read FAILED: {ex}")

                            with open(score_path, "w", encoding="utf-8") as f:
                                json.dump(score_json, f, indent=2)
                        except Exception as ex:
                            print(color(f"  → preview score read FAILED: {ex}", "red"))
                    if args.verbose:
                        print(color(
                            f"    previews: {preview_prefix}_(x|y|z|oblique|oblique_bottom).png",
                            "grey",
                        ))
            # Compact result line: size · target · score (+ per-pass) · timings.
            under_txt = color("under", "green") if res.output_size <= target_bytes else color("OVER", "yellow")
            bits = [color(fmt_size(res.output_size), "bold"), f"target {under_txt}"]
            if res.visual_score is not None:
                s = f"score {res.visual_score:.4f}"
                if res.score_components:
                    s += color(f" [{res.score_components}]", "grey")
                bits.append(s)
            timing = f"proc {fmt_secs(proc_secs)}"
            if args.render_previews:
                timing += f" · preview {fmt_secs(prev_secs)}"
            bits.append(color(timing, "grey"))
            print("  → " + "   ".join(bits))
            print(color(f"    {os.path.basename(res.output_path)}", "grey"))
        else:
            print(color(f"  → FAILED after {fmt_secs(proc_secs)}: {res.error}", "red"))

    best_size = pick_best_by_size(results, target_bytes)
    best_visual_under = pick_best_by_visual(results, target_bytes, under_target_only=True)
    best_visual_any = pick_best_by_visual(results, target_bytes, under_target_only=False)
    best_value = pick_best_by_value(results, target_bytes, under_target_only=True) or pick_best_by_value(results)

    if args.best_mode == "size":
        best = best_size
    elif args.best_mode == "visual_any":
        best = best_visual_any or best_size
    elif args.best_mode == "value":
        best = best_value or best_visual_under or best_size
    else:
        best = best_visual_under or best_visual_any or best_size

    sweep_secs = time.time() - sweep_t0
    ok_count = sum(1 for r in results if r.ok)
    print(color(
        f"\nSweep done: {ok_count}/{len(results)} candidates in {fmt_secs(sweep_secs)} "
        f"(~{fmt_secs(sweep_secs / max(1, len(results)))}/candidate)",
        "bold",
    ))
    print("\nSummary:")
    for r in results:
        name = os.path.basename(r.output_path)
        if r.ok:
            visual_str = f"  visual={r.visual_score:.6f}" if r.visual_score is not None else ""
            vm = value_metric(r)
            value_str = f"  value={vm:.3e}" if vm is not None else ""
            print(
                f"  OK  {fmt_size(r.output_size):>10}  {name}  "
                f"r={r.candidate.ratio} vox={r.candidate.voxel_size} "
                f"mode={r.candidate.decimate_mode} ang={r.candidate.dissolve_angle_deg} "
                f"recalc={r.candidate.recalc_after_process} "
                f"remesh={r.candidate.use_voxel_remesh} "
                f"skipmm={r.candidate.skip_multimaterial_remesh}"
                f"{visual_str}{value_str}"
            )
        else:
            print(
                f"  ERR {'-':>10}  {name}  "
                f"r={r.candidate.ratio} vox={r.candidate.voxel_size} "
                f"mode={r.candidate.decimate_mode} ang={r.candidate.dissolve_angle_deg} "
                f"recalc={r.candidate.recalc_after_process} "
                f"remesh={r.candidate.use_voxel_remesh} "
                f"skipmm={r.candidate.skip_multimaterial_remesh}"
            )

    if best is None:
        print("\nNo successful candidate.")
        return 1

    if best_size is not None:
        print(
            "\nBest by size: "
            f"{fmt_size(best_size.output_size)} {best_size.output_path}"
        )
    if best_visual_under is not None:
        print(
            "Best by visual under target: "
            f"score={best_visual_under.visual_score:.6f} {best_visual_under.output_path}"
        )
    elif preview_compare_enabled:
        print("Best by visual under target: none (no scored candidate under target).")
    if best_visual_any is not None:
        print(
            "Best by visual any size: "
            f"score={best_visual_any.visual_score:.6f} {best_visual_any.output_path}"
        )
    if best_value is not None:
        vm = value_metric(best_value)
        print(
            "Best by value (P/L, size x visual score, lower is better): "
            f"value={vm:.3e} {best_value.output_path}"
        )

    print(f"\nBest candidate (mode={args.best_mode}):")
    print(
        f"  size={fmt_size(best.output_size)} path={best.output_path}\n"
        f"  ratio={best.candidate.ratio}, voxel={best.candidate.voxel_size}, "
        f"mode={best.candidate.decimate_mode}, dissolve_angle_deg={best.candidate.dissolve_angle_deg}, "
        f"recalc_after_process={best.candidate.recalc_after_process}, "
        f"use_voxel_remesh={best.candidate.use_voxel_remesh}, "
        f"skip_multimaterial_remesh={best.candidate.skip_multimaterial_remesh}"
    )

    # LOD generation: one candidate sweep, pick best per descending target.
    lod_rows: List[dict] = []
    lod_best_paths = set()
    if lod_levels > 1:
        print(f"\nLOD generation ({lod_levels} levels):")
        for i in range(lod_levels):
            lod_target = int(target_bytes / (2 ** i))
            chosen = select_for_target(results, lod_target, args.best_mode)
            if chosen is None:
                print(f"  lod{i}: target {fmt_size(lod_target)} -> no candidate available")
                lod_rows.append({"index": i, "target_bytes": lod_target})
                continue
            dst = copy_lod_outputs(chosen, i, out_dir)
            lod_best_paths.add(chosen.output_path)
            under = chosen.output_size <= lod_target
            warn = "" if under else "  [WARNING: over target; smallest available]"
            print(
                f"  lod{i}: target {fmt_size(lod_target)} -> "
                f"{fmt_size(chosen.output_size)} {os.path.basename(dst)}{warn}"
            )
            lod_rows.append(
                {
                    "index": i,
                    "target_bytes": lod_target,
                    "output_name": os.path.basename(dst),
                    "output_size": chosen.output_size,
                    "visual_score": chosen.visual_score,
                    "under_target": under,
                }
            )

    if html_enabled and results:
        html_path = generate_results_html(
            out_dir=out_dir,
            input_usd=args.input,
            target_bytes=target_bytes,
            best_mode=args.best_mode,
            results=results,
            baseline_prefix=baseline_prefix if args.render_previews else None,
            lod_rows=lod_rows if lod_rows else None,
        )
        print(f"\nResults HTML: {html_path}")

    if args.delete_non_best:
        keep_paths = {best.output_path} | lod_best_paths
        for r in results:
            if r.ok and r.output_path not in keep_paths:
                try:
                    os.remove(r.output_path)
                except Exception:
                    pass
                # Remove companion preview files if present.
                preview_prefix = os.path.splitext(r.output_path)[0]
                preview_paths = [
                    preview_prefix + "_x.png",
                    preview_prefix + "_y.png",
                    preview_prefix + "_z.png",
                    preview_prefix + "_oblique.png",
                    preview_prefix + "_oblique_bottom.png",
                    preview_prefix + "_score.json",
                ]
                for p in preview_paths:
                    try:
                        if os.path.exists(p):
                            os.remove(p)
                    except Exception:
                        pass

        baseline_paths = [
            baseline_prefix + "_x.png",
            baseline_prefix + "_y.png",
            baseline_prefix + "_z.png",
            baseline_prefix + "_oblique.png",
            baseline_prefix + "_oblique_bottom.png",
            baseline_meta_path,
        ]
        for p in baseline_paths:
            try:
                if os.path.exists(p):
                    os.remove(p)
            except Exception:
                pass

        print("\nCleanup: deleted non-best candidate outputs (--delete-non-best).")
    else:
        print("\nCleanup: kept all candidate outputs (default).")

    return 0


if __name__ == "__main__":
    sys.exit(main())
