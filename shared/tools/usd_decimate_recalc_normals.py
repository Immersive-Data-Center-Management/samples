import bpy
import sys
import os
import math
import time
import bmesh
from mathutils.bvhtree import BVHTree


HELP_TEXT = """
USD Decimate/Remesh Utility (Blender headless)

Usage:
    blender -b --python usd_decimate_recalc_normals.py -- \
        <input_usd> [output_usd] [ratio] \
        [merge_mode=none|all|material] [use_voxel_remesh=0|1] [voxel_size=0.1] \
        [decimate_mode=COLLAPSE|DISSOLVE] [dissolve_angle_deg=3.0] \
        [recalc_after_process=0|1] [clear_custom_normals=0|1] [clear_sharp_edges=0|1] \
        [skip_multimaterial_remesh=0|1] \
        [min_faces_for_decimate=4] [remesh_disconnected_threshold=1.0] \
        [thin_wall_safety=0.0] [remove_floaters=0|1] [floater_min_face_ratio=0.01] \
        [per_submesh_auto=0|1] [per_submesh_scope=damaged|all] [per_submesh_error_cap=0.01] \
        [hole_loss_cap=0.05] [hole_loss_min_ratio=2.0] \
        [auto_thin_wall=0|1] [auto_thin_wall_max=2.0] [flat_planarity_threshold=0.85] \
        [untouched_name_whitelist=comma,separated,name,parts]

    You can also pass only specific named overrides:
        ... -- <input_usd> -thin_wall_safety=1.5 -remove_floaters=1
    Supported prefix styles: -name=value or --name=value

Notes:
    - merge_mode=all joins every mesh into one; merge_mode=material joins only
      meshes with an identical material-slot list (same materials in the same
      slot order).
    - recalc_after_process=1 fixes face winding after processing, but only on
      meshes without authored custom split normals: flipping the winding of a
      custom-normal mesh inverts its authored shading. It no longer clears custom
      normals or sharp edges by default (that would flatten intentional relief such
      as an embossed logo). Set clear_custom_normals=1 / clear_sharp_edges=1 to
      restore the old destructive behaviour. Note: voxel remesh always rebuilds the
      mesh, so authored custom normals cannot be preserved on a remeshed object.
    - reapply_original_normals=1 transfers split normals from each object's original
      onto its reduced result (Blender Data Transfer, nearest-surface mapping). This
      restores authored/original shading even after voxel remesh (which rebuilds the
      mesh). Opt-in; adds a per-object transfer cost.
    - skip_multimaterial_remesh=1 protects meshes with multiple materials.
    - thin_wall_safety>0 estimates wall thickness and solidifies thin walls
      before voxel remesh so they do not disappear.
    - remove_floaters=1 deletes small disconnected mesh islands (floaters).
    - per_submesh_auto=1 picks the best reduction strategy per submesh. Flat panels
      (local planarity >= flat_planarity_threshold) are routed to voxel remesh,
      because COLLAPSE and DISSOLVE both crumple a flat panel's shading into a
      diamond/foil pattern while remesh rebuilds clean flat topology; if no remesh
      variant reduces within per_submesh_error_cap (or the panel is multi-material
      and remesh is skipped) the panel is left untouched rather than crumpled. Other
      (detailed) meshes try remesh/collapse and are gated on surface distance only.
      When auto_thin_wall=1, a remesh variant that opens holes (missing geometry) is
      automatically re-tried with an escalating thin_wall_safety up to
      auto_thin_wall_max, so thin panels survive voxelization without manual tuning.
      per_submesh_scope=damaged searches objects the global pass moved too far OR
      that are flat panels; per_submesh_scope=all searches every object.
    - hole_loss_cap (default 0.05) rejects any PSA variant that loses more than
      this fraction of the original open-boundary length. Voxel remesh seals
      perforation holes without moving the surface, so distance metrics cannot
      see the damage; boundary length can. Set 1.0 to disable.
    - hole_loss_min_ratio (default 2.0) only enforces the hole guard when the
      original open-boundary length is at least this multiple of the object's
      bbox diagonal. A panel with a few tiny open rims is not a perforated sheet,
      and keeping it full-res just to save those rims costs a lot of size.
""".strip()


OPTION_SPECS = {
    "merge_mode": ("str", "none"),
    "use_voxel_remesh": ("bool", False),
    "voxel_size": ("float", 0.1),
    "decimate_mode": ("str", "COLLAPSE"),
    "dissolve_angle_deg": ("float", 3.0),
    "recalc_after_process": ("bool", True),
    "clear_custom_normals": ("bool", False),
    "clear_sharp_edges": ("bool", False),
    "reapply_original_normals": ("bool", False),
    "skip_multimaterial_remesh": ("bool", True),
    "min_faces_for_decimate": ("int", 4),
    "remesh_disconnected_threshold": ("float", 1.0),
    "thin_wall_safety": ("float", 0.0),
    "remove_floaters": ("bool", False),
    "floater_min_face_ratio": ("float", 0.01),
    "per_submesh_auto": ("bool", False),
    "per_submesh_scope": ("str", "damaged"),
    "per_submesh_error_cap": ("float", 0.01),
    "hole_loss_cap": ("float", 0.05),
    "hole_loss_min_ratio": ("float", 2.0),
    "auto_thin_wall": ("bool", True),
    "auto_thin_wall_max": ("float", 2.0),
    "flat_planarity_threshold": ("float", 0.85),
    "untouched_name_whitelist": ("str", ""),
}


DEFAULT_RATIO = 0.35

OPTIONAL_POSITIONAL_ORDER = [
    "merge_mode",
    "use_voxel_remesh",
    "voxel_size",
    "decimate_mode",
    "dissolve_angle_deg",
    "recalc_after_process",
    "skip_multimaterial_remesh",
    "min_faces_for_decimate",
    "remesh_disconnected_threshold",
    "thin_wall_safety",
    "remove_floaters",
    "floater_min_face_ratio",
    "per_submesh_auto",
    "per_submesh_scope",
    "per_submesh_error_cap",
    "auto_thin_wall",
    "auto_thin_wall_max",
    "flat_planarity_threshold",
    "untouched_name_whitelist",
    # Appended last so legacy positional callers keep their argument positions.
    "clear_custom_normals",
    "clear_sharp_edges",
    "reapply_original_normals",
    "hole_loss_cap",
    "hole_loss_min_ratio",
]


def parse_bool(raw):
    return str(raw).lower() not in ("0", "false", "no", "off")


def normalize_option_name(raw_name):
    name = raw_name.lstrip("-").strip()
    return name.replace("-", "_")


def parse_typed_value(type_name, raw_value):
    if type_name == "bool":
        return parse_bool(raw_value)
    if type_name == "float":
        return float(raw_value)
    if type_name == "int":
        return int(raw_value)
    return str(raw_value)


def maybe_join_split_decimal(tokens, index, value_token):
    # Blender 5.1 may split named decimal values into two argv tokens,
    # e.g. -foo=0.025 arrives as ['-foo=0', '.025'].
    if (index + 1) >= len(tokens):
        return value_token, index
    nxt = tokens[index + 1]
    if isinstance(nxt, str) and nxt.startswith("."):
        head = str(value_token)
        if head.lstrip("+-").isdigit() and nxt[1:].isdigit():
            return head + nxt, index + 1
    return value_token, index


def try_parse_float(value):
    try:
        return float(value)
    except Exception:
        return None


def bool_to_int(value):
    return 1 if bool(value) else 0


def compact_float_token(value):
    token = f"{float(value):.3f}".rstrip("0").rstrip(".")
    return token.replace(".", "p") if token else "0"


def build_auto_output_path(input_usd, ratio, options):
    temp_dir = os.environ.get("TEMP") or os.path.dirname(input_usd) or "."
    stem = os.path.splitext(os.path.basename(input_usd))[0]
    parts = [
        stem,
        f"merge{str(options['merge_mode']).lower()}",
        f"remesh{bool_to_int(options['use_voxel_remesh'])}",
        f"vox{compact_float_token(options['voxel_size'])}",
        f"dec{int(round(float(ratio) * 100.0))}",
        str(options["decimate_mode"]).lower(),
        f"recalc{bool_to_int(options['recalc_after_process'])}",
    ]

    if bool(options["skip_multimaterial_remesh"]):
        parts.append("skipmultimat1")

    if int(options["min_faces_for_decimate"]) != 4:
        parts.append(f"minfaces{int(options['min_faces_for_decimate'])}")

    threshold = float(options.get("remesh_disconnected_threshold", 1.0))
    if threshold > 0.0:
        parts.append("rmdisc1")
        parts.append(f"rmdth{compact_float_token(threshold)}")

    thin_wall_safety = float(options.get("thin_wall_safety", 0.0))
    if thin_wall_safety > 0.0:
        parts.append(f"thinwall{compact_float_token(thin_wall_safety)}")

    if bool(options.get("remove_floaters", False)):
        parts.append("floaters1")

    if bool(options.get("per_submesh_auto", False)):
        parts.append("psa1")
        parts.append(f"ps{str(options.get('per_submesh_scope', 'damaged')).lower()}")
        parts.append(f"pscap{compact_float_token(options.get('per_submesh_error_cap', 0.01))}")
        if bool(options.get("auto_thin_wall", True)):
            parts.append("autotw1")

    filename = "_".join(parts) + ".usdc"
    return os.path.join(temp_dir, filename)


def print_help():
    print(HELP_TEXT)


def parse_args():
    argv = sys.argv

    if "-h" in argv or "--help" in argv:
        print_help()
        return {"mode": "help"}

    if "--" not in argv:
        raise RuntimeError(
            "Expected args after --: <input_usd> [output_usd] [ratio] [merge_mode] [use_voxel_remesh] [voxel_size] [decimate_mode] [dissolve_angle_deg] [recalc_after_process] [skip_multimaterial_remesh] [min_faces_for_decimate] [remesh_disconnected_threshold] [thin_wall_safety] [remove_floaters] [floater_min_face_ratio] [untouched_name_whitelist]"
        )
    args = argv[argv.index("--") + 1 :]

    # Split tokens into plain positional tokens and named overrides.
    # Supported named formats:
    #   -name=value
    #   --name=value
    #   -name value
    #   --name value
    positional = []
    named = {}
    i = 0
    while i < len(args):
        tok = args[i]
        if tok.startswith("-"):
            if "=" in tok:
                raw_name, raw_val = tok.split("=", 1)
                raw_val, i = maybe_join_split_decimal(args, i, raw_val)
                key = normalize_option_name(raw_name)
                named[key] = raw_val
                i += 1
                continue

            # Fallback for two-token style: -name value
            key = normalize_option_name(tok)
            if key in OPTION_SPECS and (i + 1) < len(args):
                raw_val = args[i + 1]
                raw_val, i2 = maybe_join_split_decimal(args, i + 1, raw_val)
                named[key] = raw_val
                i = i2 + 1
                continue

        positional.append(tok)
        i += 1

    if len(positional) < 1:
        raise RuntimeError(
            "Usage: blender -b --python script.py -- <input_usd> [output_usd] [ratio] "
            "[named overrides...]. Run with --help for the full option list."
        )

    input_usd = positional[0]
    output_usd = None
    ratio = DEFAULT_RATIO

    # Flexible head parsing:
    # - token #1 can be output path or ratio
    # - token #2 can be ratio when #1 was output path
    next_index = 1
    if len(positional) > 1:
        maybe = positional[1]
        maybe_ratio = try_parse_float(maybe)
        if maybe_ratio is not None:
            ratio = maybe_ratio
            next_index = 2
        else:
            output_usd = maybe
            next_index = 2
            if len(positional) > 2:
                maybe_ratio2 = try_parse_float(positional[2])
                if maybe_ratio2 is not None:
                    ratio = maybe_ratio2
                    next_index = 3

    # Start from defaults.
    options = {name: spec[1] for name, spec in OPTION_SPECS.items()}

    # Apply optional positional overrides (legacy behavior).
    for rel_idx, opt_name in enumerate(OPTIONAL_POSITIONAL_ORDER):
        idx = next_index + rel_idx
        if idx < len(positional):
            type_name = OPTION_SPECS[opt_name][0]
            options[opt_name] = parse_typed_value(type_name, positional[idx])

    # Apply named overrides.
    for key, raw_val in named.items():
        if key not in OPTION_SPECS:
            valid = ", ".join(sorted(OPTION_SPECS.keys()))
            raise RuntimeError(f"Unknown option '{key}'. Valid options: {valid}")
        type_name = OPTION_SPECS[key][0]
        options[key] = parse_typed_value(type_name, raw_val)

    merge_mode = str(options["merge_mode"]).lower()
    decimate_mode = str(options["decimate_mode"]).upper()

    # Auto-generate output path if omitted.
    if not output_usd:
        output_usd = build_auto_output_path(
            input_usd,
            ratio,
            {**options, "merge_mode": merge_mode, "decimate_mode": decimate_mode},
        )
    if decimate_mode not in ("COLLAPSE", "DISSOLVE"):
        raise RuntimeError("decimate_mode must be COLLAPSE or DISSOLVE")
    if merge_mode not in ("none", "all", "material"):
        raise RuntimeError("merge_mode must be none, all or material")
    if str(options["per_submesh_scope"]).lower() not in ("damaged", "all"):
        raise RuntimeError("per_submesh_scope must be damaged or all")

    result = {"mode": "process", "input_usd": input_usd, "output_usd": output_usd, "ratio": ratio}
    result.update(options)
    result["merge_mode"] = merge_mode
    result["decimate_mode"] = decimate_mode
    return result


def mesh_tri_count(obj):
    if obj.type != "MESH" or obj.data is None:
        return 0
    me = obj.data
    me.calc_loop_triangles()
    return len(me.loop_triangles)


def recalc_normals(obj, make_consistent=True, clear_custom_normals=False, clear_sharp_edges=False):
    """Optionally repair normals. Each step is independent and OFF by default except
    make_consistent, because clearing custom split normals / sharp edges is
    DESTRUCTIVE: authored normals and hard edges are usually intentional (they can
    make embossed relief such as a logo shade flat). By default we only fix face
    winding (make_consistent) and leave authored shading data alone. Meshes with
    custom split normals are skipped by make_consistent: flipping their winding
    inverts the authored normals (measured on Server_03's bezel: 99.8% of faces
    flipped 180 degrees). Set clear_custom_normals=1 to rebuild them."""
    me = obj.data
    has_custom_normals = me.has_custom_normals
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    if clear_sharp_edges:
        try:
            bpy.ops.mesh.mark_sharp(clear=True)
        except Exception:
            pass
    if clear_custom_normals:
        try:
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
            has_custom_normals = False
        except Exception:
            pass
    if make_consistent and not has_custom_normals:
        bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")

    me.update()
    obj.select_set(False)


def reapply_normals_from_source(dst_obj, source_mesh, mapping="POLYINTERP_NEAREST"):
    """Reapply the original shading onto a reduced mesh via a Data Transfer modifier:
    it copies split (custom) normals from the original (source_mesh) to dst_obj using
    a nearest-surface mapping in 3D. This restores authored/original normals even
    after voxel remesh, which rebuilds the topology and would otherwise discard them.
    The source is wrapped in a temporary object at dst_obj's world transform so the
    mapping lines up. Returns True on success. source_mesh is left intact."""
    src_obj = bpy.data.objects.new(dst_obj.name + "__nrm_src", source_mesh)
    src_obj.matrix_world = dst_obj.matrix_world.copy()
    bpy.context.scene.collection.objects.link(src_obj)
    mod = None
    try:
        # Pre-4.1 Blender needs auto-smooth on for custom split normals to take
        # effect; 4.1+ (incl. 5.1) always supports them and lacks this flag.
        if hasattr(dst_obj.data, "use_auto_smooth"):
            dst_obj.data.use_auto_smooth = True
        bpy.context.view_layer.objects.active = dst_obj
        dst_obj.select_set(True)
        mod = dst_obj.modifiers.new(name="NormalTransfer", type="DATA_TRANSFER")
        mod.object = src_obj
        mod.use_loop_data = True
        mod.data_types_loops = {"CUSTOM_NORMAL"}
        mod.loop_mapping = mapping
        bpy.ops.object.modifier_apply(modifier=mod.name)
        dst_obj.select_set(False)
        return True
    except Exception as ex:
        print(f"[decimate] Normal transfer failed on {dst_obj.name}: {ex}")
        try:
            if mod is not None and mod.name in [m.name for m in dst_obj.modifiers]:
                dst_obj.modifiers.remove(mod)
        except Exception:
            pass
        return False
    finally:
        try:
            bpy.data.objects.remove(src_obj, do_unlink=True)
        except Exception:
            pass


def merge_mesh_objects(meshes):
    if not meshes:
        return []

    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    return [joined] if joined and joined.type == "MESH" else []


def material_signature(obj):
    return tuple(
        (slot.material.name if slot.material else "") for slot in obj.material_slots
    )


def merge_mesh_objects_by_material(meshes):
    # Join only meshes that share the same material set, so face-material
    # separation (VertexSetup) is preserved while still cutting object count.
    if not meshes:
        return []

    groups = {}
    for obj in meshes:
        groups.setdefault(material_signature(obj), []).append(obj)

    result = []
    for objs in groups.values():
        if len(objs) == 1:
            result.append(objs[0])
            continue
        bpy.ops.object.select_all(action="DESELECT")
        for o in objs:
            o.select_set(True)
        bpy.context.view_layer.objects.active = objs[0]
        bpy.ops.object.join()
        joined = bpy.context.view_layer.objects.active
        if joined and joined.type == "MESH":
            result.append(joined)
    return result


def restore_original_mesh_data(obj, original_mesh):
    old_mesh = obj.data
    obj.data = original_mesh
    try:
        if old_mesh is not None and old_mesh != original_mesh:
            bpy.data.meshes.remove(old_mesh)
    except Exception:
        pass


def should_keep_processed_mesh(before_triangles, after_triangles, ratio_threshold=0.99):
    if before_triangles <= 0:
        return True
    if after_triangles > before_triangles:
        return False
    return after_triangles < int(math.floor(before_triangles * ratio_threshold))


def measure_min_wall_thickness(obj, sample_limit=1500, max_ray_dist=None):
    """Heuristically estimate minimum wall thickness by ray casting from sampled face centers
    along inverted normals. Returns (min_thickness_or_None, hit_ratio)."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    eval_obj = obj.evaluated_get(depsgraph)
    me = eval_obj.to_mesh()

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()

    if not bm.faces:
        bm.free()
        eval_obj.to_mesh_clear()
        return None, 0.0

    step = max(1, len(bm.faces) // sample_limit)
    hits = 0
    samples = 0
    min_thickness = None
    obj_inv = obj.matrix_world.inverted()
    obj_rot = obj.matrix_world.to_3x3()
    obj_rot_inv = obj_rot.inverted()

    for i, f in enumerate(bm.faces):
        if i % step != 0:
            continue
        samples += 1
        origin_world = obj.matrix_world @ (f.calc_center_median() - f.normal * 1e-5)
        direction_world = obj_rot @ (-f.normal)
        if direction_world.length_squared == 0.0:
            continue
        direction_world.normalize()

        hit, loc, normal, index = obj.ray_cast(
            obj_inv @ origin_world,
            obj_rot_inv @ direction_world,
            distance=max_ray_dist or 1e6,
        )
        if hit:
            hits += 1
            hit_world = obj.matrix_world @ loc
            dist = (hit_world - origin_world).length
            if min_thickness is None or dist < min_thickness:
                min_thickness = dist

    bm.free()
    eval_obj.to_mesh_clear()
    hit_ratio = (hits / samples) if samples else 0.0
    return min_thickness, hit_ratio


def apply_thin_wall_guard(obj, local_voxel_size, thin_wall_safety):
    """If thin_wall_safety > 0, try to preserve walls thinner than local_voxel_size * safety
    by applying a temporary Solidify modifier before voxel remesh."""
    if thin_wall_safety <= 0.0:
        return None

    required = local_voxel_size * thin_wall_safety
    min_thickness, hit_ratio = measure_min_wall_thickness(obj, max_ray_dist=local_voxel_size * 20.0)

    if min_thickness is None:
        return f"skip (no opposite surface found; likely open/non-manifold shell, required {required:.5f})"

    if min_thickness >= required:
        return f"ok (thickness {min_thickness:.5f} >= required {required:.5f}, hit_ratio {hit_ratio:.2f})"

    add_thickness = max(0.0, required - min_thickness)
    solidify = obj.modifiers.new(name="ThinWallGuardSolidify", type="SOLIDIFY")
    solidify.thickness = add_thickness
    solidify.offset = 0.0
    bpy.ops.object.modifier_apply(modifier=solidify.name)
    return f"solidified (+{add_thickness:.5f}, was {min_thickness:.5f}, target {required:.5f}, hit_ratio {hit_ratio:.2f})"


def apply_voxel_remesh(obj, voxel_size, remove_disconnected=False, disconnected_threshold=1.0):
    remesh = obj.modifiers.new(name="VoxelRemesh", type="REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = max(0.001, voxel_size)
    remesh.use_smooth_shade = True
    if hasattr(remesh, "use_remove_disconnected"):
        remesh.use_remove_disconnected = bool(remove_disconnected)
    if hasattr(remesh, "threshold"):
        remesh.threshold = max(0.0, float(disconnected_threshold))
    bpy.ops.object.modifier_apply(modifier=remesh.name)


def apply_decimate(obj, ratio, decimate_mode, dissolve_angle_deg):
    dec = obj.modifiers.new(name="DecimateAuto", type="DECIMATE")
    dec.decimate_type = decimate_mode
    if decimate_mode == "COLLAPSE":
        dec.ratio = ratio
        dec.use_collapse_triangulate = True
    else:
        dec.angle_limit = math.radians(max(0.01, dissolve_angle_deg))
        # Keep boundaries that usually carry material and shading information.
        dec.delimit = {"NORMAL", "MATERIAL", "SEAM", "SHARP", "UV"}
    bpy.ops.object.modifier_apply(modifier=dec.name)


def remove_floater_islands(obj, min_face_ratio):
    """Delete small disconnected mesh islands (floaters). Keeps the largest island
    and any island with at least min_face_ratio of the largest island's face count.
    Returns the number of removed islands."""
    if obj.data is None:
        return 0

    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()

    if not bm.faces:
        bm.free()
        return 0

    # Flood-fill faces into connected islands (BMFace is hashable).
    visited = set()
    islands = []
    for f in bm.faces:
        if f in visited:
            continue
        stack = [f]
        comp = []
        visited.add(f)
        while stack:
            cf = stack.pop()
            comp.append(cf)
            for e in cf.edges:
                for lf in e.link_faces:
                    if lf not in visited:
                        visited.add(lf)
                        stack.append(lf)
        islands.append(comp)

    if len(islands) <= 1:
        bm.free()
        return 0

    largest = max(len(c) for c in islands)
    threshold = max(1, int(min_face_ratio * largest))

    faces_to_delete = []
    removed_islands = 0
    for comp in islands:
        if len(comp) < threshold:
            faces_to_delete.extend(comp)
            removed_islands += 1

    if faces_to_delete:
        bmesh.ops.delete(bm, geom=faces_to_delete, context="FACES")
        bm.to_mesh(me)
        me.update()

    bm.free()
    return removed_islands


# ---------------------------------------------------------------------------
# Per-submesh adaptive strategy selection
# ---------------------------------------------------------------------------

def _percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    p = max(0.0, min(1.0, p))
    idx = p * (len(sorted_vals) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return float(sorted_vals[lo])
    t = idx - lo
    return sorted_vals[lo] * (1.0 - t) + sorted_vals[hi] * t


def mesh_world_bbox_diagonal(mesh, matrix_world):
    verts = mesh.vertices
    if not verts:
        return 0.0
    lo = [1e30, 1e30, 1e30]
    hi = [-1e30, -1e30, -1e30]
    for v in verts:
        co = matrix_world @ v.co
        for k in range(3):
            if co[k] < lo[k]:
                lo[k] = co[k]
            if co[k] > hi[k]:
                hi[k] = co[k]
    dx = hi[0] - lo[0]
    dy = hi[1] - lo[1]
    dz = hi[2] - lo[2]
    return math.sqrt(dx * dx + dy * dy + dz * dz)


def _world_verts(mesh, matrix_world, sample_limit):
    verts = mesh.vertices
    n = len(verts)
    if n == 0:
        return []
    step = max(1, n // sample_limit)
    return [matrix_world @ verts[i].co for i in range(0, n, step)]


def build_world_bvh_from_mesh(mesh, matrix_world):
    # BVHTree.FromBMesh copies geometry into the tree, so the bmesh can be freed.
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.transform(matrix_world)
    bvh = BVHTree.FromBMesh(bm)
    bm.free()
    return bvh


def mesh_planarity_ratio(mesh, sample_limit=6000, align_threshold=0.95):
    """Local (area-weighted) coplanarity in [0,1]: the fraction of interior-edge
    "surface area" where the two adjacent faces are nearly coplanar (dot >
    align_threshold, i.e. the edge is smooth rather than a hard crease).

    This measures whether the mesh is built from large, locally smooth regions —
    which is what makes COLLAPSE crumpling visible — NOT whether it lies in one
    global plane. A box-shaped chassis panel/shell scores high (only its few corner
    edges are creases); a cluster of screws/wires/connectors scores low. Meshes
    with no interior edges (or too few faces) are treated as flat (return 1.0)."""
    n_polys = len(mesh.polygons)
    if n_polys < 2:
        return 1.0

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.normal_update()
    bm.edges.ensure_lookup_table()
    edges = bm.edges
    n = len(edges)
    if n == 0:
        bm.free()
        return 1.0

    step = max(1, n // sample_limit)
    total_w = 0.0
    smooth_w = 0.0
    for i in range(0, n, step):
        e = edges[i]
        lf = e.link_faces
        if len(lf) != 2:
            continue
        f0, f1 = lf[0], lf[1]
        n0, n1 = f0.normal, f1.normal
        if n0.length_squared == 0.0 or n1.length_squared == 0.0:
            continue
        # Weight each edge by the area of the surface it joins, so large flat
        # regions dominate over small, densely-tessellated detail.
        w = f0.calc_area() + f1.calc_area()
        total_w += w
        if n0.dot(n1) > align_threshold:
            smooth_w += w
    bm.free()
    return (smooth_w / total_w) if total_w > 0.0 else 1.0


def mesh_boundary_length(mesh, matrix_world=None):
    """Total length of open boundary edges (hole rims, open sheet borders).
    Voxel remesh seals perforations without moving the surface much, so this is
    the cheap signal that surface-distance metrics miss. Pass matrix_world when
    comparing lengths across objects with different scales."""
    bm = bmesh.new()
    bm.from_mesh(mesh)
    if matrix_world is not None:
        bm.transform(matrix_world)
    total = 0.0
    for e in bm.edges:
        if len(e.link_faces) < 2:
            total += e.calc_length()
    bm.free()
    return total


def submesh_quality(orig_bvh, orig_world_verts, orig_diag, cand_mesh, cand_matrix,
                    sample_limit=2000, orig_boundary_len=0.0):
    """Compare a candidate mesh to the original and return a quality dict:
      surface  - symmetric 95th-pct distance / diagonal (overall geometric drift)
      forward  - candidate->original 95th-pct distance / diagonal (moved/added surface)
      backward - original->candidate 95th-pct distance / diagonal (missing surface = HOLES)
      boundary_loss - fraction of the original open-boundary length the candidate lost.
    Larger is worse for every field. Degenerate inputs return large sentinels.

    boundary_loss catches sealed perforations: the distance percentiles stay near
    zero because most sampled points still land on the (barely moved) plate.

    Note: the crumpled-panel COLLAPSE artefact is a smooth-shading effect that no
    cheap geometric distance/normal metric reliably separates from a clean
    reduction (verified by rendering). Flat-panel quality is therefore handled by
    POLICY in per_submesh_best_variant (route flat panels to voxel remesh, which
    renders clean, or leave them untouched) rather than by a shading score here."""
    bad = {"surface": 1e9, "forward": 1e9, "backward": 1e9, "boundary_loss": 1e9}
    if orig_diag <= 0.0:
        return bad
    cand_verts = _world_verts(cand_mesh, cand_matrix, sample_limit)
    if not cand_verts or not orig_world_verts:
        return bad

    cand_bvh = build_world_bvh_from_mesh(cand_mesh, cand_matrix)

    fwd = []
    for co in cand_verts:
        loc, nrm, idx, d = orig_bvh.find_nearest(co)
        if d is not None:
            fwd.append(d)
    bwd = []
    for co in orig_world_verts:
        loc, nrm, idx, d = cand_bvh.find_nearest(co)
        if d is not None:
            bwd.append(d)
    if not fwd or not bwd:
        return bad

    fwd.sort()
    bwd.sort()
    both = sorted(fwd + bwd)
    forward = _percentile(fwd, 0.95) / orig_diag
    backward = _percentile(bwd, 0.95) / orig_diag
    surface = _percentile(both, 0.95) / orig_diag

    boundary_loss = 0.0
    if orig_boundary_len > 0.0:
        cand_boundary_len = mesh_boundary_length(cand_mesh, cand_matrix)
        boundary_loss = max(0.0, (orig_boundary_len - cand_boundary_len) / orig_boundary_len)

    return {
        "surface": surface,
        "forward": forward,
        "backward": backward,
        "boundary_loss": boundary_loss,
    }


def _apply_variant_ops(obj, strat, cfg):
    bpy.context.view_layer.objects.active = obj
    if strat.get("remesh"):
        voxel = strat["voxel"]
        # A strategy may carry its own thin_wall override (auto-escalation);
        # otherwise fall back to the run-wide thin_wall_safety.
        thin_wall = strat.get("thin_wall", cfg["thin_wall_safety"])
        if thin_wall > 0.0:
            apply_thin_wall_guard(obj, voxel, thin_wall)
        apply_voxel_remesh(
            obj,
            voxel,
            remove_disconnected=cfg["remesh_disconnected_threshold"] > 0.0,
            disconnected_threshold=cfg["remesh_disconnected_threshold"],
        )
    ratio = strat.get("ratio")
    decimate_mode = strat.get("decimate_mode", "COLLAPSE")
    # DISSOLVE reduces by co-planar angle, not ratio, so it must still run even
    # when a strategy carries no ratio. COLLAPSE needs an explicit ratio.
    do_decimate = decimate_mode == "DISSOLVE" or ratio is not None
    if do_decimate and len(obj.data.polygons) >= cfg["min_faces_for_decimate"]:
        apply_decimate(obj, ratio if ratio is not None else 1.0, decimate_mode, cfg["dissolve_angle_deg"])
    if cfg["remove_floaters"]:
        remove_floater_islands(obj, cfg["floater_min_face_ratio"])


def _make_temp_object(src_obj, source_mesh):
    tmp = src_obj.copy()
    tmp.data = source_mesh.copy()
    tmp.modifiers.clear()
    tmp.name = src_obj.name + "__psa_try"
    bpy.context.scene.collection.objects.link(tmp)
    return tmp


def _remove_temp_object(tmp):
    mesh = tmp.data
    try:
        bpy.data.objects.remove(tmp, do_unlink=True)
    except Exception:
        pass
    try:
        if mesh is not None and mesh.users == 0:
            bpy.data.meshes.remove(mesh)
    except Exception:
        pass


def _eval_strategy(obj, original_mesh, strat, cfg, orig_bvh, orig_world_verts, orig_diag,
                   orig_boundary_len, sample_limit):
    """Apply one strategy to a fresh copy and measure it. Returns
    (quality_dict, faces, mesh_copy) or None on failure."""
    tmp = _make_temp_object(obj, original_mesh)
    try:
        _apply_variant_ops(tmp, strat, cfg)
        q = submesh_quality(
            orig_bvh, orig_world_verts, orig_diag, tmp.data, tmp.matrix_world, sample_limit,
            orig_boundary_len=orig_boundary_len,
        )
        return q, len(tmp.data.polygons), tmp.data.copy()
    finally:
        _remove_temp_object(tmp)


def _thin_wall_escalation_steps(auto_thin_wall_max):
    steps = [s for s in (1.1, 1.5, 2.0) if s <= float(auto_thin_wall_max) + 1e-6]
    if not steps:
        steps = [max(0.1, float(auto_thin_wall_max))]
    return steps


def per_submesh_best_variant(
    obj, original_mesh, base_voxel, base_ratio, cap, cfg,
    orig_bvh, orig_world_verts, orig_diag, orig_boundary_len=0.0, sample_limit=2000,
):
    """Pick the best reduction strategy for one object, driven by a flatness policy
    grounded in rendered ground truth:

      * Flat panels (planarity >= flat_planarity_threshold): COLLAPSE and DISSOLVE
        both shatter the smooth shading into a crumpled-foil pattern, while VOXEL
        REMESH reconstructs clean flat topology. So flat panels are routed to
        remesh only (with automatic thin-wall escalation to avoid holes). If no
        remesh variant is allowed (multi-material) or none reduces within the
        surface cap, the panel is left UNTOUCHED (full-res but artefact-free) --
        never crumpled by a collapse/dissolve fallback.
      * Other meshes: detailed/curved geometry hides collapse triangulation, so the
        usual remesh/collapse set is tried and gated on surface distance only.

    Every variant is gated by surface distance <= cap; flat-panel remesh variants
    must also actually reduce the face count. The most-reduced passing variant wins.

    Returns (mesh_datablock, strategy_name, quality_dict, face_count, thin_wall_used)."""
    multimat = len(obj.material_slots) > 1
    allow_remesh = not (cfg["skip_multimaterial_remesh"] and multimat)
    auto_thin_wall = bool(cfg.get("auto_thin_wall", True))
    auto_thin_wall_max = float(cfg.get("auto_thin_wall_max", 2.0))
    flat_threshold = float(cfg.get("flat_planarity_threshold", 0.85))
    orig_faces = len(original_mesh.polygons)

    planarity = mesh_planarity_ratio(original_mesh)
    is_flat = planarity >= flat_threshold

    remesh_strats = [
        ("remesh_coarse+collapse", {"remesh": True, "voxel": base_voxel * 1.8, "ratio": base_ratio * 0.7}),
        ("remesh+collapse", {"remesh": True, "voxel": base_voxel, "ratio": base_ratio}),
        ("remesh_fine+collapse", {"remesh": True, "voxel": base_voxel * 0.7, "ratio": base_ratio}),
    ]
    collapse_strat = ("collapse", {"remesh": False, "ratio": base_ratio})
    collapse_gentle_strat = ("collapse_gentle", {"remesh": False, "ratio": min(1.0, base_ratio * 1.4)})

    if is_flat:
        # Remesh is the only strategy that keeps a flat panel visually clean.
        strategies = list(remesh_strats) if allow_remesh else []
    else:
        strategies = (list(remesh_strats) if allow_remesh else []) + [collapse_strat, collapse_gentle_strat]

    hole_thresh = cap  # backward error above the surface cap == missing geometry
    hole_loss_cap = float(cfg.get("hole_loss_cap", 0.05))

    results = []  # (name, quality, faces, mesh_copy, thin_wall_used)
    for name, strat in strategies:
        try:
            evaluated = _eval_strategy(
                obj, original_mesh, strat, cfg, orig_bvh, orig_world_verts, orig_diag,
                orig_boundary_len, sample_limit,
            )
            if evaluated is None:
                continue
            q, faces, mesh_copy = evaluated
            thin_wall_used = 0.0

            # Auto thin-wall escalation: a remesh variant that opened holes is
            # re-tried with progressively thicker temporary walls.
            if (
                strat.get("remesh")
                and auto_thin_wall
                and cfg["thin_wall_safety"] <= 0.0
                and q.get("backward", 0.0) > hole_thresh
            ):
                for tw in _thin_wall_escalation_steps(auto_thin_wall_max):
                    guarded = dict(strat)
                    guarded["thin_wall"] = tw
                    retry = _eval_strategy(
                        obj, original_mesh, guarded, cfg,
                        orig_bvh, orig_world_verts, orig_diag, orig_boundary_len, sample_limit,
                    )
                    if retry is None:
                        continue
                    rq, rfaces, rmesh = retry
                    if rq.get("backward", 1e9) < q.get("backward", 1e9):
                        try:
                            bpy.data.meshes.remove(mesh_copy)
                        except Exception:
                            pass
                        q, faces, mesh_copy, thin_wall_used = rq, rfaces, rmesh, tw
                    else:
                        try:
                            bpy.data.meshes.remove(rmesh)
                        except Exception:
                            pass
                    if q.get("backward", 1e9) <= hole_thresh:
                        break

            results.append((name, q, faces, mesh_copy, thin_wall_used))
            tw_dbg = f" tw={thin_wall_used:.2f}" if thin_wall_used > 0.0 else ""
            print(
                f"[decimate]   PSA try {obj.name}/{name}: surface={q['surface']:.4f} "
                f"backward={q['backward']:.4f} hole_loss={q['boundary_loss']:.2%} "
                f"faces={faces} (flat={is_flat}){tw_dbg}"
            )
        except Exception as ex:
            print(f"[decimate]   PSA variant '{name}' failed on {obj.name}: {ex}")

    def passes(name, q, faces):
        if q.get("surface", 1e9) > cap:
            return False
        # Sealed perforations: a remesh can keep surface error near zero while
        # deleting every hole rim.
        if q.get("boundary_loss", 0.0) > hole_loss_cap:
            return False
        # A flat-panel remesh must genuinely reduce faces to be worth keeping;
        # a too-fine voxel can otherwise inflate a large panel past its original.
        if is_flat and faces >= orig_faces:
            return False
        return True

    passing = [r for r in results if passes(r[0], r[1], r[2])]
    chosen = min(passing, key=lambda r: r[2]) if passing else None
    chosen_mesh = chosen[3] if chosen else None

    for (name, q, faces, mesh, tw) in results:
        if mesh is not chosen_mesh:
            try:
                bpy.data.meshes.remove(mesh)
            except Exception:
                pass

    if chosen is None:
        untouched_q = {"surface": 0.0, "forward": 0.0, "backward": 0.0, "boundary_loss": 0.0}
        return original_mesh.copy(), "untouched", untouched_q, orig_faces, 0.0
    return chosen_mesh, chosen[0], chosen[1], chosen[2], chosen[4]


def main():
    parsed = parse_args()
    mode = parsed["mode"]

    if mode == "help":
        return

    input_usd = parsed["input_usd"]
    output_usd = parsed["output_usd"]
    ratio = parsed["ratio"]
    merge_mode = parsed["merge_mode"]
    use_voxel_remesh = parsed["use_voxel_remesh"]
    voxel_size = parsed["voxel_size"]
    decimate_mode = parsed["decimate_mode"]
    dissolve_angle_deg = parsed["dissolve_angle_deg"]
    recalc_after_process = parsed["recalc_after_process"]
    clear_custom_normals = parsed["clear_custom_normals"]
    clear_sharp_edges = parsed["clear_sharp_edges"]
    reapply_original_normals = parsed["reapply_original_normals"]
    skip_multimaterial_remesh = parsed["skip_multimaterial_remesh"]
    min_faces_for_decimate = parsed["min_faces_for_decimate"]
    remesh_disconnected_threshold = parsed["remesh_disconnected_threshold"]
    thin_wall_safety = parsed["thin_wall_safety"]
    remove_floaters = parsed["remove_floaters"]
    floater_min_face_ratio = parsed["floater_min_face_ratio"]
    per_submesh_auto = parsed["per_submesh_auto"]
    per_submesh_scope = str(parsed["per_submesh_scope"]).lower()
    per_submesh_error_cap = parsed["per_submesh_error_cap"]
    hole_loss_cap = parsed["hole_loss_cap"]
    hole_loss_min_ratio = parsed["hole_loss_min_ratio"]
    auto_thin_wall = parsed["auto_thin_wall"]
    auto_thin_wall_max = parsed["auto_thin_wall_max"]
    flat_planarity_threshold = parsed["flat_planarity_threshold"]
    untouched_name_whitelist_raw = str(parsed["untouched_name_whitelist"] or "")

    untouched_name_whitelist = [
        s.strip().lower()
        for s in untouched_name_whitelist_raw.replace(";", ",").split(",")
        if s.strip()
    ]

    if not os.path.exists(input_usd):
        raise FileNotFoundError(f"Input USD not found: {input_usd}")

    ratio = max(0.01, min(1.0, ratio))
    voxel_size = max(0.001, voxel_size)
    min_faces_for_decimate = max(0, min_faces_for_decimate)
    remesh_disconnected_threshold = max(0.0, float(remesh_disconnected_threshold))
    thin_wall_safety = max(0.0, float(thin_wall_safety))
    floater_min_face_ratio = max(0.0, min(1.0, float(floater_min_face_ratio)))
    per_submesh_error_cap = max(0.0, float(per_submesh_error_cap))
    hole_loss_cap = max(0.0, min(1.0, float(hole_loss_cap)))
    hole_loss_min_ratio = max(0.0, float(hole_loss_min_ratio))
    auto_thin_wall_max = max(0.0, float(auto_thin_wall_max))
    flat_planarity_threshold = max(0.0, min(1.0, float(flat_planarity_threshold)))

    bpy.ops.wm.read_factory_settings(use_empty=True)

    print(f"[decimate] Importing: {input_usd}")
    _t_import0 = time.time()
    bpy.ops.wm.usd_import(filepath=input_usd)
    _import_secs = time.time() - _t_import0
    _t_process0 = time.time()

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    print(f"[decimate] Mesh objects found: {len(meshes)}")
    print(
        f"[decimate] Options: ratio={ratio}, merge_mode={merge_mode}, "
        f"use_voxel_remesh={use_voxel_remesh}, voxel_size={voxel_size}, "
        f"decimate_mode={decimate_mode}, dissolve_angle_deg={dissolve_angle_deg}, "
        f"recalc_after_process={recalc_after_process}, "
        f"clear_custom_normals={clear_custom_normals}, "
        f"clear_sharp_edges={clear_sharp_edges}, "
        f"reapply_original_normals={reapply_original_normals}, "
        f"skip_multimaterial_remesh={skip_multimaterial_remesh}, "
        f"min_faces_for_decimate={min_faces_for_decimate}, "
        f"remesh_disconnected_threshold={remesh_disconnected_threshold}, "
        f"thin_wall_safety={thin_wall_safety}, "
        f"remove_floaters={remove_floaters}, "
        f"floater_min_face_ratio={floater_min_face_ratio}, "
        f"per_submesh_auto={per_submesh_auto}, "
        f"per_submesh_scope={per_submesh_scope}, "
        f"per_submesh_error_cap={per_submesh_error_cap}, "
        f"hole_loss_cap={hole_loss_cap}, "
        f"hole_loss_min_ratio={hole_loss_min_ratio}, "
        f"auto_thin_wall={auto_thin_wall}, "
        f"auto_thin_wall_max={auto_thin_wall_max}, "
        f"flat_planarity_threshold={flat_planarity_threshold}, "
        f"untouched_name_whitelist={untouched_name_whitelist}"
    )

    before = sum(mesh_tri_count(o) for o in meshes)
    print(f"[decimate] Triangles before: {before}")

    if merge_mode == "all":
        meshes = merge_mesh_objects(meshes)
        print(f"[decimate] Mesh objects after merge (all): {len(meshes)}")
    elif merge_mode == "material":
        meshes = merge_mesh_objects_by_material(meshes)
        print(f"[decimate] Mesh objects after merge (by material): {len(meshes)}")

    bpy.ops.object.select_all(action="DESELECT")
    processed = 0
    remesh_applied = 0
    remesh_skipped_multimat = 0
    remesh_skipped_whitelist = 0
    decimate_skipped_low_face = 0
    untouched_skipped = 0
    thin_wall_checked = 0
    thin_wall_solidified = 0
    floaters_cleaned = 0
    per_submesh_searched = 0
    per_submesh_reprocessed = 0
    per_submesh_untouched_fallback = 0
    per_submesh_flat_routed = 0
    per_submesh_hole_routed = 0
    per_submesh_thin_wall_auto = 0
    normals_reapplied = 0
    psa_records = []  # per-object diagnostics for the sidecar report

    psa_cfg = {
        "decimate_mode": decimate_mode,
        "dissolve_angle_deg": dissolve_angle_deg,
        "min_faces_for_decimate": min_faces_for_decimate,
        "thin_wall_safety": thin_wall_safety,
        "remesh_disconnected_threshold": remesh_disconnected_threshold,
        "remove_floaters": remove_floaters,
        "floater_min_face_ratio": floater_min_face_ratio,
        "skip_multimaterial_remesh": skip_multimaterial_remesh,
        "auto_thin_wall": auto_thin_wall,
        "auto_thin_wall_max": auto_thin_wall_max,
        "flat_planarity_threshold": flat_planarity_threshold,
        "hole_loss_cap": hole_loss_cap,
        "hole_loss_min_ratio": hole_loss_min_ratio,
    }

    for obj in meshes:
        if obj.data is None:
            continue

        # Check the whitelist before copying mesh data, otherwise the copy is
        # leaked (never assigned or removed) for every skipped object.
        if untouched_name_whitelist:
            lname = obj.name.lower()
            if any(token in lname for token in untouched_name_whitelist):
                untouched_skipped += 1
                remesh_skipped_whitelist += 1
                continue

        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        original_mesh = obj.data.copy()
        before_triangles = mesh_tri_count(obj)

        try:
            # In scope=all the per-submesh search replaces the global pass entirely.
            do_global_pass = not (per_submesh_auto and per_submesh_scope == "all")

            if do_global_pass:
                if use_voxel_remesh:
                    skip_remesh = False

                    if skip_multimaterial_remesh and len(obj.material_slots) > 1:
                        skip_remesh = True
                        remesh_skipped_multimat += 1

                    if not skip_remesh:
                        local_voxel = voxel_size

                        if thin_wall_safety > 0.0:
                            thin_wall_checked += 1
                            status = apply_thin_wall_guard(obj, local_voxel, thin_wall_safety)
                            print(
                                f"[decimate] Thin-wall guard on {obj.name}: {status} "
                                f"(local_voxel={local_voxel:.5f}, safety={thin_wall_safety:.3f})"
                            )
                            if status and status.startswith("solidified"):
                                thin_wall_solidified += 1

                        apply_voxel_remesh(
                            obj,
                            local_voxel,
                            remove_disconnected=remesh_disconnected_threshold > 0.0,
                            disconnected_threshold=remesh_disconnected_threshold,
                        )
                        remesh_applied += 1

                # Blender Decimate warns/fails on tiny meshes; skip those explicitly.
                face_count_now = len(obj.data.polygons) if obj.data is not None else 0
                if face_count_now >= min_faces_for_decimate:
                    apply_decimate(obj, ratio, decimate_mode, dissolve_angle_deg)
                else:
                    decimate_skipped_low_face += 1

                if remove_floaters:
                    removed = remove_floater_islands(obj, floater_min_face_ratio)
                    if removed > 0:
                        floaters_cleaned += removed
                        print(f"[decimate] Removed {removed} floater island(s) from {obj.name}")

                if recalc_after_process:
                    recalc_normals(
                        obj,
                        clear_custom_normals=clear_custom_normals,
                        clear_sharp_edges=clear_sharp_edges,
                    )
                if reapply_original_normals:
                    if reapply_normals_from_source(obj, original_mesh):
                        normals_reapplied += 1

            if per_submesh_auto:
                # Decide per object whether to re-search for a safer strategy.
                # Trigger when the global pass moved the surface too far (holes /
                # shape loss) OR the object is a flat panel -- flat panels are
                # routed to voxel remesh because COLLAPSE/DISSOLVE crumple their
                # shading (see per_submesh_best_variant), a defect surface distance
                # cannot see. scope=all always re-searches.
                orig_diag = mesh_world_bbox_diagonal(original_mesh, obj.matrix_world)
                orig_bvh = build_world_bvh_from_mesh(original_mesh, obj.matrix_world)
                orig_world_verts = _world_verts(original_mesh, obj.matrix_world, 2000)
                orig_boundary_len = mesh_boundary_length(original_mesh, obj.matrix_world)
                # A few tiny open rims on a big panel are not perforations worth
                # keeping at full resolution; only guard objects whose boundary is
                # large relative to their own size.
                if orig_diag > 0.0 and orig_boundary_len / orig_diag < hole_loss_min_ratio:
                    orig_boundary_len = 0.0
                per_submesh_searched += 1

                planarity = mesh_planarity_ratio(original_mesh)
                is_flat = planarity >= flat_planarity_threshold

                need_search = per_submesh_scope == "all"
                cur_q = None
                if not need_search:
                    cur_q = submesh_quality(
                        orig_bvh, orig_world_verts, orig_diag, obj.data, obj.matrix_world,
                        orig_boundary_len=orig_boundary_len,
                    )
                    over_surface = cur_q["surface"] > per_submesh_error_cap
                    over_holes = cur_q["boundary_loss"] > hole_loss_cap
                    need_search = over_surface or over_holes or is_flat
                    if is_flat:
                        per_submesh_flat_routed += 1
                    if over_holes:
                        per_submesh_hole_routed += 1

                if need_search:
                    win_mesh, win_name, win_q, win_faces, win_tw = per_submesh_best_variant(
                        obj, original_mesh, voxel_size, ratio, per_submesh_error_cap, psa_cfg,
                        orig_bvh, orig_world_verts, orig_diag, orig_boundary_len,
                    )
                    old = obj.data
                    obj.data = win_mesh
                    if old is not None and old is not original_mesh and old is not win_mesh:
                        try:
                            bpy.data.meshes.remove(old)
                        except Exception:
                            pass
                    per_submesh_reprocessed += 1
                    if win_name == "untouched":
                        per_submesh_untouched_fallback += 1
                    elif recalc_after_process and "remesh" not in win_name:
                        # Voxel-remesh output already has clean, consistent normals;
                        # re-running recalc on it can degrade them.
                        recalc_normals(
                            obj,
                            clear_custom_normals=clear_custom_normals,
                            clear_sharp_edges=clear_sharp_edges,
                        )
                    if reapply_original_normals and win_name != "untouched":
                        # Restore the original shading onto the reduced/remeshed mesh.
                        if reapply_normals_from_source(obj, original_mesh):
                            normals_reapplied += 1
                    if win_tw > 0.0:
                        per_submesh_thin_wall_auto += 1
                    if per_submesh_scope == "all":
                        reason = "scope=all"
                    else:
                        flags = []
                        if cur_q["surface"] > per_submesh_error_cap:
                            flags.append(f"surface {cur_q['surface']:.4f}>{per_submesh_error_cap:.4f}")
                        if cur_q["boundary_loss"] > hole_loss_cap:
                            flags.append(
                                f"holes {cur_q['boundary_loss']:.2%}>{hole_loss_cap:.0%}"
                            )
                        if is_flat:
                            flags.append(f"flat panel (planarity {planarity:.2f})")
                        reason = ", ".join(flags)
                    tw_txt = f", thinwall={win_tw:.2f}" if win_tw > 0.0 else ""
                    print(
                        f"[decimate] PSA {obj.name}: {reason} -> {win_name} "
                        f"(planarity={planarity:.2f}, surface={win_q['surface']:.4f}, "
                        f"backward={win_q['backward']:.4f}, hole_loss={win_q['boundary_loss']:.2%}, "
                        f"faces={win_faces}{tw_txt})"
                    )
                    psa_records.append({
                        "object": obj.name,
                        "strategy": win_name,
                        "planarity": round(planarity, 4),
                        "is_flat": is_flat,
                        "surface": round(win_q["surface"], 5),
                        "backward": round(win_q["backward"], 5),
                        "boundary_loss": round(win_q["boundary_loss"], 4),
                        "faces": win_faces,
                        "thin_wall": round(win_tw, 3),
                        "reason": "scope=all" if per_submesh_scope == "all" else reason,
                    })
                else:
                    print(
                        f"[decimate] PSA {obj.name}: ok "
                        f"(planarity={planarity:.2f}, flat={is_flat}, "
                        f"surface={cur_q['surface']:.4f} <= {per_submesh_error_cap:.4f})"
                    )
                    psa_records.append({
                        "object": obj.name,
                        "strategy": "global_pass_ok",
                        "planarity": round(planarity, 4),
                        "is_flat": is_flat,
                        "surface": round(cur_q["surface"], 5),
                        "backward": round(cur_q["backward"], 5),
                        "boundary_loss": round(cur_q["boundary_loss"], 4),
                        "faces": len(obj.data.polygons) if obj.data else 0,
                        "thin_wall": 0.0,
                        "reason": "within caps",
                    })

                try:
                    bpy.data.meshes.remove(original_mesh)
                except Exception:
                    pass
                processed += 1
            else:
                processed += 1
                after_triangles = mesh_tri_count(obj)
                if not should_keep_processed_mesh(before_triangles, after_triangles, ratio_threshold=0.99):
                    print(
                        f"[decimate] Restoring original mesh for {obj.name}: "
                        f"after={after_triangles}, before={before_triangles}"
                    )
                    restore_original_mesh_data(obj, original_mesh)
                else:
                    try:
                        bpy.data.meshes.remove(original_mesh)
                    except Exception:
                        pass
        except Exception as ex:
            print(f"[decimate] Failed on {obj.name}: {ex}")
            try:
                bpy.ops.object.mode_set(mode="OBJECT")
            except Exception:
                pass
            try:
                restore_original_mesh_data(obj, original_mesh)
            except Exception:
                pass
            obj.select_set(False)

    meshes_after = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    after = sum(mesh_tri_count(o) for o in meshes_after)
    print(f"[decimate] Processed mesh objects: {processed}")
    if reapply_original_normals:
        print(f"[decimate] Original normals reapplied (data transfer): {normals_reapplied}")
    if use_voxel_remesh:
        print(f"[decimate] Remesh applied: {remesh_applied}")
        print(f"[decimate] Remesh skipped (multi-material): {remesh_skipped_multimat}")
        print(f"[decimate] Remesh skipped (whitelist): {remesh_skipped_whitelist}")
        if thin_wall_safety > 0.0:
            print(f"[decimate] Thin-wall guard checked: {thin_wall_checked}")
            print(f"[decimate] Thin-wall guard solidified: {thin_wall_solidified}")
    if remove_floaters:
        print(f"[decimate] Floater islands removed: {floaters_cleaned}")
    if per_submesh_auto:
        print(f"[decimate] Per-submesh searched: {per_submesh_searched}")
        print(f"[decimate] Per-submesh re-processed: {per_submesh_reprocessed}")
        print(f"[decimate] Per-submesh flat panels routed to remesh: {per_submesh_flat_routed}")
        print(f"[decimate] Per-submesh hole-loss re-searched: {per_submesh_hole_routed}")
        print(f"[decimate] Per-submesh thin-wall auto-applied: {per_submesh_thin_wall_auto}")
        print(f"[decimate] Per-submesh untouched fallback: {per_submesh_untouched_fallback}")
    print(f"[decimate] Objects skipped by whitelist: {untouched_skipped}")
    print(f"[decimate] Decimate skipped (low-face mesh): {decimate_skipped_low_face}")
    print(f"[decimate] Mesh objects after processing: {len(meshes_after)}")
    print(f"[decimate] Triangles after: {after}")

    out_dir = os.path.dirname(output_usd)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    # Write a compact per-submesh diagnostics sidecar so the host tool / HTML
    # report can surface which objects switched strategy or were thin-wall guarded.
    if per_submesh_auto and psa_records:
        strategy_counts = {}
        for rec in psa_records:
            strategy_counts[rec["strategy"]] = strategy_counts.get(rec["strategy"], 0) + 1
        psa_sidecar = {
            "input_usd": input_usd,
            "output_usd": output_usd,
            "per_submesh_scope": per_submesh_scope,
            "per_submesh_error_cap": per_submesh_error_cap,
            "hole_loss_cap": hole_loss_cap,
            "hole_loss_min_ratio": hole_loss_min_ratio,
            "auto_thin_wall": bool(auto_thin_wall),
            "counters": {
                "searched": per_submesh_searched,
                "reprocessed": per_submesh_reprocessed,
                "flat_routed": per_submesh_flat_routed,
                "hole_routed": per_submesh_hole_routed,
                "thin_wall_auto": per_submesh_thin_wall_auto,
                "untouched_fallback": per_submesh_untouched_fallback,
            },
            "strategy_counts": strategy_counts,
            "objects": psa_records,
        }
        sidecar_path = os.path.splitext(output_usd)[0] + ".psa.json"
        try:
            import json as _json
            with open(sidecar_path, "w", encoding="utf-8") as f:
                _json.dump(psa_sidecar, f, indent=2)
            print(f"[decimate] PSA diagnostics: {sidecar_path}")
        except Exception as ex:
            print(f"[decimate] PSA diagnostics write failed: {ex}")

    _process_secs = time.time() - _t_process0
    print(f"[decimate] Exporting: {output_usd}")
    _t_export0 = time.time()
    bpy.ops.wm.usd_export(filepath=output_usd)
    _export_secs = time.time() - _t_export0
    print(
        f"[decimate] Timings: import {_import_secs:.1f}s · "
        f"process {_process_secs:.1f}s · export {_export_secs:.1f}s "
        f"(total {_import_secs + _process_secs + _export_secs:.1f}s)"
    )
    print("[decimate] Done")


if __name__ == "__main__":
    main()
