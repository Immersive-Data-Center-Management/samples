#!/usr/bin/env python3
"""Simulates live operational data in the AAS.

Every few seconds it writes a slightly drifting Temperature and PowerDraw for
each component. One component (UNREACHABLE, default server-02) reports
Status "unreachable" and no live values, which the Experiment 2 app turns
into an on-site check task. Runs until stopped.
"""

import os
import random
import time

import seed

INTERVAL = float(os.environ.get("SIMULATE_INTERVAL", "5"))
UNREACHABLE = os.environ.get("SIMULATE_UNREACHABLE", "server-02")


def set_value(token, submodel_id, id_short, value):
    url = (
        f"{seed.AAS_URL}/submodels/{seed.encode_id(submodel_id)}"
        f"/submodel-elements/{id_short}/$value"
    )
    # $value of a string Property is the JSON string itself; request() JSON-encodes it
    status, body = seed.request("PATCH", url, token, value)
    if status not in (200, 204):
        raise RuntimeError(f"PATCH {submodel_id}/{id_short} -> HTTP {status}: {body[:200]}")


def main():
    seed.wait_for_status(f"{seed.AAS_URL}/shells", {200, 401}, "AAS environment")
    components = [c for rack in seed.RACKS for c in rack["components"]]
    temps = {c["slug"]: random.uniform(30, 42) for c in components}
    print(f"[simulate] {len(components)} components, unreachable={UNREACHABLE}", flush=True)

    token, token_time = None, 0.0
    while True:
        if time.monotonic() - token_time > 120:  # demo tokens live 5 min
            token, token_time = seed.wait_for_token(), time.monotonic()
        for c in components:
            sm_id = f"urn:apeirora.eu:sm:demo:{c['slug']}:operational"
            try:
                if c["slug"] == UNREACHABLE:
                    set_value(token, sm_id, "Status", "unreachable")
                    set_value(token, sm_id, "Temperature", "")
                    set_value(token, sm_id, "PowerDraw", "")
                    continue
                temps[c["slug"]] = min(max(temps[c["slug"]] + random.uniform(-0.6, 0.6), 28), 48)
                set_value(token, sm_id, "Status", "ok")
                set_value(token, sm_id, "Temperature", f"{temps[c['slug']]:.1f}")
                set_value(token, sm_id, "PowerDraw", str(random.randint(160, 240)))
            except RuntimeError as error:
                # e.g. the AAS was restarted and not reseeded yet; keep going
                print(f"[simulate] {error}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
