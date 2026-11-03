#!/usr/bin/env python3
"""Idempotent demo seed for the standalone Keycloak + BaSyx stack.

Creates fictional nameplate data, 3D-asset submodels and the RackUsage
submodel that the Godot app reads. Safe to run repeatedly.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak:8080").rstrip("/")
AAS_URL = os.environ.get("AAS_URL", "http://aas-environment:8081").rstrip("/")
ASSET_BASE_URL = os.environ.get("ASSET_BASE_URL", "http://127.0.0.1:8080").rstrip("/")

REALM = "BaSyx"
CLIENT_ID = "basyx-client-api"
USERNAME = "demo"
PASSWORD = "demo"

SEM_3D = "urn:apeirora.eu:smt:3dAssets:0.1"
SEM_RACK_USAGE = "urn:apeirora.eu:smt:rackUsage:0.1"
SEM_NAMEPLATE = "https://admin-shell.io/idta/nameplate/3/0/Nameplate"

def component(slug, label, model, height, position, product, serial):
    return {
        "slug": slug,
        "label": label,
        "model": model,
        "height": height,
        "position": position,
        "product": product,
        "serial": serial,
    }


RACKS = [
    {
        "slug": "rack-01",
        "label": "DemoRack01",
        "product": "Demo Rack 45U",
        "serial": "RACK-DEMO-001",
        "components": [
            component("server-01", "DemoServer01", "Server_00.usdc", 1, 2,
                      "Demo Rack Server 1U", "SRV-DEMO-001"),
            component("server-02", "DemoServer02", "Server_00.usdc", 1, 3,
                      "Demo Rack Server 1U", "SRV-DEMO-002"),
            component("server-03", "DemoServer03", "Server_3U_00.usdc", 3, 4,
                      "Demo Rack Server 3U", "SRV-DEMO-003"),
            component("psu-01", "DemoPsu01", "PowerSupply_00.usdc", 3, 12,
                      "Demo Rack Power Supply 3U", "PSU-DEMO-001"),
            component("psu-02", "DemoPsu02", "PowerSupply_00.usdc", 3, 15,
                      "Demo Rack Power Supply 3U", "PSU-DEMO-002"),
        ],
    },
    {
        "slug": "rack-02",
        "label": "DemoRack02",
        "product": "Demo Rack 45U",
        "serial": "RACK-DEMO-002",
        "components": [
            component("psu-03", "DemoPsu03", "PowerSupply_00.usdc", 3, 2,
                      "Demo Rack Power Supply 3U", "PSU-DEMO-003"),
            component("server-04", "DemoServer04", "Server_3U_00.usdc", 3, 6,
                      "Demo Rack Server 3U", "SRV-DEMO-004"),
            component("server-05", "DemoServer05", "Server_3U_00.usdc", 3, 9,
                      "Demo Rack Server 3U", "SRV-DEMO-005"),
            component("server-06", "DemoServer06", "Server_00.usdc", 1, 14,
                      "Demo Rack Server 1U", "SRV-DEMO-006"),
            component("server-07", "DemoServer07", "Server_00.usdc", 1, 15,
                      "Demo Rack Server 1U", "SRV-DEMO-007"),
            component("server-08", "DemoServer08", "Server_00.usdc", 1, 16,
                      "Demo Rack Server 1U", "SRV-DEMO-008"),
        ],
    },
]


def external_ref(value):
    return {
        "type": "ExternalReference",
        "keys": [{"type": "GlobalReference", "value": value}],
    }


def model_ref(value):
    return {
        "type": "ModelReference",
        "keys": [{"type": "Submodel", "value": value}],
    }


def prop(id_short, value):
    return {
        "modelType": "Property",
        "idShort": id_short,
        "valueType": "xs:string",
        "value": str(value),
    }


def mlp(id_short, texts):
    return {
        "modelType": "MultiLanguageProperty",
        "idShort": id_short,
        "value": [{"language": language, "text": text} for language, text in texts],
    }


def file_element(url):
    return {
        "modelType": "File",
        "idShort": "USDFile",
        "contentType": "model/vnd.usd",
        "value": url,
    }


def submodel(submodel_id, id_short, semantic_id, elements):
    return {
        "modelType": "Submodel",
        "id": submodel_id,
        "idShort": id_short,
        "semanticId": external_ref(semantic_id),
        "submodelElements": elements,
    }


def three_d_submodel(slug, label, model):
    url = f"{ASSET_BASE_URL}/api/v1/download/{urllib.parse.quote(model)}"
    return submodel(
        f"urn:apeirora.eu:sm:demo:{slug}:3d",
        f"{label}_3D",
        SEM_3D,
        [file_element(url)],
    )


def nameplate_submodel(slug, label, product, serial):
    return submodel(
        f"urn:apeirora.eu:sm:demo:{slug}:nameplate",
        "Nameplate",
        SEM_NAMEPLATE,
        [
            prop("ManufacturerName", "Apeirora Demo"),
            mlp("ManufacturerProductDesignation", [("en", product), ("de", product)]),
            prop("SerialNumber", serial),
            prop("YearOfConstruction", "2026"),
            prop("URIOfTheProduct", f"https://example.invalid/demo/{label}"),
        ],
    )


def shell(shell_id, id_short, asset_id, submodel_ids):
    return {
        "modelType": "AssetAdministrationShell",
        "id": shell_id,
        "idShort": id_short,
        "assetInformation": {
            "assetKind": "Instance",
            "globalAssetId": asset_id,
        },
        "submodels": [model_ref(submodel_id) for submodel_id in submodel_ids],
    }


def installed_component(component):
    return {
        "modelType": "SubmodelElementCollection",
        "idShort": component["label"],
        "value": [
            {
                "modelType": "Entity",
                "idShort": "Asset",
                "entityType": "SelfManagedEntity",
                "globalAssetId": f"urn:apeirora.eu:asset:demo:{component['slug']}",
            },
            prop("HeightUnits", component["height"]),
            prop("PositionFrom", component["position"]),
        ],
    }


def asset_shell(item, extra_submodels=()):
    """Returns (shell, submodels) for a rack or component with 3D + nameplate."""
    slug, label = item["slug"], item["label"]
    model_3d = three_d_submodel(slug, label, item["model"])
    nameplate = nameplate_submodel(slug, label, item["product"], item["serial"])
    submodels = [model_3d, nameplate, *extra_submodels]
    return (
        shell(
            f"urn:apeirora.eu:aas:demo:{slug}",
            label,
            f"urn:apeirora.eu:asset:demo:{slug}",
            [sm["id"] for sm in submodels],
        ),
        submodels,
    )


def build_seed():
    submodels, shells = [], []
    for rack in RACKS:
        rack_usage = submodel(
            f"urn:apeirora.eu:sm:demo:{rack['slug']}:rack-usage",
            "RackUsage",
            SEM_RACK_USAGE,
            [
                {
                    "modelType": "SubmodelElementCollection",
                    "idShort": "InstalledComponents",
                    "value": [installed_component(c) for c in rack["components"]],
                }
            ],
        )
        for item, extra in [({**rack, "model": "ServerRack.usdc"}, [rack_usage])] + [
            (c, []) for c in rack["components"]
        ]:
            item_shell, item_submodels = asset_shell(item, extra)
            shells.append(item_shell)
            submodels.extend(item_submodels)
    return submodels, shells


def request(method, url, token=None, payload=None):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, response.read().decode(errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")
    except urllib.error.URLError as error:
        return None, str(error)


def wait_for_status(url, accepted, label, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, _ = request("GET", url)
        if status in accepted:
            print(f"[seed] {label} ready (HTTP {status})", flush=True)
            return
        time.sleep(2)
    raise RuntimeError(f"Timed out waiting for {label}: {url}")


def fetch_token():
    body = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "username": USERNAME,
            "password": PASSWORD,
            "scope": "openid",
        }
    ).encode()
    req = urllib.request.Request(
        f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token",
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)["access_token"]


def wait_for_token(timeout=180):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            return fetch_token()
        except (urllib.error.URLError, urllib.error.HTTPError, KeyError) as error:
            last_error = error
            time.sleep(2)
    raise RuntimeError(f"Could not obtain a Keycloak token: {last_error}")


def encode_id(value):
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")


def seed_resource(collection, obj, token):
    encoded_id = encode_id(obj["id"])
    item_path = f"/{collection}/{encoded_id}"
    status, body = request("PUT", AAS_URL + item_path, token, obj)
    if status in (404, 405):
        status, body = request("POST", f"{AAS_URL}/{collection}", token, obj)
    if status == 409:
        status, body = request("PUT", AAS_URL + item_path, token, obj)

    if status not in (200, 201, 204):
        raise RuntimeError(
            f"Failed to seed {collection}/{obj['id']} (HTTP {status}): {body[:500]}"
        )
    print(f"[seed] {collection}: {obj['id']} (HTTP {status})", flush=True)


def main():
    print(
        f"[seed] keycloak={KEYCLOAK_URL} aas={AAS_URL} assets={ASSET_BASE_URL}",
        flush=True,
    )
    wait_for_status(f"{KEYCLOAK_URL}/realms/{REALM}", {200}, "Keycloak realm")
    wait_for_status(f"{AAS_URL}/shells", {200, 401}, "AAS environment")

    token = wait_for_token()
    submodels, shells = build_seed()
    for submodel_data in submodels:
        seed_resource("submodels", submodel_data, token)
    for shell_data in shells:
        seed_resource("shells", shell_data, token)

    print("[seed] done", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"[seed] ERROR: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
