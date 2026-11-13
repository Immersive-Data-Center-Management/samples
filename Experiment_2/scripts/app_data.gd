extends Node

## Autoload "AppData": what the flow states hand to each other besides the login (that is the
## "Session" autoload, an AasSession): the rack being checked and the open task.

## Rack whose components are checked. One rack keeps the demo simple; QR codes of other racks
## are reported as "not in this rack".
const RACK_SHELL_ID := "urn:apeirora.eu:aas:demo:rack-01"
const RACK_NAME := "Rack 01"

## Components of the rack (RackComponents dictionaries, with shell_id and model_url resolved),
## each with an extra "operational_id" (its OperationalData submodel id) once loaded.
var components: Array = []
## The component that needs an on-site check, or {} if all are fine.
var task: Dictionary = {}

## The component whose shell id is [param shell_id], or {}.
func component_by_shell(shell_id: String) -> Dictionary:
	for comp in components:
		if comp.get("shell_id") == shell_id:
			return comp
	return {}
