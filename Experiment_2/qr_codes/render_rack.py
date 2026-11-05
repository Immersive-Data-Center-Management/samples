#!/usr/bin/env python3
"""Renders rack_01.jpg: DemoRack01 with a QR sticker on the front of every part.

Open it on a monitor and zoom in (or print it large), then scan the stickers with the phone,
as if standing in front of the real rack. The rack and parts are the same USD models the app
shows (shared/deploy/assets), placed the way RackComponents places them. Slots and shell ids
come from shared/deploy/seed/seed.py, so the image cannot drift from the demo data.

    pip install "qrcode[pil]==8.2"
    python render_rack.py

Step 1 (this Python) makes one sticker PNG per part. Step 2 runs Blender 5.2 on this same file
to compose and render the rack (set BLENDER if it is not in the default install path).
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ASSETS = ROOT / "shared" / "deploy" / "assets"
STICKERS = Path(tempfile.gettempdir()) / "idtx_rack_stickers"
OUT = HERE / "rack_01.jpg"
BLENDER = os.environ.get("BLENDER", r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe")

U = 0.04445          # one rack unit in metres (RackComponents)
SLOT_0_Z = 0.098     # slot 0 above the rack's feet (RackComponents.RACK_SLOT_0_Z_M)
STICKER_W, STICKER_H = 900, 300  # px: QR on the left, name on the right, like an asset label


def rack_parts():
    """(label, shell id, model file, height in U, lowest slot) of DemoRack01's components."""
    sys.path.insert(0, str(ROOT / "shared" / "deploy" / "seed"))
    import seed
    rack = next(r for r in seed.RACKS if r["slug"] == "rack-01")
    return [(c["label"], f"urn:apeirora.eu:aas:demo:{c['slug']}", c["model"], c["height"], c["position"])
            for c in rack["components"]]


def make_stickers():
    import qrcode
    from PIL import Image, ImageDraw, ImageFont

    def font(size):
        for name in ("arialbd.ttf", "arial.ttf", "DejaVuSans-Bold.ttf", "Helvetica.ttc"):
            try:
                return ImageFont.truetype(name, size)
            except OSError:
                pass
        return ImageFont.load_default()

    STICKERS.mkdir(exist_ok=True)
    for label, shell_id, *_ in rack_parts():
        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2, box_size=10)
        qr.add_data(shell_id)
        qr.make(fit=True)
        code = qr.make_image(fill_color="black", back_color="white").convert("RGB")
        code = code.resize((STICKER_H, STICKER_H), Image.NEAREST)
        img = Image.new("RGB", (STICKER_W, STICKER_H), "white")
        img.paste(code, (0, 0))
        draw = ImageDraw.Draw(img)
        draw.text((STICKER_H + 20, STICKER_H // 2 - 30), label, fill="black", font=font(64), anchor="lm")
        draw.text((STICKER_H + 20, STICKER_H // 2 + 45), "Asset tag · scan me", fill="#555555", font=font(36), anchor="lm")
        img.save(STICKERS / f"{label}.png")


# --- Step 2, inside Blender --------------------------------------------------------------------

def blender_main():
    import bpy
    from mathutils import Vector

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    def import_usd(path):
        before = set(bpy.data.objects)
        bpy.ops.wm.usd_import(filepath=str(path), import_cameras=False, import_lights=False)
        new = [o for o in bpy.data.objects if o not in before]
        tops = [o for o in new if o.parent not in new]
        return tops, [o for o in new if o.type == "MESH"]

    import_usd(ASSETS / "ServerRack.usdc")
    top_slot = 0
    for label, _, model, height, position in rack_parts():
        z = SLOT_0_Z + position * U
        tops, meshes = import_usd(ASSETS / model)
        for o in tops:
            o.location.z += z
        bpy.context.view_layer.update()
        front_y = min((o.matrix_world @ Vector(c)).y for o in meshes for c in o.bound_box)
        # 1U parts get a slim label that fits the faceplate, taller parts a bigger one.
        _sticker(label, front_y - 0.002, z + height * U / 2, min(0.034, height * U * 0.75) if height == 1 else 0.06)
        top_slot = max(top_slot, position + height)

    # Soft front light, neutral background, straight-on orthographic view of the used slots.
    bpy.ops.object.light_add(type="AREA", location=(0, -2.5, 0.6))
    light = bpy.context.object
    light.data.energy, light.data.size = 15, 3
    light.rotation_euler = (1.5708, 0, 0)
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.09, 0.1, 0.11, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
    scene.world = world

    view_bottom, view_top = 0.0, SLOT_0_Z + (top_slot + 2) * U
    bpy.ops.object.camera_add(location=(0, -3, (view_bottom + view_top) / 2), rotation=(1.5708, 0, 0))
    cam = bpy.context.object
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = view_top - view_bottom
    scene.camera = cam

    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_y = 6000
    scene.render.resolution_x = int(6000 * 0.75 / (view_top - view_bottom))
    scene.view_settings.view_transform = "Standard"
    # JPEG at quality 95 keeps every sticker scannable at a tenth of the PNG size.
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.quality = 95
    scene.render.filepath = str(OUT)
    bpy.ops.render.render(write_still=True)


def _sticker(label, y, z, height):
    import bpy
    mat = bpy.data.materials.new(f"Sticker_{label}")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(str(STICKERS / f"{label}.png"))
    tex.interpolation = "Closest"
    emit = nodes.new("ShaderNodeEmission")  # unlit, so the code keeps full contrast
    mat.node_tree.links.new(tex.outputs["Color"], emit.inputs["Color"])
    mat.node_tree.links.new(emit.outputs["Emission"], nodes["Material Output"].inputs["Surface"])
    width = height * STICKER_W / STICKER_H
    # Right half of the faceplate, like an asset label.
    bpy.ops.mesh.primitive_plane_add(size=1, location=(0.2 - width / 2, y, z), rotation=(1.5708, 0, 0))
    plane = bpy.context.object
    plane.scale = (width, height, 1)
    plane.data.materials.append(mat)


if __name__ == "__main__":
    if "bpy" in sys.modules:
        blender_main()
    else:
        make_stickers()
        subprocess.run([BLENDER, "--background", "--python", __file__], check=True)
        print(f"wrote {OUT}")
