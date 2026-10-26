#!/usr/bin/env python3
"""Check that the demo USD assets contain IDTXFlow select colliders."""

from pathlib import Path

from pxr import Usd

HERE = Path(__file__).resolve().parent
ASSETS = (
    "ServerRack.usdc",
    "Server_00.usdc",
    "Server_3U_00.usdc",
    "PowerSupply_00.usdc",
)


def has_select_collider(path):
    stage = Usd.Stage.Open(str(path))
    return any(
        "CollisionAPI" in str(prim.GetMetadata("apiSchemas"))
        and prim.GetAttribute("collision:interactionTypes").Get() == ["Select"]
        for prim in stage.Traverse()
    )


def main():
    missing = []
    for name in ASSETS:
        path = HERE / name
        ok = path.exists() and has_select_collider(path)
        print(f"{name}: {'OK' if ok else 'missing CollisionAPI select proxy'}")
        if not ok:
            missing.append(name)
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
