#!/usr/bin/env python3
"""Idempotent demo seed for the standalone Keycloak + BaSyx stack.

Creates fictional nameplate data, Models3D submodels, the rack's
HierarchicalStructures (bill of material) submodel and OperationalData that the
Godot apps read. The data model is described in ../README.md ("AAS data model").
Safe to run repeatedly.
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

SEM_3D = "https://admin-shell.io/idta/Models3D/1/0"
SEM_BOM = "https://admin-shell.io/idta/HierarchicalStructures/1/1/Submodel"
# Our own extension inside each BoM Node: where the part sits in the rack.
SEM_RACK_SLOT = "urn:apeirora.eu:smt:rackSlot:0.1"
SEM_NAMEPLATE = "https://admin-shell.io/idta/nameplate/3/0/Nameplate"
SEM_OPERATIONAL = "urn:apeirora.eu:smt:operationalData:0.1"

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
        "product": "Demo Rack 42U",
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
        "product": "Demo Rack 42U",
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
    {
        # A well-filled rack (32 of 42 U), so the samples also show a realistic density.
        "slug": "rack-03",
        "label": "DemoRack03",
        "product": "Demo Rack 42U",
        "serial": "RACK-DEMO-003",
        "components": [
            component("psu-04", "DemoPsu04", "PowerSupply_00.usdc", 3, 0,
                      "Demo Rack Power Supply 3U", "PSU-DEMO-004"),
            component("psu-05", "DemoPsu05", "PowerSupply_00.usdc", 3, 3,
                      "Demo Rack Power Supply 3U", "PSU-DEMO-005"),
            component("server-09", "DemoServer09", "Server_3U_00.usdc", 3, 6,
                      "Demo Rack Server 3U", "SRV-DEMO-009"),
            component("server-10", "DemoServer10", "Server_3U_00.usdc", 3, 9,
                      "Demo Rack Server 3U", "SRV-DEMO-010"),
            *[component(f"server-{n}", f"DemoServer{n}", "Server_2U_00.usdc", 2, 12 + (n - 11) * 2,
                        "Demo Rack Server 2U", f"SRV-DEMO-0{n}") for n in range(11, 14)],
            *[component(f"server-{n}", f"DemoServer{n}", "Server_00.usdc", 1, 18 + (n - 14),
                        "Demo Rack Server 1U", f"SRV-DEMO-0{n}") for n in range(14, 22)],
            *[component(f"server-{n}", f"DemoServer{n}", "Server_2U_00.usdc", 2, 28 + (n - 22) * 2,
                        "Demo Rack Server 2U", f"SRV-DEMO-0{n}") for n in range(22, 24)],
            component("switch-01", "DemoSwitch01", "NetworkSwitch_00.usdc", 1, 38,
                      "Demo Network Switch 48-Port 1U", "SW-DEMO-001"),
            component("switch-02", "DemoSwitch02", "NetworkSwitch_00.usdc", 1, 39,
                      "Demo Network Switch 48-Port 1U", "SW-DEMO-002"),
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


def file_element(id_short, url, content_type):
    return {
        "modelType": "File",
        "idShort": id_short,
        "contentType": content_type,
        "value": url,
    }


def smc(id_short, elements):
    return {"modelType": "SubmodelElementCollection", "idShort": id_short, "value": elements}


def sml(id_short, elements):
    """SubmodelElementList of collections; list items have no idShort."""
    return {
        "modelType": "SubmodelElementList",
        "idShort": id_short,
        "typeValueListElement": "SubmodelElementCollection",
        "value": [{"modelType": "SubmodelElementCollection", "value": e} for e in elements],
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
    """IDTA 02026 Provision of 3D Models with the mandatory elements only: one Model3D whose
    FileVersion.DigitalFile is the USD URL. The idShort paths follow the template; per-element
    semanticIds are left out to keep the seed short (the app matches the submodel's semanticId)."""
    url = f"{ASSET_BASE_URL}/api/v1/download/{urllib.parse.quote(model)}"
    organization = [prop("OrganizationName", "Apeirora Demo"),
                    prop("OrganizationOfficialName", "Apeirora Demo")]
    file_version = [
        mlp("Title", [("en", f"{label} 3D model")]),
        prop("FileName", model),
        prop("FileVersionId", "1.0.0"),
        prop("StatusValue", "Released"),
        prop("SetDate", "2026-01-01"),
        # mandatory, but the demo has no preview images: element without a value
        {"modelType": "File", "idShort": "PreviewFile", "contentType": "image/png"},
        file_element("DigitalFile", url, "model/vnd.usd"),
        smc("FileFormat", [prop("FormatName", "USD"), prop("FormatVersion", "0.8"),
                           prop("FormatQualifier", "usdc")]),
        smc("ProvidingOrganization", organization),
    ]
    file = smc("File", [
        sml("FileId", [[prop("FileDomainId", "Apeirora Demo"), prop("ValueId", f"{slug}-3d")]]),
        sml("FileVersion", [file_version]),
        sml("FileClassification", [[prop("ClassId", "02-02"), mlp("ClassName", [("en", "Drawings, plans")]),
                                    prop("ClassificationSystem", "VDI2770:2020")]]),
    ])
    return submodel(
        f"urn:apeirora.eu:sm:demo:{slug}:3d",
        "Models3D",
        SEM_3D,
        [sml("Model3D", [[file]])],
    )


def nameplate_submodel(slug, label, product, serial):
    return submodel(
        f"urn:apeirora.eu:sm:demo:{slug}:nameplate",
        "Nameplate",
        SEM_NAMEPLATE,
        [
            mlp("ManufacturerName", [("en", "Apeirora Demo"), ("de", "Apeirora Demo")]),
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


def entity(id_short, asset_slug, statements):
    return {
        "modelType": "Entity",
        "idShort": id_short,
        "entityType": "SelfManagedEntity",
        "globalAssetId": f"urn:apeirora.eu:asset:demo:{asset_slug}",
        "statements": statements,
    }


def element_ref(submodel_id, *id_shorts):
    """ModelReference to an element inside a submodel, e.g. a BoM node."""
    keys = [{"type": "Submodel", "value": submodel_id}]
    keys += [{"type": "Entity", "value": id_short} for id_short in id_shorts]
    return {"type": "ModelReference", "keys": keys}


def bom_submodel(rack):
    """IDTA 02011 Hierarchical Structures (archetype OneDown): the EntryNode is the rack itself,
    one Node per installed component with a HasPart relationship from the rack to it.
    HeightUnits / PositionFrom are not part of the template; they are our own rack-slot
    extension inside each Node."""
    submodel_id = f"urn:apeirora.eu:sm:demo:{rack['slug']}:bom"
    nodes, relations = [], []
    for c in rack["components"]:
        slot = [prop("HeightUnits", c["height"]), prop("PositionFrom", c["position"])]
        for element in slot:
            element["semanticId"] = external_ref(f"{SEM_RACK_SLOT}/{element['idShort']}")
        nodes.append(entity(c["label"], c["slug"], slot))
        relations.append({
            "modelType": "RelationshipElement",
            "idShort": f"HasPart_{c['label']}",
            "semanticId": external_ref("https://admin-shell.io/idta/HierarchicalStructures/HasPart/1/0"),
            "first": element_ref(submodel_id, "EntryNode"),
            "second": element_ref(submodel_id, "EntryNode", c["label"]),
        })
    entry = entity("EntryNode", rack["slug"], nodes + relations)
    entry["semanticId"] = external_ref("https://admin-shell.io/idta/HierarchicalStructures/EntryNode/1/0")
    for node in nodes:
        node["semanticId"] = external_ref("https://admin-shell.io/idta/HierarchicalStructures/Node/1/0")
    return submodel(submodel_id, "HierarchicalStructures", SEM_BOM, [prop("ArcheType", "OneDown"), entry])


def operational_submodel(slug):
    """Live status of a component. The simulator updates the values; a fresh seed
    also empties LastInspection again (demo reset)."""
    return submodel(
        f"urn:apeirora.eu:sm:demo:{slug}:operational",
        "OperationalData",
        SEM_OPERATIONAL,
        [
            prop("Status", "ok"),
            prop("Temperature", "35.0"),
            prop("PowerDraw", "180"),
            # Empty until a technician sends a report (Experiment 2). It must exist up front:
            # BaSyx checks a POST of a new element as UPDATE on "*", so the technician role
            # (allowed to update LastInspection only) can replace it with PUT, not create it.
            {"modelType": "SubmodelElementCollection", "idShort": "LastInspection", "value": []},
        ],
    )


def asset_shell(item, extra_submodels=()):
    """Returns (shell, submodels) for a rack or component with 3D + nameplate.
    Components (items with a rack position) also get OperationalData."""
    slug, label = item["slug"], item["label"]
    model_3d = three_d_submodel(slug, label, item["model"])
    nameplate = nameplate_submodel(slug, label, item["product"], item["serial"])
    if "position" in item:
        extra_submodels = [*extra_submodels, operational_submodel(slug)]
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
        for item, extra in [({**rack, "model": "ServerRack.usdc"}, [bom_submodel(rack)])] + [
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
