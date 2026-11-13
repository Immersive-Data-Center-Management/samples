import bpy
import argparse
import json
import os
import sys
from mathutils import Vector


def parse_args():
    argv = sys.argv
    if "--" not in argv:
        raise RuntimeError(
            "Usage: blender -b --python usd_render_views.py -- <input_usd> <candidate_usd> <preview_prefix_or_dir> "
            "[--size N] [--camera-center x,y,z] [--camera-dist D] [--compare-to-prefix PREFIX] "
            "[--score-out PATH] [--meta-out PATH]"
        )
    raw = argv[argv.index("--") + 1 :]
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("input_usd")
    ap.add_argument("candidate_usd")
    ap.add_argument("preview_prefix_or_dir")
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--camera-center", default=None, help="x,y,z world-space center")
    ap.add_argument("--camera-dist", type=float, default=None)
    ap.add_argument("--compare-to-prefix", default=None)
    ap.add_argument("--score-out", default=None)
    ap.add_argument("--meta-out", default=None)
    ap.add_argument(
        "--score-mask-mode",
        choices=["full", "foreground"],
        default="foreground",
        help="How to select pixels for image diff scoring",
    )
    ap.add_argument(
        "--score-passes",
        default="rgb",
        help="Comma list of render passes used for scoring: rgb, normal, silhouette. "
        "rgb = studio-lit material RMSE; normal = matcap (view-space normal) RMSE, "
        "sensitive to shading/crumple; silhouette = alpha-mask IoU, catches holes / "
        "missing parts / outline drift. The combined score weights normal and "
        "silhouette above rgb (hard-surface tuning).",
    )
    ns = ap.parse_args(raw)

    passes = [p.strip().lower() for p in str(ns.score_passes).split(",") if p.strip()]
    valid_passes = {"rgb", "normal", "silhouette"}
    bad = [p for p in passes if p not in valid_passes]
    if bad:
        raise RuntimeError(f"Unknown score pass(es) {bad}; valid: {sorted(valid_passes)}")
    if "rgb" not in passes:
        passes = ["rgb"] + passes  # rgb is always rendered (primary preview)

    camera_center = None
    if ns.camera_center:
        parts = [p.strip() for p in ns.camera_center.split(",")]
        if len(parts) != 3:
            raise RuntimeError("--camera-center must be in x,y,z format")
        camera_center = Vector((float(parts[0]), float(parts[1]), float(parts[2])))

    return {
        "input_usd": ns.input_usd,
        "candidate_usd": ns.candidate_usd,
        "preview_prefix_or_dir": ns.preview_prefix_or_dir,
        "size": max(128, ns.size),
        "camera_center": camera_center,
        "camera_dist": ns.camera_dist,
        "compare_to_prefix": ns.compare_to_prefix,
        "score_out": ns.score_out,
        "meta_out": ns.meta_out,
        "score_mask_mode": ns.score_mask_mode,
        "score_passes": passes,
    }


def world_bbox_for_meshes(meshes):
    mins = Vector((1e30, 1e30, 1e30))
    maxs = Vector((-1e30, -1e30, -1e30))
    for obj in meshes:
        for c in obj.bound_box:
            wc = obj.matrix_world @ Vector(c)
            mins.x = min(mins.x, wc.x)
            mins.y = min(mins.y, wc.y)
            mins.z = min(mins.z, wc.z)
            maxs.x = max(maxs.x, wc.x)
            maxs.y = max(maxs.y, wc.y)
            maxs.z = max(maxs.z, wc.z)
    return mins, maxs


def point_camera_at(camera_obj, target):
    direction = target - camera_obj.location
    rot_quat = direction.to_track_quat("-Z", "Y")
    camera_obj.rotation_euler = rot_quat.to_euler()


def build_preview_paths(preview_prefix_or_dir):
    # If caller passes a directory, keep legacy behavior.
    # Preferred behavior is passing a file prefix and writing:
    # <prefix>_x.png, <prefix>_y.png, <prefix>_z.png
    lower = preview_prefix_or_dir.lower()
    if lower.endswith(".png"):
        base = preview_prefix_or_dir[:-4]
    else:
        base = preview_prefix_or_dir

    if os.path.isdir(preview_prefix_or_dir) or preview_prefix_or_dir.endswith(("/", "\\")):
        out_dir = preview_prefix_or_dir.rstrip("/\\")
        os.makedirs(out_dir, exist_ok=True)
        return {
            "x": os.path.join(out_dir, "view_x.png"),
            "y": os.path.join(out_dir, "view_y.png"),
            "z": os.path.join(out_dir, "view_z.png"),
            "oblique": os.path.join(out_dir, "view_oblique.png"),
            "oblique_bottom": os.path.join(out_dir, "view_oblique_bottom.png"),
        }

    out_dir = os.path.dirname(base) or "."
    os.makedirs(out_dir, exist_ok=True)
    return {
        "x": base + "_x.png",
        "y": base + "_y.png",
        "z": base + "_z.png",
        "oblique": base + "_oblique.png",
        "oblique_bottom": base + "_oblique_bottom.png",
    }


# Combined-score weights per pass. Normal (shading) and silhouette (shape/holes)
# are weighted above plain RGB, which mixes geometry with studio lighting/material
# colour and dilutes small but important defects. Renormalized over the passes
# actually rendered.
SCORE_PASS_WEIGHTS = {"rgb": 0.25, "normal": 0.40, "silhouette": 0.35}


def pass_suffix_path(rgb_path, mode):
    """Map a base (rgb) preview path to the path for another scoring pass."""
    if mode == "rgb":
        return rgb_path
    base = rgb_path[:-4] if rgb_path.lower().endswith(".png") else rgb_path
    return f"{base}_{mode}.png"


def configure_shading_for_pass(scene, mode):
    """Set up Workbench shading for one scoring pass. Returns True if the pass is
    usable, False if it could not be configured (caller should skip it)."""
    shading = scene.display.shading
    if mode == "rgb":
        scene.render.film_transparent = False
        shading.light = "STUDIO"
        shading.color_type = "MATERIAL"
        shading.show_cavity = True
        if hasattr(shading, "cavity_type"):
            shading.cavity_type = "BOTH"
        if hasattr(shading, "cavity_ridge_factor"):
            shading.cavity_ridge_factor = 0.85
        if hasattr(shading, "cavity_valley_factor"):
            shading.cavity_valley_factor = 0.75
        return True

    if mode == "silhouette":
        # Flat white object on a transparent background -> the alpha channel is a
        # clean coverage mask, independent of material colour and lighting.
        scene.render.film_transparent = True
        shading.light = "FLAT"
        shading.color_type = "SINGLE"
        shading.show_cavity = False
        if hasattr(shading, "single_color"):
            shading.single_color = (1.0, 1.0, 1.0)
        return True

    if mode == "normal":
        # A matcap render is a deterministic function of the view-space surface
        # normal, so its difference measures shading/normal change directly. Prefer
        # the built-in normal-visualizing matcap; fall back to any available matcap.
        scene.render.film_transparent = False
        shading.light = "MATCAP"
        shading.color_type = "SINGLE"
        shading.show_cavity = False
        if hasattr(shading, "single_color"):
            shading.single_color = (0.8, 0.8, 0.8)
        preferred = "check_normal+y.exr"
        try:
            studio_lights = [
                s.name for s in bpy.context.preferences.studio_lights
                if getattr(s, "type", "") == "MATCAP"
            ]
        except Exception:
            studio_lights = []
        try:
            if preferred in studio_lights:
                shading.studio_light = preferred
            elif studio_lights:
                shading.studio_light = studio_lights[0]
            return True
        except Exception:
            return bool(studio_lights)

    return False


def silhouette_iou(path_a, path_b, alpha_threshold=0.5):
    """Intersection-over-union of the alpha (coverage) masks of two silhouette
    renders. 1.0 = identical outline; lower = missing/extra parts or outline drift."""
    img_a = bpy.data.images.load(path_a, check_existing=False)
    img_b = bpy.data.images.load(path_b, check_existing=False)
    try:
        wa, ha = img_a.size
        wb, hb = img_b.size
        if wa != wb or ha != hb:
            raise RuntimeError(f"Image size mismatch: {path_a} vs {path_b}")
        pa = img_a.pixels[:]
        pb = img_b.pixels[:]
        inter = 0
        union = 0
        for i in range(3, min(len(pa), len(pb)), 4):
            a_on = pa[i] >= alpha_threshold
            b_on = pb[i] >= alpha_threshold
            if a_on or b_on:
                union += 1
                if a_on and b_on:
                    inter += 1
        iou = (inter / union) if union else 1.0
        return {"iou": iou, "intersection": inter, "union": union}
    finally:
        bpy.data.images.remove(img_a)
        bpy.data.images.remove(img_b)


def compare_png_rgb_metrics(path_a, path_b):
    img_a = bpy.data.images.load(path_a, check_existing=False)
    img_b = bpy.data.images.load(path_b, check_existing=False)
    try:
        wa, ha = img_a.size
        wb, hb = img_b.size
        if wa != wb or ha != hb:
            raise RuntimeError(
                f"Image size mismatch: {path_a} ({wa}x{ha}) vs {path_b} ({wb}x{hb})"
            )

        pa = img_a.pixels[:]
        pb = img_b.pixels[:]
        if len(pa) != len(pb):
            raise RuntimeError("Image pixel data length mismatch")

        sum_abs = 0.0
        sum_sq = 0.0
        count = 0
        for i in range(0, len(pa), 4):
            for c in (0, 1, 2):
                d = pa[i + c] - pb[i + c]
                if d < 0.0:
                    sum_abs += -d
                else:
                    sum_abs += d
                sum_sq += d * d
                count += 1

        mae = (sum_abs / count) if count else 0.0
        mse = (sum_sq / count) if count else 0.0
        rmse = mse ** 0.5
        return {"mae": mae, "mse": mse, "rmse": rmse, "width": wa, "height": ha}
    finally:
        bpy.data.images.remove(img_a)
        bpy.data.images.remove(img_b)


def compare_png_rgb_metrics_foreground(path_a, path_b):
    img_a = bpy.data.images.load(path_a, check_existing=False)
    img_b = bpy.data.images.load(path_b, check_existing=False)
    try:
        wa, ha = img_a.size
        wb, hb = img_b.size
        if wa != wb or ha != hb:
            raise RuntimeError(
                f"Image size mismatch: {path_a} ({wa}x{ha}) vs {path_b} ({wb}x{hb})"
            )

        pa = img_a.pixels[:]
        pb = img_b.pixels[:]
        if len(pa) != len(pb):
            raise RuntimeError("Image pixel data length mismatch")

        # Estimate viewport background color from corner pixels for each image.
        # Foreground = pixels that differ from either background estimate.
        corners = [
            0,
            (wa - 1) * 4,
            ((ha - 1) * wa) * 4,
            ((ha - 1) * wa + (wa - 1)) * 4,
        ]

        def avg_corner_rgb(pix):
            r = g = b = 0.0
            for idx in corners:
                r += pix[idx + 0]
                g += pix[idx + 1]
                b += pix[idx + 2]
            n = float(len(corners))
            return (r / n, g / n, b / n)

        bg_a = avg_corner_rgb(pa)
        bg_b = avg_corner_rgb(pb)
        threshold = 0.02

        sum_abs = 0.0
        sum_sq = 0.0
        count = 0
        compared_pixels = 0
        total_pixels = wa * ha

        for i in range(0, len(pa), 4):
            da = max(
                abs(pa[i + 0] - bg_a[0]),
                abs(pa[i + 1] - bg_a[1]),
                abs(pa[i + 2] - bg_a[2]),
            )
            db = max(
                abs(pb[i + 0] - bg_b[0]),
                abs(pb[i + 1] - bg_b[1]),
                abs(pb[i + 2] - bg_b[2]),
            )
            is_foreground = (da > threshold) or (db > threshold)
            if not is_foreground:
                continue

            compared_pixels += 1
            for c in (0, 1, 2):
                d = pa[i + c] - pb[i + c]
                if d < 0.0:
                    sum_abs += -d
                else:
                    sum_abs += d
                sum_sq += d * d
                count += 1

        # Fallback to full-image score if mask became empty.
        if count == 0:
            full = compare_png_rgb_metrics(path_a, path_b)
            full.update(
                {
                    "mask_mode": "foreground",
                    "mask_fallback_to_full": True,
                    "compared_pixels": 0,
                    "total_pixels": total_pixels,
                    "foreground_fraction": 0.0,
                }
            )
            return full

        mae = sum_abs / count
        mse = sum_sq / count
        rmse = mse ** 0.5
        return {
            "mae": mae,
            "mse": mse,
            "rmse": rmse,
            "width": wa,
            "height": ha,
            "mask_mode": "foreground",
            "mask_fallback_to_full": False,
            "compared_pixels": compared_pixels,
            "total_pixels": total_pixels,
            "foreground_fraction": (compared_pixels / total_pixels) if total_pixels else 0.0,
        }
    finally:
        bpy.data.images.remove(img_a)
        bpy.data.images.remove(img_b)


def render_views(
    stage_path,
    preview_prefix_or_dir,
    size,
    camera_center=None,
    camera_dist=None,
    compare_to_prefix=None,
    score_out=None,
    meta_out=None,
    score_mask_mode="foreground",
    score_passes=None,
):
    if not os.path.exists(stage_path):
        raise FileNotFoundError(f"USD not found: {stage_path}")

    score_passes = score_passes or ["rgb"]
    out_paths = build_preview_paths(preview_prefix_or_dir)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=stage_path)

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        raise RuntimeError("No mesh objects found after import")

    mins, maxs = world_bbox_for_meshes(meshes)
    computed_center = (mins + maxs) * 0.5
    extents = maxs - mins
    max_dim = max(extents.x, extents.y, extents.z)
    computed_dist = max(0.5, max_dim * 1.7)

    center = camera_center if camera_center is not None else computed_center
    dist = camera_dist if camera_dist is not None else computed_dist

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"  # keep alpha for silhouette masks

    cam_data = bpy.data.cameras.new("AutoPreviewCamera")
    cam_obj = bpy.data.objects.new("AutoPreviewCamera", cam_data)
    scene.collection.objects.link(cam_obj)
    scene.camera = cam_obj

    views = {
        "x": Vector((dist, 0.0, 0.0)),
        "y": Vector((0.0, dist, 0.0)),
        "z": Vector((0.0, 0.0, dist)),
        "oblique": Vector((dist * 0.85, -dist * 0.75, dist * 0.55)),
        "oblique_bottom": Vector((-dist * 0.85, dist * 0.75, -dist * 0.55)),
    }

    # Render each requested pass for every view. All passes reuse the single import
    # above, so extra passes only cost re-renders (cheap), not another USD load.
    rendered_passes = []
    for mode in score_passes:
        if not configure_shading_for_pass(scene, mode):
            print(f"[preview] pass '{mode}' unavailable in this Blender build; skipping")
            continue
        rendered_passes.append(mode)
        for name, offset in views.items():
            cam_obj.location = center + offset
            point_camera_at(cam_obj, center)
            out_path = pass_suffix_path(out_paths[name], mode)
            scene.render.filepath = out_path
            bpy.ops.render.render(write_still=True)
            print(f"[preview] wrote {out_path}")

    if meta_out:
        meta = {
            "used_center": [float(center.x), float(center.y), float(center.z)],
            "used_dist": float(dist),
            "computed_center": [float(computed_center.x), float(computed_center.y), float(computed_center.z)],
            "computed_dist": float(computed_dist),
            "size": int(size),
            "views": out_paths,
            "score_passes": rendered_passes,
        }
        with open(meta_out, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)

    if compare_to_prefix and score_out:
        ref_paths = build_preview_paths(compare_to_prefix)

        def rgb_component():
            per_view = {}
            for name, cand in out_paths.items():
                ref = ref_paths.get(name)
                if not ref or not os.path.exists(ref) or not os.path.exists(cand):
                    continue
                if score_mask_mode == "foreground":
                    per_view[name] = compare_png_rgb_metrics_foreground(ref, cand)
                else:
                    per_view[name] = compare_png_rgb_metrics(ref, cand)
            if not per_view:
                return None
            mean_rmse = sum(v["rmse"] for v in per_view.values()) / len(per_view)
            return mean_rmse, per_view

        def normal_component():
            per_view = {}
            for name, cand_base in out_paths.items():
                cand = pass_suffix_path(cand_base, "normal")
                ref = pass_suffix_path(ref_paths.get(name, ""), "normal")
                if not os.path.exists(ref) or not os.path.exists(cand):
                    continue
                per_view[name] = compare_png_rgb_metrics_foreground(ref, cand)
            if not per_view:
                return None
            mean_rmse = sum(v["rmse"] for v in per_view.values()) / len(per_view)
            return mean_rmse, per_view

        def silhouette_component():
            per_view = {}
            for name, cand_base in out_paths.items():
                cand = pass_suffix_path(cand_base, "silhouette")
                ref = pass_suffix_path(ref_paths.get(name, ""), "silhouette")
                if not os.path.exists(ref) or not os.path.exists(cand):
                    continue
                per_view[name] = silhouette_iou(ref, cand)
            if not per_view:
                return None
            mean_iou = sum(v["iou"] for v in per_view.values()) / len(per_view)
            # Report as an error (lower is better), consistent with the other passes.
            return (1.0 - mean_iou), per_view

        components = {}       # pass -> scalar error (lower better)
        per_view_by_pass = {}
        rgb = rgb_component()
        if rgb is not None:
            components["rgb"] = rgb[0]
            per_view_by_pass["rgb"] = rgb[1]
        if "normal" in rendered_passes:
            nrm = normal_component()
            if nrm is not None:
                components["normal"] = nrm[0]
                per_view_by_pass["normal"] = nrm[1]
        if "silhouette" in rendered_passes:
            sil = silhouette_component()
            if sil is not None:
                components["silhouette"] = sil[0]
                per_view_by_pass["silhouette"] = sil[1]

        if not components:
            raise RuntimeError("No comparable preview images found for scoring")

        # Weighted blend over the passes that actually produced a score.
        total_w = sum(SCORE_PASS_WEIGHTS.get(k, 0.0) for k in components)
        if total_w <= 0.0:
            combined = sum(components.values()) / len(components)
        else:
            combined = sum(
                SCORE_PASS_WEIGHTS.get(k, 0.0) * v for k, v in components.items()
            ) / total_w

        score = {
            "score_metric": "combined",
            "score_value": combined,
            "score_mask_mode": score_mask_mode,
            # Back-compat: rgb mean RMSE is still exposed under the old key.
            "mean_rmse": components.get("rgb"),
            "score_components": {k: round(v, 6) for k, v in components.items()},
            "score_weights": {k: SCORE_PASS_WEIGHTS.get(k, 0.0) for k in components},
            "passes_scored": list(components.keys()),
            "per_view": per_view_by_pass.get("rgb", {}),
            "per_view_by_pass": per_view_by_pass,
        }
        with open(score_out, "w", encoding="utf-8") as f:
            json.dump(score, f, indent=2)


def main():
    parsed = parse_args()
    render_views(
        parsed["candidate_usd"],
        parsed["preview_prefix_or_dir"],
        parsed["size"],
        camera_center=parsed["camera_center"],
        camera_dist=parsed["camera_dist"],
        compare_to_prefix=parsed["compare_to_prefix"],
        score_out=parsed["score_out"],
        meta_out=parsed["meta_out"],
        score_mask_mode=parsed["score_mask_mode"],
        score_passes=parsed["score_passes"],
    )


if __name__ == "__main__":
    main()
