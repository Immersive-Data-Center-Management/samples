# SPDX-FileCopyrightText: 2026 SAP SE or an SAP affiliate company and samples contributors
# SPDX-License-Identifier: Apache-2.0
"""Builds the sample data-center models in Blender 5.2 LTS and exports them to ../*.usdc:
  blender --background --python build_assets.py

Contract shared with the AAS seed and RackComponents: metres, Z up, front faces -Y, origin at the
bottom centre of the part's lowest U slot, 19" width (0.48 m incl. ears), depth 0.80 m.
Each model is a root empty with a few meshes: the chassis, one merged "details" mesh and a
separate "StatusLed" (its colour can later show the AAS status). Port link LEDs are off: no cables.
"""
import math
import os

import bmesh
import bpy
from mathutils import Matrix
from pxr import Gf, Sdf, Usd, UsdGeom

U = 0.04445          # one rack unit in metres
WIDTH = 0.44         # chassis width between the rack ears
DEPTH = 0.78
EAR = 0.02           # rack ear width each side -> 0.48 m overall
SLOT_0_Z = 0.098     # rack slot 0 above the floor (plinth + feet); RackComponents.RACK_SLOT_0_Z_M
BACK = DEPTH / 2     # rear face of the chassis

_mats = {}


def mat(name, color, metallic=0.0, roughness=0.5, emission=None):
    """Plain Principled material, exports to UsdPreviewSurface."""
    if name in _mats:
        return _mats[name]
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)  # reuse on rebuild: no ".001" names
    m.use_nodes = True
    nodes = m.node_tree.nodes
    nodes.clear()  # also resets a same-named material from an imported reference
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    out = nodes.new("ShaderNodeOutputMaterial")
    m.node_tree.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 4.0
    _mats[name] = m
    return m


def palette():
    return {
        "chassis": mat("Chassis", (0.32, 0.34, 0.37), metallic=0.8, roughness=0.35),
        "chassis_dark": mat("ChassisDark", (0.045, 0.047, 0.052), metallic=0.5, roughness=0.5),
        "bezel": mat("Bezel", (0.07, 0.075, 0.085), roughness=0.6),
        "carrier": mat("Carrier", (0.13, 0.135, 0.145), roughness=0.55),
        "plastic": mat("Plastic", (0.03, 0.03, 0.035), roughness=0.6),
        "cutout": mat("Cutout", (0.01, 0.01, 0.012), roughness=0.9),
        "trim": mat("Trim", (0.55, 0.57, 0.6), metallic=0.9, roughness=0.3),
        "label": mat("Label", (0.85, 0.86, 0.86), roughness=0.6),
        "tab": mat("PullTab", (0.1, 0.3, 0.75), roughness=0.5),
        "gold": mat("Contacts", (0.83, 0.62, 0.22), metallic=1.0, roughness=0.25),
        "led_ok": mat("StatusLed", (0.05, 0.6, 0.2), emission=(0.1, 1.0, 0.3)),
        "link": mat("LinkLed", (0.05, 0.6, 0.2), emission=(0.1, 1.0, 0.3)),
        "led_off": mat("LedOff", (0.03, 0.05, 0.03), roughness=0.4),
        "screen": mat("Screen", (0.02, 0.05, 0.08), roughness=0.2),
        "segment": mat("Segment", (0.4, 0.9, 1.0), emission=(0.4, 0.9, 1.0)),
        "frame": mat("RackFrame", (0.06, 0.065, 0.075), metallic=0.6, roughness=0.45),
        "panel": mat("RackPanel", (0.09, 0.095, 0.105), metallic=0.5, roughness=0.55),
    }


# --- Objects (only for the few big parts that get a bevel) ---

def box(name, size, center, material, parent, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=center)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    o.data.materials.append(material)
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = 2
        b.limit_method = "ANGLE"
    o.parent = parent
    return o


def root(name):
    o = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(o)
    return o


def status_led(p, r, x, face, z):
    """The device status LED, a separate mesh so the app can recolour it."""
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.0025, depth=0.004, location=(x, face - 0.002, z), rotation=(math.pi / 2, 0, 0))
    o = bpy.context.active_object
    o.name = "StatusLed"
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    o.data.materials.append(p["led_ok"])
    o.parent = r
    return o


# --- Merged detail mesh ---

class MeshBuilder:
    """Collects many small parts into one mesh: one object instead of hundreds."""

    def __init__(self):
        self.bm = bmesh.new()
        self.materials = []

    def _assign(self, verts, material):
        if material not in self.materials:
            self.materials.append(material)
        index = self.materials.index(material)
        for face in {f for v in verts for f in v.link_faces}:
            face.material_index = index

    def box(self, size, center, material, spin=0.0):
        """Axis-aligned box; [param spin] turns it in the front plane (around Y), e.g. for printed strokes."""
        matrix = Matrix.Translation(center) @ Matrix.Rotation(spin, 4, "Y") @ Matrix.Diagonal((*size, 1.0))
        self._assign(bmesh.ops.create_cube(self.bm, size=1.0, matrix=matrix)["verts"], material)

    def front(self, w, h, x, z, face, d, material):
        """A box of w x h standing d out of a front surface at y = [param face]."""
        self.box((w, d, h), (x, face - d / 2, z), material)

    def back(self, w, h, x, z, face, d, material):
        """Same on a rear surface (sticks out towards +Y)."""
        self.box((w, d, h), (x, face + d / 2, z), material)

    def cyl(self, radius, depth, center, material, verts=16, axis="Y", spin=0.0):
        turn = {"Y": Matrix.Rotation(math.pi / 2, 4, "X"), "X": Matrix.Rotation(math.pi / 2, 4, "Y"), "Z": Matrix.Identity(4)}[axis]
        matrix = Matrix.Translation(center) @ Matrix.Rotation(spin, 4, axis) @ turn
        geom = bmesh.ops.create_cone(self.bm, cap_ends=True, segments=verts, radius1=radius, radius2=radius, depth=depth, matrix=matrix)
        self._assign(geom["verts"], material)

    def finish(self, name, parent):
        mesh = bpy.data.meshes.new(name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        for m in self.materials:
            mesh.materials.append(m)
        o = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(o)
        o.parent = parent
        return o


# --- Connectors and front parts (f = -1 on the front, +1 on the back) ---

def rj45(mb, p, x, z, face_y, latch_up, f=-1):
    """RJ45 jack centred at (x, z): metal shield around an opening with the latch notch, dark
    cavity, contact tongue with gold pins opposite the notch, link LED (off: no cable)."""
    w, h, notch_w, notch_h, t, d = 0.0100, 0.0066, 0.0050, 0.0018, 0.0009, 0.0035
    s = 1 if latch_up else -1
    outer_h = h + notch_h + 2 * t
    edge = z - s * outer_h / 2              # outer edge on the contact (non-latch) side
    y = face_y + f * d / 2
    for side in (-1, 1):
        mb.box((t, d, outer_h), (x + side * (w / 2 + t / 2), y, z), p["trim"])
    mb.box((w, d, t), (x, y, edge + s * t / 2), p["trim"])
    top = edge + s * (t + h)                # where the opening narrows to the notch
    shoulder = (w - notch_w) / 2
    for side in (-1, 1):
        mb.box((shoulder, d, notch_h + t), (x + side * (notch_w / 2 + shoulder / 2), y, top + s * (notch_h + t) / 2), p["trim"])
    mb.box((notch_w, d, t), (x, y, top + s * (notch_h + t / 2)), p["trim"])
    mb.box((w, 0.0006, h + notch_h), (x, face_y + f * 0.0003, z), p["cutout"])
    mb.box((0.0080, 0.0020, 0.0016), (x, face_y + f * 0.0016, edge + s * (t + 0.0008)), p["bezel"])
    mb.box((0.0062, 0.0016, 0.0003), (x, face_y + f * 0.0016, edge + s * (t + 0.0017)), p["gold"])
    mb.box((0.0018, 0.0006, 0.0010), (x - w / 2 + 0.0012, face_y + f * 0.0003, z + s * (outer_h / 2 + 0.0009)), p["led_off"])


def sfp(mb, p, x, z, face_y, module, f=-1):
    """SFP+ cage; with [param module] an inserted transceiver with its pull tab."""
    w, h, t, d = 0.0135, 0.0088, 0.0006, 0.0045
    y = face_y + f * d / 2
    for side in (-1, 1):
        mb.box((t, d, h + 2 * t), (x + side * (w / 2 + t / 2), y, z), p["trim"])
        mb.box((w, d, t), (x, y, z + side * (h / 2 + t / 2)), p["trim"])
    mb.box((w, 0.0006, h), (x, face_y + f * 0.0003, z), p["cutout"])
    if module:
        mb.box((w - 0.0012, 0.010, h - 0.0012), (x, face_y + f * 0.005, z), p["chassis"])
        mb.box((w - 0.004, 0.006, 0.0015), (x, face_y + f * 0.012, z - h / 2 + 0.002), p["tab"])


def usb(mb, p, x, z, face_y, f=-1):
    """USB-A: metal shell, dark opening, blue (USB 3) tongue."""
    mb.box((0.0125, 0.0030, 0.0055), (x, face_y + f * 0.0015, z), p["trim"])
    mb.box((0.0112, 0.0004, 0.0044), (x, face_y + f * 0.0032, z), p["cutout"])
    mb.box((0.0098, 0.0008, 0.0016), (x, face_y + f * 0.0036, z - 0.0008), p["tab"])


def vga(mb, p, x, z, face_y, f=-1):
    mb.box((0.0175, 0.0020, 0.0085), (x, face_y + f * 0.0010, z), p["trim"])
    mb.box((0.0135, 0.0004, 0.0050), (x, face_y + f * 0.0022, z), p["tab"])
    for side in (-1, 1):
        mb.cyl(0.0015, 0.0020, (x + side * 0.0125, face_y + f * 0.0010, z), p["trim"], verts=8)


SEGMENTS = {"0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg", "5": "acdfg",
            "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg"}


def seg_text(mb, p, text, cx, z, face_y, dw, dh):
    """Seven-segment digits, e.g. a current reading on a power display."""
    t = dh * 0.12
    pitch = dw * 1.5
    digits = [c for c in text if c != "."]
    x = cx - (len(digits) - 1) * pitch / 2
    spots = {"a": (0, dh / 2, 1), "g": (0, 0, 1), "d": (0, -dh / 2, 1),
             "b": (dw / 2, dh / 4, 0), "c": (dw / 2, -dh / 4, 0), "e": (-dw / 2, -dh / 4, 0), "f": (-dw / 2, dh / 4, 0)}
    for ch in text:
        if ch == ".":
            mb.front(t, t, x - pitch / 2, z - dh / 2, face_y, 0.0003, p["segment"])
            continue
        for s in SEGMENTS[ch]:
            sx, sz, horizontal = spots[s]
            size = (dw - t, t) if horizontal else (t, dh / 2 - t)
            mb.front(size[0], size[1], x + sx, z + sz, face_y, 0.0003, p["segment"])
        x += pitch


def honeycomb(mb, p, width, height, front_y, center_z, radius):
    """Recessed hexagons across a bezel."""
    dx = radius * math.sqrt(3) * 1.05
    dz = radius * 1.5 * 1.05
    rows, cols = int(height / dz), int(width / dx)
    z0 = center_z - (rows - 1) * dz / 2
    for r in range(rows):
        shift = dx / 2 if r % 2 else 0.0
        for c in range(cols - (1 if r % 2 else 0)):
            x = -(cols - 1) * dx / 2 + c * dx + shift
            mb.cyl(radius * 0.9, 0.004, (x, front_y - 0.001, z0 + r * dz), p["cutout"], verts=6, spin=math.pi / 6)


def drive_sff(mb, p, x, z, face, w, h):
    """2.5" drive carrier: vent slots, activity (on) + fault (off) LED, handle, release latch."""
    mb.front(w, h, x, z, face, 0.002, p["carrier"])
    f2 = face - 0.002
    top = z + h / 2
    for k in range(5):
        mb.front(w - 0.012, 0.0018, x - 0.003, top - 0.005 - k * 0.0035, f2, 0.0004, p["cutout"])
    mb.front(0.003, 0.003, x + w / 2 - 0.004, top - 0.0045, f2, 0.0004, p["link"])
    mb.front(0.003, 0.003, x + w / 2 - 0.004, top - 0.0090, f2, 0.0004, p["led_off"])
    mb.front(w - 0.006, 0.0045, x, z - h / 2 + 0.0045, f2, 0.0025, p["trim"])
    mb.front(0.006, 0.003, x - w / 2 + 0.006, z - h / 2 + 0.011, f2, 0.0008, p["tab"])


def drive_lff(mb, p, x, z, face, w, h):
    """3.5" drive carrier: perforated window, LEDs, label, handle with blue latch."""
    mb.front(w, h, x, z, face, 0.002, p["carrier"])
    f2 = face - 0.002
    for r in range(2):
        for c in range(5):
            mb.front(0.006, 0.006, x - w / 2 + 0.009 + c * 0.0085, z + h / 2 - 0.007 - r * 0.0085, f2, 0.0004, p["cutout"])
    mb.front(0.003, 0.003, x + w / 2 - 0.005, z + h / 2 - 0.005, f2, 0.0004, p["link"])
    mb.front(0.003, 0.003, x + w / 2 - 0.005, z + h / 2 - 0.010, f2, 0.0004, p["led_off"])
    mb.front(w - 0.008, 0.007, x, z - h / 2 + 0.0055, f2, 0.003, p["trim"])
    mb.front(0.008, 0.004, x + w / 2 - 0.009, z - h / 2 + 0.0135, f2, 0.001, p["tab"])
    mb.front(0.016, 0.004, x - w / 2 + 0.012, z - h / 2 + 0.0135, f2, 0.0003, p["label"])


# --- Shared chassis and rear panels ---

def chassis(p, r, units, body="chassis"):
    """19" body with rack ears (screws, pull handles), side vents and a top cover seam.
    Returns (height, front_y, MeshBuilder for the details)."""
    h = units * U
    front = -DEPTH / 2
    box("chassis", (WIDTH, DEPTH, h - 0.002), (0, 0, h / 2), p[body], r, bevel=0.002)
    mb = MeshBuilder()
    hh = min(h * 0.6, 0.06)
    for side in (-1, 1):
        x = side * (WIDTH / 2 + EAR / 2)
        mb.box((EAR, 0.004, h - 0.001), (x, front - 0.002, h / 2), p[body])
        hx = x + side * 0.004
        mb.box((0.006, 0.004, hh), (hx, front - 0.014, h / 2), p["trim"])
        for e in (-1, 1):
            mb.box((0.006, 0.010, 0.004), (hx, front - 0.009, h / 2 + e * (hh / 2 - 0.002)), p["trim"])
        for k in range(units):
            mb.cyl(0.0024, 0.0015, (x - side * 0.005, front - 0.0047, k * U + U / 2), p["trim"], verts=8)
        rows = min(8, max(1, int((h - 0.012) / 0.0055)))
        for rr in range(rows):
            for c in range(6):
                mb.box((0.0008, 0.014, 0.0025), (side * (WIDTH / 2 + 0.0004), front + 0.04 + c * 0.018, h / 2 + (rr - (rows - 1) / 2) * 0.0055), p["cutout"])
    top = h - 0.001
    mb.box((WIDTH - 0.006, 0.0015, 0.0004), (0, -0.14, top + 0.0002), p["cutout"])
    mb.box((0.07, 0.045, 0.0003), (0.11, 0.18, top + 0.00015), p["label"])
    return h, front, mb


def rear_psus(mb, p, h):
    """Two hot-swap PSUs on the right: stacked from 2U up, side by side in 1U. LEDs off: no power cord."""
    ph, w = min(h - 0.006, 0.039), 0.072
    x = WIDTH / 2 - w / 2 - 0.006
    if h >= 2 * ph + 0.008:
        slots = [(x, h / 2 + ph / 2 + 0.002), (x, h / 2 - ph / 2 - 0.002)]
    else:
        slots = [(x, h / 2), (x - w - 0.004, h / 2)]
    for sx, sz in slots:
        mb.back(w, ph, sx, sz, BACK, 0.003, p["plastic"])
        b = BACK + 0.003
        rf = ph * 0.36
        fx = sx - w / 2 + rf + 0.004
        mb.cyl(rf, 0.0008, (fx, b + 0.0004, sz), p["cutout"], verts=16)
        mb.box((2 * rf, 0.0012, 0.0010), (fx, b + 0.0010, sz), p["trim"])
        mb.box((0.0010, 0.0012, 2 * rf), (fx, b + 0.0010, sz), p["trim"])
        mb.back(0.016, 0.011, sx + 0.012, sz, b, 0.0008, p["cutout"])
        for px in (-0.004, 0.0, 0.004):
            mb.back(0.0012, 0.0035, sx + 0.012 + px, sz, b + 0.0008, 0.0015, p["trim"])
        mb.back(0.004, ph * 0.7, sx + w / 2 - 0.006, sz, b, 0.008, p["trim"])
        mb.back(0.002, 0.002, sx + 0.012, sz + ph / 2 - 0.004, b, 0.0006, p["led_off"])


def slot_cover(mb, p, x, z, w, h, horizontal):
    """PCIe slot cover with vent slots."""
    mb.back(w, h, x, z, BACK, 0.0008, p["carrier"])
    for k in range(5):
        if horizontal:
            mb.back(0.003, h * 0.55, x - w / 2 + w * (k + 1) / 6, z, BACK + 0.0008, 0.0003, p["cutout"])
        else:
            mb.back(w * 0.55, 0.003, x, z - h / 2 + h * (k + 1) / 6, BACK + 0.0008, 0.0003, p["cutout"])


def rear_server_io(mb, p, h, units):
    """Management + 2 LAN ports, 2 USB, VGA, PCIe slot covers and vents."""
    z = 0.011
    for x in (-0.205, -0.1925, -0.18):
        rj45(mb, p, x, z, BACK, True, f=1)
    usb(mb, p, -0.163, 0.009, BACK, f=1)
    usb(mb, p, -0.163, 0.0165, BACK, f=1)
    vga(mb, p, -0.142, z, BACK, f=1)
    if units == 1:
        for x in (-0.07, 0.01):
            slot_cover(mb, p, x, h - 0.013, 0.072, 0.016, horizontal=True)
        for c in range(12):
            for rr in range(2):
                mb.back(0.005, 0.005, -0.11 + c * 0.008, 0.008 + rr * 0.008, BACK, 0.0004, p["cutout"])
    else:
        for i in range(7):
            slot_cover(mb, p, -0.11 + i * 0.022, h / 2 + 0.008, 0.017, min(h - 0.03, 0.07), horizontal=False)
        for c in range(9):
            for rr in range(int((h - 0.04) / 0.009)):
                mb.back(0.006, 0.006, -0.208 + c * 0.009, 0.03 + rr * 0.009, BACK, 0.0004, p["cutout"])


def rear_fans(mb, p, h, count, x0, x1):
    rad = min(h * 0.38, 0.017)
    for i in range(count):
        x = x0 + (i + 0.5) * (x1 - x0) / count
        mb.cyl(rad, 0.0008, (x, BACK + 0.0004, h / 2), p["cutout"], verts=20)
        mb.cyl(rad * 0.35, 0.0014, (x, BACK + 0.0007, h / 2), p["plastic"], verts=12)
        mb.box((2 * rad, 0.0010, 0.0008), (x, BACK + 0.0016, h / 2), p["trim"])
        mb.box((0.0008, 0.0010, 2 * rad), (x, BACK + 0.0016, h / 2), p["trim"])


# --- Models ---

def server_1u(name="Server_1U"):
    """1U server: 8 x 2.5" drive carriers, front USB + VGA, control panel."""
    p = palette()
    r = root(name)
    h, front, mb = chassis(p, r, 1)
    mb.front(WIDTH - 0.02, h - 0.004, 0, h / 2, front, 0.006, p["bezel"])
    face = front - 0.006
    usb(mb, p, -0.199, h * 0.68, face)
    vga(mb, p, -0.199, h * 0.30, face)
    w = 0.0385
    for i in range(8):
        drive_sff(mb, p, -0.180 + w / 2 + i * 0.0405, h / 2, face, w, h - 0.010)
    cx = 0.185
    mb.cyl(0.0035, 0.002, (cx + 0.008, face - 0.001, h * 0.66), p["trim"])
    mb.cyl(0.0022, 0.0015, (cx - 0.006, face - 0.00075, h * 0.66), p["tab"])
    mb.front(0.012, 0.0025, cx - 0.004, h * 0.28, face, 0.0004, p["label"])
    status_led(p, r, cx + 0.010, face, h * 0.28)
    rear_psus(mb, p, h)
    rear_server_io(mb, p, h, 1)
    mb.finish("details", r)
    return r


def server_2u(name="Server_2U"):
    """2U server: honeycomb bezel with lock, front USB + VGA, control panel."""
    p = palette()
    r = root(name)
    h, front, mb = chassis(p, r, 2)
    bezel_w = WIDTH - 0.07
    box("bezel", (bezel_w, 0.012, h - 0.008), (0, front - 0.008, h / 2), p["bezel"], r, bevel=0.003)
    honeycomb(mb, p, bezel_w - 0.04, h - 0.02, front - 0.014, h / 2, 0.0085)
    lx = bezel_w / 2 - 0.009
    mb.cyl(0.0045, 0.003, (lx, front - 0.0155, h * 0.75), p["trim"])
    mb.front(0.0012, 0.004, lx, h * 0.75, front - 0.017, 0.0004, p["cutout"])
    for side in (-1, 1):
        cx = side * (WIDTH / 2 - 0.018)
        mb.front(0.026, h - 0.01, cx, h / 2, front, 0.006, p["trim"])
    face = front - 0.006
    usb(mb, p, -(WIDTH / 2 - 0.018), h * 0.70, face)
    vga(mb, p, -(WIDTH / 2 - 0.018), h * 0.40, face)
    mb.front(0.016, 0.004, -(WIDTH / 2 - 0.018), h * 0.15, face, 0.0003, p["label"])
    cx = WIDTH / 2 - 0.018
    mb.cyl(0.004, 0.003, (cx, face - 0.0015, h * 0.72), p["bezel"])
    mb.cyl(0.0025, 0.0015, (cx, face - 0.00075, h * 0.55), p["tab"])
    status_led(p, r, cx, face, h * 0.38)
    for k in range(3):
        mb.front(0.002, 0.0015, cx - 0.006 + k * 0.006, h * 0.2, face, 0.0004, p["led_off"])
    rear_psus(mb, p, h)
    rear_server_io(mb, p, h, 2)
    mb.finish("details", r)
    return r


def storage_3u(name="Storage_3U"):
    """3U storage: 3 x 6 x 3.5" drive carriers; rear: two stacked controllers with SAS ports."""
    p = palette()
    r = root(name)
    h, front, mb = chassis(p, r, 3)
    mb.front(WIDTH - 0.01, h - 0.004, 0, h / 2, front, 0.004, p["bezel"])
    face = front - 0.004
    w, ch = 0.057, 0.0375
    for row in range(3):
        for c in range(6):
            drive_lff(mb, p, -0.185 + w / 2 + c * 0.06, h / 2 + (row - 1) * 0.0415, face, w, ch)
    cx = 0.202
    mb.front(0.024, h - 0.02, cx, h / 2, face, 0.002, p["trim"])
    f2 = face - 0.002
    mb.cyl(0.004, 0.003, (cx, f2 - 0.0015, h * 0.72), p["bezel"])
    mb.cyl(0.0025, 0.0015, (cx, f2 - 0.00075, h * 0.62), p["tab"])
    status_led(p, r, cx, f2, h * 0.52)
    usb(mb, p, cx, h * 0.30, f2)
    for cz in (h / 2 + 0.031, h / 2 - 0.031):
        cxx, cw, chh = -0.07, 0.25, 0.055
        mb.back(cw, chh, cxx, cz, BACK, 0.003, p["plastic"])
        b = BACK + 0.003
        for k in range(2):
            mb.back(0.017, 0.008, cxx - 0.06 + k * 0.024, cz, b, 0.003, p["trim"])
            mb.back(0.014, 0.005, cxx - 0.06 + k * 0.024, cz, b + 0.003, 0.0003, p["cutout"])
        rj45(mb, p, cxx, cz, b, True, f=1)
        rj45(mb, p, cxx + 0.0125, cz, b, True, f=1)
        usb(mb, p, cxx + 0.032, cz, b, f=1)
        for e in (-1, 1):
            mb.back(0.006, chh - 0.01, cxx + e * (cw / 2 - 0.006), cz, b, 0.008, p["trim"])
        mb.back(0.002, 0.002, cxx + 0.05, cz + 0.015, b, 0.0006, p["led_off"])
    rear_psus(mb, p, h)
    mb.finish("details", r)
    return r


def ring(mb, p, x, z, face, radius, t):
    """A printed circle outline of 12 short strokes."""
    for k in range(12):
        a = k * math.pi / 6
        stroke(mb, p, x + radius * math.cos(a - 0.3), z + radius * math.sin(a - 0.3),
               x + radius * math.cos(a + 0.3), z + radius * math.sin(a + 0.3), face, t)


def stroke(mb, p, x0, z0, x1, z1, face, t=0.0006):
    """A printed straight line from (x0, z0) to (x1, z1) on a front surface."""
    length = math.hypot(x1 - x0, z1 - z0)
    # Rotation around +Y turns +X towards -Z, so negate the angle measured from X towards Z.
    mb.box((length + t, 0.0002, t), ((x0 + x1) / 2, face - 0.0001, (z0 + z1) / 2), p["label"],
           spin=-math.atan2(z1 - z0, x1 - x0))


def breaker(mb, p, x, z, face):
    """Circuit breaker with OFF/ON rocker (ON side pressed in, i.e. switched on) and its two
    mounting screws."""
    mb.front(0.026, 0.017, x, z, face, 0.0015, p["plastic"])
    f2 = face - 0.0015
    mb.front(0.010, 0.013, x - 0.006, z, f2, 0.0008, p["carrier"])       # OFF half, raised
    mb.front(0.010, 0.013, x + 0.006, z, f2, 0.0003, p["bezel"])         # ON half, pressed
    ring(mb, p, x - 0.006, z, f2 - 0.0008, 0.0022, 0.0006)                          # "O" = off
    mb.front(0.0007, 0.0050, x + 0.006, z, f2 - 0.0003, 0.0002, p["label"])          # "I" = on
    for sx in (-1, 1):
        mb.cyl(0.0018, 0.0008, (x + sx * 0.0175, face - 0.0004, z), p["trim"], verts=8)


def pdu_3u(name="PDU_3U"):
    """3U horizontal rack PDU (after the NVIDIA reference). Front: management panel (RJ45, USB,
    LCD with 4 buttons) and 3 groups of 4 circuit breakers. Rear: 3 x 6 C19/C13 outlets and the
    round locking feed inlet."""
    p = palette()
    r = root(name)
    h, front, mb = chassis(p, r, 3)
    mb.front(WIDTH - 0.008, h - 0.006, 0, h / 2, front, 0.002, p["chassis"])
    face = front - 0.002
    # management panel
    pz = h * 0.72
    mb.front(0.21, 0.040, 0.0, pz, face, 0.0015, p["carrier"])
    f2 = face - 0.0015
    for x in (-0.074, -0.061):
        rj45(mb, p, x, pz + 0.0085, f2, True)
        rj45(mb, p, x, pz - 0.0085, f2, False)
    mb.front(0.0085, 0.0075, -0.046, pz + 0.009, f2, 0.0025, p["trim"])      # USB-B
    mb.front(0.0055, 0.0045, -0.046, pz + 0.009, f2 - 0.0025, 0.0003, p["cutout"])
    usb(mb, p, -0.046, pz - 0.0035, f2)
    usb(mb, p, -0.046, pz - 0.0110, f2)
    rj45(mb, p, -0.030, pz + 0.0085, f2, True)
    rj45(mb, p, -0.030, pz - 0.0085, f2, False)
    for lz in (pz + 0.007, pz - 0.007):
        mb.cyl(0.0012, 0.0008, (-0.019, f2 - 0.0004, lz), p["led_off"], verts=8)
    mb.front(0.044, 0.034, 0.012, pz, f2, 0.001, p["bezel"])
    mb.front(0.040, 0.030, 0.012, pz, f2 - 0.001, 0.0004, p["screen"])
    seg_text(mb, p, "16.4", 0.012, pz, f2 - 0.0014, 0.0065, 0.010)
    s = 0.0022  # symbol half size: up, OK ("O"), down, cancel ("X")
    for bx, bz, sym in ((0.048, 1, "up"), (0.062, 1, "o"), (0.048, -1, "down"), (0.062, -1, "x")):
        bzz = pz + bz * 0.0075
        mb.cyl(0.0050, 0.0012, (bx, f2 - 0.0006, bzz), p["trim"], verts=16)
        mb.cyl(0.0040, 0.0015, (bx, f2 - 0.00075, bzz), p["carrier"], verts=16)
        sf = f2 - 0.0015  # front of the button cap
        if sym == "o":
            ring(mb, p, bx, bzz, sf, s, 0.0005)
        elif sym == "x":
            stroke(mb, p, bx - s, bzz - s, bx + s, bzz + s, sf)
            stroke(mb, p, bx - s, bzz + s, bx + s, bzz - s, sf)
        else:
            tip = s if sym == "up" else -s
            stroke(mb, p, bx - s, bzz - tip * 0.5, bx, bzz + tip * 0.7, sf)
            stroke(mb, p, bx, bzz + tip * 0.7, bx + s, bzz - tip * 0.5, sf)
    status_led(p, r, 0.090, f2, pz)
    mb.cyl(0.0018, 0.0008, (-0.096, f2 - 0.0004, pz), p["trim"], verts=8)   # panel screws
    mb.cyl(0.0018, 0.0008, (0.096, f2 - 0.0004, pz), p["trim"], verts=8)
    # 3 groups of 2 x 2 breakers
    gz = h * 0.30
    for gx in (-0.14, 0.0, 0.14):
        mb.front(0.130, 0.058, gx, gz, face, 0.0012, p["carrier"])
        for bx in (-0.032, 0.032):
            for bz in (-0.0135, 0.0135):
                breaker(mb, p, gx + bx, gz + bz, face - 0.0012)
    # rear: 3 rows of outlets, the left 3 columns C19 (larger, for high-power loads), then C13
    for row in range(3):
        oz = h / 2 + (row - 1) * 0.036
        for c in range(6):
            ox = -0.19 + c * 0.04
            if c < 3:
                c19_rear(mb, p, ox, oz)
            else:
                c13_rear(mb, p, ox, oz)
    feed_inlet(mb, p, 0.15, h / 2)
    mb.finish("details", r)
    return r


def c13_rear(mb, p, x, z):
    """C13 outlet on the rear panel (sticks out towards +Y)."""
    mb.back(0.026, 0.019, x, z, BACK, 0.003, p["plastic"])
    b = BACK + 0.003
    mb.back(0.020, 0.013, x, z, b, 0.0004, p["carrier"])
    for hx in (-0.0055, 0.0055):
        mb.back(0.0022, 0.0050, x + hx, z + 0.0015, b + 0.0004, 0.0003, p["cutout"])
    mb.back(0.0022, 0.0040, x, z - 0.0035, b + 0.0004, 0.0003, p["cutout"])


def c19_rear(mb, p, x, z):
    """C19 outlet: wider housing, two horizontal blade slots above the earth slot."""
    mb.back(0.032, 0.026, x, z, BACK, 0.003, p["plastic"])
    b = BACK + 0.003
    mb.back(0.026, 0.020, x, z, b, 0.0004, p["carrier"])
    for hx in (-0.0065, 0.0065):
        mb.back(0.0070, 0.0022, x + hx, z + 0.003, b + 0.0004, 0.0003, p["cutout"])
    mb.back(0.0070, 0.0022, x, z - 0.005, b + 0.0004, 0.0003, p["cutout"])


def feed_inlet(mb, p, x, z):
    """Round locking power inlet (like a CEE / twist-lock socket) with its mounting flange,
    collar, contact pins, cable gland stub and a cover flap above it."""
    mb.back(0.060, 0.060, x, z, BACK, 0.003, p["trim"])
    for sx in (-1, 1):
        for sz in (-1, 1):
            mb.cyl(0.0025, 0.0015, (x + sx * 0.024, BACK + 0.0037, z + sz * 0.024), p["chassis"], verts=8)
    b = BACK + 0.003
    mb.cyl(0.024, 0.020, (x, b + 0.010, z), p["plastic"], verts=24)
    mb.cyl(0.019, 0.004, (x, b + 0.019, z), p["cutout"], verts=24)
    for a in range(5):
        ang = a * 2 * math.pi / 5
        mb.cyl(0.0022, 0.006, (x + 0.011 * math.cos(ang), b + 0.019, z + 0.011 * math.sin(ang)), p["gold"], verts=8)
    mb.cyl(0.0035, 0.006, (x, b + 0.019, z), p["gold"], verts=8)
    mb.box((0.006, 0.020, 0.008), (x, b + 0.010, z + 0.026), p["plastic"])  # locking lug
    mb.back(0.016, 0.005, x, z - 0.040, BACK, 0.0003, p["label"])


def network_switch(name="NetworkSwitch_1U"):
    """1U access switch: 4 SFP+ cages, 48 x RJ45 in 4 blocks (rows mirrored like stacked jacks)
    with printed port numbers, USB + console. No cables, so all link LEDs are off."""
    p = palette()
    r = root(name)
    h, front, mb = chassis(p, r, 1, body="chassis_dark")
    mb.front(WIDTH - 0.016, h - 0.004, 0, h / 2, front, 0.004, p["bezel"])
    face = front - 0.004
    pitch, row = 0.0125, 0.0112
    for b in range(4):
        x0 = -0.163 + b * (6 * pitch + 0.0055)
        for c in range(6):
            x = x0 + pitch / 2 + c * pitch
            for latch_up in (True, False):
                rj45(mb, p, x, h / 2 + (row / 2 if latch_up else -row / 2), face, latch_up)
            mb.front(0.0035, 0.0007, x, h - 0.0045, face, 0.0002, p["label"])
        mb.front(6 * pitch - 0.004, 0.0005, x0 + 3 * pitch, 0.0035, face, 0.0002, p["label"])
    for i, (sx, sz) in enumerate([(-0.196, 1), (-0.180, 1), (-0.196, -1), (-0.180, -1)]):
        sfp(mb, p, sx, h / 2 + sz * 0.0056, face, module=i in (0, 2))
    usb(mb, p, 0.172, h * 0.64, face)
    mb.front(0.0085, 0.0032, 0.172, h * 0.30, face, 0.0015, p["trim"])     # USB-C console
    mb.front(0.0072, 0.0020, 0.172, h * 0.30, face - 0.0015, 0.0003, p["cutout"])
    for k in range(3):
        mb.front(0.002, 0.0015, 0.19, h * 0.78 - k * 0.006, face, 0.0004, p["led_off"])
    mb.cyl(0.0018, 0.0015, (0.202, face - 0.00075, h * 0.5), p["plastic"], verts=10)
    status_led(p, r, 0.19, face, h * 0.28)
    rear_psus(mb, p, h)
    rear_fans(mb, p, h, 4, -0.2, 0.05)
    mb.finish("details", r)
    return r


def rack_42u(name="ServerRack_42U"):
    """42U rack, open front: frame, side panels with grip, perforated rear door, 19" rails with
    3 square holes per U and U marks, rail supports, rear cable lacing bars, roof vents, levelling feet."""
    p = palette()
    r = root(name)
    units = 42
    inner_h = units * U
    ow, od, post = 0.60, 1.00, 0.04
    base = 0.08                     # plinth below slot 0
    top = inner_h + 0.04
    z0 = -base
    frame = p["frame"]
    box("plinth", (ow, od, base - 0.01), (0, 0, z0 + (base - 0.01) / 2), frame, r, bevel=0.004)
    box("roof", (ow, od, 0.03), (0, 0, top + 0.015), frame, r, bevel=0.004)
    post_bottom = z0 + base - 0.01
    post_h = top - post_bottom
    pz = post_bottom + post_h / 2
    for px in (-1, 1):
        for py in (-1, 1):
            box(f"post_{px}_{py}", (post, post, post_h), (px * (ow / 2 - post / 2), py * (od / 2 - post / 2), pz), frame, r, bevel=0.003)
    for side in (-1, 1):
        box(f"side_panel_{side}", (0.006, od - 2 * post, post_h), (side * (ow / 2 - 0.006), 0, pz), p["panel"], r)
    box("rear_door", (ow - 2 * post, 0.006, post_h), (0, od / 2 - 0.006, pz), p["panel"], r)

    mb = MeshBuilder()
    for fx in (-1, 1):
        for fy in (-1, 1):
            x, y = fx * (ow / 2 - 0.05), fy * (od / 2 - 0.06)
            mb.cyl(0.006, 0.012, (x, y, z0 - 0.006), p["trim"], verts=10, axis="Z")
            mb.cyl(0.022, 0.006, (x, y, z0 - 0.015), p["plastic"], verts=16, axis="Z")
    for fy in (-1, 1):
        for c in range(16):
            mb.box((0.022, 0.0008, 0.035), (-0.24 + c * 0.032, fy * (od / 2 + 0.0004), z0 + (base - 0.01) / 2), p["cutout"])
    roof = top + 0.0304
    for rr in range(3):
        for c in range(8):
            mb.box((0.045, 0.012, 0.0008), (-0.19 + c * 0.054, -0.2 + rr * 0.03, roof), p["cutout"])
    mb.box((0.30, 0.06, 0.0010), (0, 0.32, roof), p["plastic"])         # cable entry with brush
    mb.box((0.28, 0.006, 0.0012), (0, 0.32, roof + 0.0002), p["cutout"])
    # 19" rails: front with holes and U marks, rear plain; supports to the side frame
    rail_y = -DEPTH / 2 + 0.006
    for side in (-1, 1):
        rx = side * (WIDTH / 2 + EAR / 2)
        for ry in (rail_y, -rail_y):
            mb.box((EAR, 0.004, inner_h), (rx, ry, inner_h / 2), p["trim"])
            mb.box((0.002, 0.03, inner_h), (side * (WIDTH / 2 + EAR - 0.001), ry + (0.017 if ry < 0 else -0.017), inner_h / 2), p["trim"])
            for sz in (0.05, inner_h / 2, inner_h - 0.05):
                mb.box((0.051, 0.02, 0.025), (side * 0.2655, ry, sz), frame)
        for u in range(units):
            for k in (0.143, 0.5, 0.857):
                mb.box((0.0065, 0.002, 0.0065), (rx, rail_y - 0.0025, (u + k) * U), p["cutout"])
    for u in range(units + 1):
        long = u % 5 == 0
        mb.box((0.006 if long else 0.003, 0.0006, 0.0008), (-(WIDTH / 2 + EAR) + (0.003 if long else 0.0015), rail_y - 0.0023, u * U), p["label"])
    # perforated rear door with handle and hinges
    door_y = od / 2 - 0.003
    cols, rows = 10, 44
    area_w, area_h = ow - 2 * post - 0.06, post_h - 0.24
    for rr in range(rows):
        for c in range(cols - (rr % 2)):
            x = -area_w / 2 + (c + 0.5 + (rr % 2) * 0.5) * area_w / cols
            mb.box((0.03, 0.0008, 0.024), (x, door_y + 0.0004, pz - area_h / 2 + (rr + 0.5) * area_h / rows), p["cutout"])
    mb.box((0.012, 0.012, 0.12), (ow / 2 - post - 0.02, door_y + 0.006, inner_h * 0.55), p["trim"])
    for hz in (0.15, inner_h / 2, inner_h - 0.15):
        mb.box((0.012, 0.008, 0.05), (-(ow / 2 - post) + 0.004, door_y + 0.004, hz), p["trim"])
    # side panels: two-part seam, recessed grip with lock
    for side in (-1, 1):
        xo = side * (ow / 2 - 0.003)
        mb.box((0.0006, od - 2 * post, 0.003), (xo + side * 0.0003, 0, pz), p["cutout"])
        mb.box((0.0008, 0.12, 0.04), (xo + side * 0.0004, 0.15, inner_h * 0.55), p["cutout"])
        mb.cyl(0.006, 0.003, (xo + side * 0.0015, 0.15, inner_h * 0.55 + 0.045), p["trim"], verts=12, axis="X")
    # rear cable lacing bars with rings
    for side in (-1, 1):
        lx, ly = side * 0.262, 0.44
        mb.box((0.004, 0.03, inner_h), (lx, ly, inner_h / 2), p["trim"])
        for k in range(14):
            rz = 0.08 + k * (inner_h - 0.16) / 13
            for e in (-1, 1):
                mb.box((0.03, 0.003, 0.003), (lx - side * 0.015, ly + e * 0.012, rz), p["trim"])
            mb.box((0.003, 0.027, 0.003), (lx - side * 0.03, ly, rz), p["trim"])
    mb.finish("details", r)
    return r


MODELS = [rack_42u, server_1u, server_2u, storage_3u, pdu_3u, network_switch]


def build(scene_name="Assets", spacing=0.8):
    scene = bpy.data.scenes.get(scene_name) or bpy.data.scenes.new(scene_name)
    bpy.context.window.scene = scene
    for o in list(scene.objects):
        if o.name != "ReviewCam":
            bpy.data.objects.remove(o, do_unlink=True)
    built = {}
    for i, make in enumerate(MODELS):
        r = make()
        r.location.x = i * spacing  # side by side for review; export resets this to the origin
        built[r.name] = i
    return built


# Blender model -> file name the AAS seed references; add_colliders.py then adds the select boxes.
FILES = {"ServerRack_42U": "ServerRack", "Server_1U": "Server_00", "Server_2U": "Server_2U_00",
         "Storage_3U": "Server_3U_00", "PDU_3U": "PowerSupply_00", "NetworkSwitch_1U": "NetworkSwitch_00"}


def select_collider(stage, name, size, center):
    """Select-only box: IDTXFlow builds physics only for prims with its CollisionAPI schema."""
    cube = UsdGeom.Cube.Define(stage, f"/root/{name}")
    cube.CreateSizeAttr(1.0)
    cube.AddTranslateOp().Set(Gf.Vec3d(*center))
    cube.AddScaleOp().Set(Gf.Vec3f(*size))
    cube.CreatePurposeAttr("guide")  # not rendered
    prim = cube.GetPrim()
    prim.AddAppliedSchema("CollisionAPI")
    prim.CreateAttribute("collision:shape", Sdf.ValueTypeNames.Token, custom=True).Set("Box")
    prim.CreateAttribute("collision:interactionTypes", Sdf.ValueTypeNames.TokenArray, custom=True).Set(["Select"])
    prim.CreateAttribute("collision:type", Sdf.ValueTypeNames.Token, custom=True).Set("Static")


def add_colliders(path, rack):
    """Components get one box around the model. The rack gets one per frame part (not the rails),
    so clicks inside it reach the components. The rack model and colliders are lifted so the feet
    stand on Z = 0; the components (placed under /root by RackComponents) are lifted by the same
    SLOT_0_Z there. (IDTXFlow ignores transforms on /root itself, so the lift is on its children.)"""
    stage = Usd.Stage.Open(path)
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), ["default", "render"])
    model = stage.GetDefaultPrim().GetChildren()[0]
    parts = [p for p in model.GetChildren() if p.GetName() != "details"] if rack else [model]
    for i, part in enumerate(parts):
        box = cache.ComputeWorldBound(part).ComputeAlignedRange()
        select_collider(stage, f"select_{i}", box.GetSize(), box.GetMidpoint())
    if rack:
        feet = cache.ComputeWorldBound(model).ComputeAlignedRange().GetMin()[2]
        assert abs(feet + SLOT_0_Z) < 1e-4, f"rack feet at {feet}, expected {-SLOT_0_Z}"
        for child in stage.GetDefaultPrim().GetChildren():
            xf = UsdGeom.Xformable(child)
            ops = xf.GetOrderedXformOps()
            lift = xf.AddTranslateOp(opSuffix="slot0")
            lift.Set(Gf.Vec3d(0, 0, SLOT_0_Z))
            xf.SetXformOpOrder([lift, *ops])
    stage.Save()


def export(out_dir):
    """Export each model alone, at the origin, as <out_dir>/<FILES name>.usdc with root prim /root,
    then add the select colliders (Blender's exporter can't write them; its bundled pxr can)."""
    os.makedirs(out_dir, exist_ok=True)
    for r in [o for o in bpy.context.scene.objects if o.name in FILES]:
        saved = r.location.copy()
        r.location = (0, 0, 0)
        bpy.ops.object.select_all(action="DESELECT")
        for o in [r] + list(r.children_recursive):
            o.select_set(True)
        bpy.context.view_layer.objects.active = r
        bpy.ops.wm.usd_export(
            filepath=os.path.join(out_dir, FILES[r.name] + ".usdc"), check_existing=False,
            selected_objects_only=True, generate_preview_surface=True, root_prim_path="/root",
            export_lights=False, export_cameras=False, export_mesh_colors=False,
            export_custom_properties=False, author_blender_name=False, convert_world_material=False)
        r.location = saved
        add_colliders(os.path.join(out_dir, FILES[r.name] + ".usdc"), rack=r.name == "ServerRack_42U")


if __name__ == "__main__":
    build()
    export(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
