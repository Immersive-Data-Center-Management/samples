class_name RackComponents

## Turns the rack inventory in the AAS into one assembled 3D rack (Experiments 1 and 2).
## The AAS tells us which parts are installed, their slots and their model URLs.
## This helper describes how to assemble those models; IDTXFlow loads and renders them.
## No hand-placed Godot node per component is needed.
##
## Call sequence:
## 1. await fetch(aas, rack_shell_id): read the rack's bill of material (IDTA HierarchicalStructures)
##    into dictionaries.
## 2. await resolve_models(aas, components): add each component's shell id and USD model URL.
## 3. load_rack(stage, rack_url, components): build a session layer and request the composed
##    stage load. The caller supplies the rack model URL separately; loading is asynchronous.
##
## A session layer is USD text added over the rack model at load time: it references each
## component file as a payload and gives it a position. It does not modify the source files.
## Each component dictionary has identifier, global_asset_id, height_units, position_from,
## shell_id and model_url. session_layer() also assigns prim_name to placed components;
## StageSelection uses that name to map clicked geometry back to the component identifier.
##
## Example (seed data). The rack's HierarchicalStructures submodel (archetype OneDown) contains
## the rack as EntryNode, one Node entity per installed component, and a HasPart relationship
## per component (omitted here). HeightUnits/PositionFrom are the samples' own extension:
##
##   {"idShort": "EntryNode", "modelType": "Entity", "globalAssetId": "urn:apeirora.eu:asset:demo:rack-01",
##    "statements": [
##     {"idShort": "DemoServer01", "modelType": "Entity", "globalAssetId": "urn:apeirora.eu:asset:demo:server-01",
##      "statements": [
##       {"idShort": "HeightUnits", "modelType": "Property", "value": "1"},
##       {"idShort": "PositionFrom", "modelType": "Property", "value": "2"}]}]}
##
## fetch() turns this into
##
##   {"identifier": "DemoServer01", "global_asset_id": "urn:apeirora.eu:asset:demo:server-01",
##    "height_units": "1", "position_from": "2", "shell_id": "", "model_url": ""}
##
## resolve_models() finds the shell whose assetInformation.globalAssetId is
## that asset id, and takes the URL from the DigitalFile element of its
## Models3D submodel (IDTA 02026):
##
##   "shell_id": "urn:apeirora.eu:aas:demo:server-01",
##   "model_url": "http://127.0.0.1:8080/api/v1/download/Server_00.usdc"
##
## session_layer() then returns this layer. It is composed over the rack
## stage, whose root prim is "root", whose feet stand on Z = 0 and whose slot 0
## is RACK_SLOT_0_Z_M above that:
##
##   #usda 1.0
##
##   over "root"
##   {
##     def Xform "AAS_Component_0" (
##       prepend payload = @http://127.0.0.1:8080/api/v1/download/Server_00.usdc@
##     )
##     {
##       double3 xformOp:translate = (0, 0, 0.186900)   # 0.098 m + PositionFrom 2 * 0.04445 m
##       uniform token[] xformOpOrder = ["xformOp:translate"]
##     }
##   }
##
## The payload brings the component file's default prim in under the Xform, so
## the component's bottom (Z = 0 in its own file) ends up at the slot height.
## These are the samples' asset conventions, not a general rack-layout solver:
## HeightUnits is kept as data, but does not resize models or check for overlapping slots.
## Components without a model URL or PositionFrom stay in the data but are not placed.

## Semantic ids of the submodels the samples read (see shared/deploy/seed/seed.py).
## IDTA 02011 Hierarchical Structures enabling Bills of Material
const BOM_SEMANTIC_ID := "https://admin-shell.io/idta/HierarchicalStructures/1/1/Submodel"
## IDTA 02026 Provision of 3D Models
const MODELS3D_SEMANTIC_ID := "https://admin-shell.io/idta/Models3D/1/0"
const OPERATIONAL_SEMANTIC_ID := "urn:apeirora.eu:smt:operationalData:0.1"
const NAMEPLATE_SEMANTIC_ID := "https://admin-shell.io/idta/nameplate/3/0/Nameplate"
const RACK_U_HEIGHT_M := 0.04445
## Height of rack slot 0 above the rack's feet (plinth), see shared/deploy/assets/README.md.
const RACK_SLOT_0_Z_M := 0.098
const RACK_ROOT_PRIM := "root"


## Installed components of the rack, with shell_id/model_url initially empty; [] if none.
static func fetch(aas: AasService, rack_shell_id: String) -> Array:
	var bom := await aas.find_submodel_by_semantic_id(rack_shell_id, BOM_SEMANTIC_ID)
	return parse_bom(bom)


## Child Node entities of the EntryNode, parsed by parse_installed_component(). With the
## OneDown archetype these are exactly the parts installed in the rack (no deeper levels).
static func parse_bom(bom: Dictionary) -> Array:
	var components: Array = []
	for element in bom.get("submodelElements", []):
		if element is Dictionary and element.get("modelType") == "Entity" and element.get("idShort") == "EntryNode":
			for node in element.get("statements", []):
				if node is Dictionary and node.get("modelType") == "Entity":
					var parsed := parse_installed_component(node)
					if not parsed.is_empty():
						components.append(parsed)
	return components


## Fills shell_id and model_url of each component in place.
static func resolve_models(aas: AasService, components: Array) -> void:
	var asset_to_shell := {}
	for shell in await aas.fetch_all_shells():
		if shell is Dictionary and shell.get("assetInformation") is Dictionary:
			var gaid := str(shell["assetInformation"].get("globalAssetId", ""))
			if not gaid.is_empty():
				asset_to_shell[gaid] = shell

	# All Models3D submodels in one request, instead of searching each shell's submodels.
	var model_urls := {}
	for model in await aas.fetch_submodels_by_semantic_id(MODELS3D_SEMANTIC_ID):
		model_urls[str(model.get("id", ""))] = aas.reachable_url(AasService.find_file_value(model))

	for comp in components:
		var shell: Dictionary = asset_to_shell.get(comp["global_asset_id"], {})
		if shell.is_empty():
			push_warning("RackComponents: no shell for asset '%s'." % comp["global_asset_id"])
			continue
		comp["shell_id"] = str(shell.get("id", ""))
		for id in AasService.extract_submodel_ids(shell):
			if model_urls.has(id):
				comp["model_url"] = model_urls[id]


## USDA layer with one payload Xform "AAS_Component_N" per placeable component
## directly under the rack root, raised by PositionFrom rack units. Sets
## prim_name on the placed components. Returns "" if nothing can be placed.
static func session_layer(components: Array) -> String:
	var layer := ""
	var index := 0
	for comp in components:
		comp.erase("prim_name")
		if str(comp.get("position_from", "")).is_empty() or str(comp.get("model_url", "")).is_empty():
			continue
		comp["prim_name"] = "AAS_Component_%d" % index
		index += 1
		layer += "  def Xform \"%s\" (\n" % comp["prim_name"]
		layer += "    prepend payload = @%s@\n" % comp["model_url"]
		layer += "  )\n"
		layer += "  {\n"
		layer += "    double3 xformOp:translate = (0, 0, %.6f)\n" % (RACK_SLOT_0_Z_M + int(comp["position_from"]) * RACK_U_HEIGHT_M)
		layer += "    uniform token[] xformOpOrder = [\"xformOp:translate\"]\n"
		layer += "  }\n\n"
	if layer.is_empty():
		return ""
	return "#usda 1.0\n\nover \"%s\"\n{\n%s}\n" % [RACK_ROOT_PRIM, layer]


## Loads [param rack_url] into [param stage] (a UsdStageNode3D) with every placeable
## component of [param components] in its slot (session_layer()), so the AAS data
## becomes one composed USD rack.
static func load_rack(stage: Node3D, rack_url: String, components: Array) -> void:
	var layer := session_layer(components)
	if layer.is_empty():
		stage.remove_meta(&"USD_OVERRIDE_LAYER")
	else:
		stage.set_meta(&"USD_OVERRIDE_LAYER", layer)
		stage.set_meta(&"USD_OVERRIDE_LAYERID", "user://aas_models/local_composition.usd")
	# set_stage_uri with an unchanged value would not reload the stage
	stage.set_stage_uri("")
	stage.set_stage_uri(rack_url)


## One BoM Node entity: idShort is the component identifier, globalAssetId its asset;
## its statements hold HeightUnits/PositionFrom.
static func parse_installed_component(comp: Dictionary) -> Dictionary:
	var identifier := str(comp.get("idShort", ""))
	if identifier.is_empty():
		return {}
	var result := {
		"identifier": identifier,
		"global_asset_id": str(comp.get("globalAssetId", "")),
		"height_units": "",
		"position_from": "",
		"shell_id": "",
		"model_url": "",
	}
	var sub_elements: Variant = comp.get("statements", [])
	if not sub_elements is Array:
		return result
	for elem in sub_elements:
		if not elem is Dictionary:
			continue
		var elem_id := str(elem.get("idShort", ""))
		if elem_id == "HeightUnits":
			result["height_units"] = str(elem.get("value", ""))
		elif elem_id == "PositionFrom":
			result["position_from"] = str(elem.get("value", ""))
	return result
