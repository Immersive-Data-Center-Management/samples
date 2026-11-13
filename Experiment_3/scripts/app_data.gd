extends Node

## Autoload "AppData": the (fake) data of each part, shown in the AR view and updated by
## FakeTelemetry.

## Per-object info shown in the AR view's bottom menu when an object is picked, keyed by the
## PickableObject's object_id. Fake data on purpose: this experiment shows AR, not the AAS
## (see Experiment_2 for live AAS data). Dictionaries preserve insertion order, so the display
## order below is the order shown.
var object_data: Dictionary = {
	"Server_00_usdc": {
		"Name": "Server_00",
		"Type": "1U rack server",
		"Position": "U 13",
		"Serial": "SRV-1U-24017",
		"Last Maintenance": "Firmware updated to 2.4.1",
		"Status": "Operational",
	},
	"Server_01_usdc": {
		"Name": "Server_01",
		"Type": "2U rack server",
		"Position": "U 10-11",
		"Serial": "SRV-2U-24102",
		"Last Maintenance": "Fan module replaced",
		"Status": "Operational",
	},
	"Server_02_usdc": {
		"Name": "Server_02",
		"Type": "2U rack server",
		"Position": "U 8-9",
		"Serial": "SRV-2U-24103",
		"Last Maintenance": "Installed, configuration pending",
		"Status": "Operational",
	},
	"Server_03_usdc": {
		"Name": "Server_03",
		"Type": "3U storage server, 18 drives",
		"Position": "U 14-16",
		"Serial": "STO-3U-23988",
		"Last Maintenance": "Drive 7 replaced",
		"Status": "Operational",
	},
	"PowerSupply_00_usdc": {
		"Name": "PDU",
		"Type": "3U power distribution unit",
		"Position": "U 22-24",
		"Serial": "PDU-3U-22051",
		"Last Maintenance": "Breakers tested",
		"Status": "Operational",
	},
	"NetworkSwitch_00_usdc": {
		"Name": "NetworkSwitch",
		"Type": "1U switch, 48 x RJ45 + 4 x SFP",
		"Position": "U 20",
		"Serial": "NSW-1U-24330",
		"Last Maintenance": "Firmware updated to 10.13",
		"Status": "Operational",
	},
}

## Returns the info dictionary for [param object_id], or an empty dictionary if unknown.
func get_object_data(object_id: String) -> Dictionary:
	return object_data.get(object_id, {})
