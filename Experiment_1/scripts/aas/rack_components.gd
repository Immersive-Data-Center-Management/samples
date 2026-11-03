class_name RackComponents

## Reads the components installed in a rack from the AAS and builds the USD
## session layer that places their 3D models in the rack.
##
## Rack shell -> RackUsage submodel -> InstalledComponents (identifier, asset
## id, height/position in rack units) -> component shell -> 3D-asset submodel
## -> model URL. Each component is a Dictionary with the keys identifier,
## global_asset_id, height_units, position_from, shell_id, model_url and, once
## placed in the session layer, prim_name.
##
## Example (seed data). The rack's RackUsage submodel contains:
##
##   {"idShort": "InstalledComponents", "modelType": "SubmodelElementCollection", "value": [
##     {"idShort": "DemoServer01", "modelType": "SubmodelElementCollection", "value": [
##       {"idShort": "Asset", "modelType": "Entity", "globalAssetId": "urn:apeirora.eu:asset:demo:server-01"},
##       {"idShort": "HeightUnits", "modelType": "Property", "value": "1"},
##       {"idShort": "PositionFrom", "modelType": "Property", "value": "2"}]}]}
##
## fetch() turns this into
##
##   {"identifier": "DemoServer01", "global_asset_id": "urn:apeirora.eu:asset:demo:server-01",
##    "height_units": "1", "position_from": "2", "shell_id": "", "model_url": ""}
##
## resolve_models() finds the shell whose assetInformation.globalAssetId is
## that asset id, and takes the URL from the first File element of its
## 3D-asset submodel:
##
##   "shell_id": "urn:apeirora.eu:aas:demo:server-01",
##   "model_url": "http://127.0.0.1:8080/api/v1/download/Server_00.usdc"
##
## session_layer() then returns this layer. It is composed over the rack
## stage, whose root prim is "root" and whose bottom is at Z = 0:
##
##   #usda 1.0
##
##   over "root"
##   {
##     def Xform "AAS_Component_0" (
##       prepend payload = @http://127.0.0.1:8080/api/v1/download/Server_00.usdc@
##     )
##     {
##       double3 xformOp:translate = (0, 0, 0.088900)   # PositionFrom 2 * 0.04445 m
##       uniform token[] xformOpOrder = ["xformOp:translate"]
##     }
##   }
##
## The payload brings the component file's default prim in under the Xform, so
## the component's bottom (Z = 0 in its own file) ends up at the slot height.
## Clicks on the component are mapped back to the AAS entry through prim_name
## ("AAS_Component_0").

const RACK_USAGE_SEMANTIC_ID := "urn:apeirora.eu:smt:rackUsage:0.1"
const MODELS3D_SEMANTIC_ID := "urn:apeirora.eu:smt:3dAssets:0.1"
const RACK_U_HEIGHT_M := 0.04445
const RACK_ROOT_PRIM := "root"


## Installed components of the rack without shell_id/model_url, [] if none.
static func fetch(aas: AasService, rack_shell_id: String) -> Array:
	var rack_usage := await aas.find_submodel_by_semantic_id(rack_shell_id, RACK_USAGE_SEMANTIC_ID)
	var components: Array = []
	for element in rack_usage.get("submodelElements", []):
		if element is Dictionary and element.get("idShort") == "InstalledComponents":
			for comp in element.get("value", []):
				if comp is Dictionary:
					var parsed := parse_installed_component(comp)
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

	for comp in components:
		var shell: Dictionary = asset_to_shell.get(comp["global_asset_id"], {})
		if shell.is_empty():
			print("[DEBUG] RackComponents: No shell for asset '%s'." % comp["global_asset_id"])
			continue
		comp["shell_id"] = str(shell.get("id", ""))
		var model := await aas.find_submodel(AasService.extract_submodel_ids(shell), MODELS3D_SEMANTIC_ID)
		comp["model_url"] = AasService.find_file_value(model)


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
		layer += "    double3 xformOp:translate = (0, 0, %.6f)\n" % (int(comp["position_from"]) * RACK_U_HEIGHT_M)
		layer += "    uniform token[] xformOpOrder = [\"xformOp:translate\"]\n"
		layer += "  }\n\n"
	if layer.is_empty():
		return ""
	return "#usda 1.0\n\nover \"%s\"\n{\n%s}\n" % [RACK_ROOT_PRIM, layer]


## One InstalledComponent collection: idShort is the component identifier;
## children are an Entity (globalAssetId) and HeightUnits/PositionFrom.
static func parse_installed_component(comp: Dictionary) -> Dictionary:
	var identifier := str(comp.get("idShort", ""))
	if identifier.is_empty():
		return {}
	var result := {
		"identifier": identifier,
		"global_asset_id": "",
		"height_units": "",
		"position_from": "",
		"shell_id": "",
		"model_url": "",
	}
	var sub_elements: Variant = comp.get("value", [])
	if not sub_elements is Array:
		return result
	for elem in sub_elements:
		if not elem is Dictionary:
			continue
		var elem_id := str(elem.get("idShort", ""))
		if str(elem.get("modelType", "")) == "Entity" or elem.has("globalAssetId"):
			var gaid := str(elem.get("globalAssetId", ""))
			if not gaid.is_empty():
				result["global_asset_id"] = gaid
		elif elem_id == "HeightUnits":
			result["height_units"] = str(elem.get("value", ""))
		elif elem_id == "PositionFrom":
			result["position_from"] = str(elem.get("value", ""))
	return result
