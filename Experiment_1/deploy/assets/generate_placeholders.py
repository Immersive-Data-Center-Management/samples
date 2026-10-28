#!/usr/bin/env python3
"""Generate the small, original placeholder USD assets for the demo stack.

These placeholders keep the sample self-contained. Any USD that follows the
contract in README.md can replace them.

Requires usd-core 26.11 (OpenUSD Python bindings): pip install -r requirements.txt
"""

from pathlib import Path

from pxr import Gf, Sdf, Usd, UsdGeom

HERE = Path(__file__).resolve().parent
U_HEIGHT = 0.04445
_part_index = 0


def new_stage(name):
    global _part_index
    _part_index = 0
    path = HERE / name
    stage = Usd.Stage.CreateNew(str(path))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = UsdGeom.Xform.Define(stage, "/root")
    stage.SetDefaultPrim(root.GetPrim())
    return stage


def select_collider(stage, name, size, center):
    """Author a select-only primitive so IDTXFlow can pick the asset."""
    cube = UsdGeom.Cube.Define(stage, f"/root/{name}")
    cube.CreateSizeAttr(1.0)
    xform = UsdGeom.Xformable(cube)
    xform.AddTranslateOp().Set(Gf.Vec3d(*center))
    xform.AddScaleOp().Set(Gf.Vec3d(*size))
    prim = cube.GetPrim()
    prim.AddAppliedSchema("CollisionAPI")
    prim.CreateAttribute("collision:shape", Sdf.ValueTypeNames.Token, custom=True).Set("Box")
    prim.CreateAttribute(
        "collision:interactionTypes", Sdf.ValueTypeNames.TokenArray, custom=True
    ).Set(["Select"])
    prim.CreateAttribute("collision:type", Sdf.ValueTypeNames.Token, custom=True).Set(
        "Static"
    )


def box(stage, name, size, center, color, selectable=False):
    global _part_index
    _part_index += 1
    cube = UsdGeom.Cube.Define(stage, f"/root/part_{_part_index}")
    cube.CreateSizeAttr(1.0)
    xform = UsdGeom.Xformable(cube)
    xform.AddTranslateOp().Set(Gf.Vec3d(*center))
    xform.AddScaleOp().Set(Gf.Vec3d(*size))
    cube.CreateDisplayColorAttr([Gf.Vec3f(*color)])
    if selectable:
        select_collider(stage, f"select_{_part_index}", size, center)


def make_rack():
    stage = new_stage("ServerRack.usdc")
    frame = (0.10, 0.12, 0.16)
    for x in (-0.275, 0.275):
        for y in (-0.475, 0.475):
            box(stage, f"post_{x}_{y}", (0.05, 0.05, 2.0), (x, y, 1.0), frame, selectable=True)
    for z in (0.025, 1.975):
        for y in (-0.475, 0.475):
            box(stage, f"rail_x_{z}_{y}", (0.60, 0.05, 0.05), (0, y, z), frame, selectable=True)
        for x in (-0.275, 0.275):
            box(stage, f"rail_y_{z}_{x}", (0.05, 1.0, 0.05), (x, 0, z), frame, selectable=True)
    stage.Save()


def make_server():
    stage = new_stage("Server_00.usdc")
    height = 0.04379
    body = (0.22, 0.25, 0.30)
    face = (0.10, 0.11, 0.13)
    box(stage, "body", (0.48, 0.80, height), (0, 0, height / 2), body, selectable=True)
    box(stage, "front", (0.46, 0.02, 0.035), (0, -0.405, height / 2), face)
    box(stage, "led", (0.012, 0.006, 0.008), (0.20, -0.416, height / 2 + 0.008),
        (0.10, 0.80, 0.30))
    for index in range(6):
        box(
            stage,
            f"vent_{index}",
            (0.02, 0.004, 0.008),
            (-0.15 + index * 0.05, -0.416, height / 2 - 0.005),
            (0.35, 0.38, 0.42),
        )
    stage.Save()


def make_server_3u():
    stage = new_stage("Server_3U_00.usdc")
    height = 3 * U_HEIGHT
    body = (0.20, 0.22, 0.26)
    face = (0.08, 0.09, 0.11)
    box(stage, "body", (0.48, 0.80, height), (0, 0, height / 2), body, selectable=True)
    box(stage, "front", (0.44, 0.02, height - 0.02), (0, -0.405, height / 2), face)
    for row, offset in enumerate((-0.033, 0.033)):
        for index in range(6):
            box(
                stage,
                f"bay_{row}_{index}",
                (0.05, 0.006, 0.026),
                (-0.13 + index * 0.052, -0.416, height / 2 + offset),
                (0.28, 0.31, 0.35),
            )
    for index, x in enumerate((-0.215, 0.215)):
        box(stage, f"handle_{index}", (0.012, 0.01, 0.05), (x, -0.412, height / 2),
            (0.16, 0.38, 0.68))
    box(stage, "led", (0.012, 0.006, 0.008), (0.17, -0.416, height / 2 + 0.033),
        (0.10, 0.80, 0.30))
    stage.Save()


def make_psu():
    stage = new_stage("PowerSupply_00.usdc")
    height = 3 * U_HEIGHT
    body = (0.18, 0.20, 0.24)
    face = (0.10, 0.11, 0.13)
    box(stage, "body", (0.48, 0.80, height), (0, 0, height / 2), body, selectable=True)
    box(stage, "front", (0.46, 0.02, 0.12), (0, -0.405, height / 2), face)
    for index in range(5):
        box(
            stage,
            f"vent_{index}",
            (0.10, 0.004, 0.008),
            (0, -0.416, 0.02 + index * 0.022),
            (0.35, 0.38, 0.42),
        )
    box(stage, "accent", (0.012, 0.006, 0.012), (0.20, -0.416, height / 2),
        (0.90, 0.45, 0.10))
    stage.Save()


if __name__ == "__main__":
    make_rack()
    make_server()
    make_server_3u()
    make_psu()
    for name in (
        "ServerRack.usdc",
        "Server_00.usdc",
        "Server_3U_00.usdc",
        "PowerSupply_00.usdc",
    ):
        path = HERE / name
        print(f"wrote {path} ({path.stat().st_size} bytes)")
