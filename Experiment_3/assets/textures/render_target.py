"""Renders image-16.png, the AR image target: the Experiment 3 rack seen straight from the front.

The rack and its parts are the same USD models the AR view places on top of the target, at the
heights set in scenes/ar_view_state.tscn (read from there, so the image cannot drift from the
scene). The framing matches the ImageTrackedComponent: the rack's front is the image plane and
the image covers exactly physical_width, so the 3D models land on their printed counterparts.

    & "C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe" --background --factory-startup --python render_target.py
"""

import re
from pathlib import Path

import bpy

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
SCENE = PROJECT / "scenes" / "ar_view_state.tscn"
OUT = HERE / "image-16.png"
WIDTH_PX, HEIGHT_PX = 1152, 2048  # 9:16 like before: the scene's 0.17 m width keeps its height

# Image centre in rack (USD) coordinates and the image width in rack metres. They follow from the
# scene: PositionHelper scales the rack by 0.137 and offsets it so that the image centre is 0.96 m
# above the rack's feet; 0.17 m printed width / 0.137 = 1.241 m of rack.
CENTER_X, CENTER_Z = -0.0045, 0.9616
VIEW_WIDTH = 0.17 / 0.137


def parts():
    """(model file, height above the rack's feet in metres) of each part in the AR scene."""
    text = SCENE.read_text(encoding="utf-8")
    found = re.findall(r'stage_uri = "res://assets/usd/Rack/([^"]+)"\ntransform = Transform3D\(([^)]*)\)', text)
    return [(model, float(values.split(",")[10])) for model, values in found if model != "ServerRack.usdc"]


def import_usd(path, z=0.0):
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=str(path), import_cameras=False, import_lights=False)
    new = [o for o in bpy.data.objects if o not in before]
    for o in new:
        if o.parent not in new:
            o.location.z += z


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    models = PROJECT / "assets" / "usd" / "Rack"
    import_usd(models / "ServerRack.usdc")
    for model, z in parts():
        import_usd(models / model, z)

    # Soft front light and a light grey background, so the dark rack has clear edges to track.
    bpy.ops.object.light_add(type="AREA", location=(0, -2.5, 1.2))
    light = bpy.context.object
    light.data.energy, light.data.size = 40, 3
    light.rotation_euler = (1.5708, 0, 0)
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.58, 0.62, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.8
    scene.world = world

    bpy.ops.object.camera_add(location=(CENTER_X, -3, CENTER_Z), rotation=(1.5708, 0, 0))
    cam = bpy.context.object
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = VIEW_WIDTH * HEIGHT_PX / WIDTH_PX  # ortho_scale is the longer side
    scene.camera = cam

    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = WIDTH_PX, HEIGHT_PX
    scene.view_settings.view_transform = "Standard"
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(OUT)
    bpy.ops.render.render(write_still=True)


main()
