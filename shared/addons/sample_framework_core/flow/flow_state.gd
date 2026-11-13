extends Node
class_name FlowState

## One screen/step of an app flow, driven by a StateManager (its parent).
## Call [method go_to] or [method finish] to switch states; the manager handles
## activation, visibility and UI scaling.

## Emitted to ask the StateManager to switch to [param next].
signal change_requested(next: FlowState)

## State [method finish] switches to. Leave empty for the last state.
@export var next_state: FlowState

## Called by StateManager when this state becomes active.
func enter_state() -> void:
	pass

## Called by StateManager when this state becomes inactive.
func exit_state() -> void:
	pass

## Switches to [member next_state].
func finish() -> void:
	go_to(next_state)

## Switches to [param state].
func go_to(state: FlowState) -> void:
	change_requested.emit(state)
