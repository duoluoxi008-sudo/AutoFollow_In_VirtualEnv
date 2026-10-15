# res://vehicle/mmt_player_controller.gd
extends MMTBaseController
class_name MMTPlayerController

## MMT Player Controller
##
## Translates player input (e.g., keyboard, gamepad) into an `MMTVehicleInputState`
## data object.
##
## This controller is designed to be decoupled from the vehicle's internal logic.
## It communicates solely through the `_input_state` object, similar to the role
## of APlayerController in Unreal Engine.

@export_group("Input Actions")
@export var action_forward:       String = "forward"
@export var action_backward:      String = "backward"
@export var action_steer_left:    String = "left"
@export var action_steer_right:   String = "right"
@export var action_brake:         String = "brake"
@export var action_shift_up:      String = "shift_up"
@export var action_shift_down:    String = "shift_down"
@export var action_toggle_auto:   String = "toggle_auto_shift"


func _compute_input(_delta: float) -> void:
	# This controller is specifically for ground vehicles, so it expects
	# the state object to be of type MMTVehicleInputState.
	var state := _input_state as MMTVehicleInputState
	if not state:
		return

	# Poll analog inputs for continuous control.
	state.throttle_forward = Input.get_action_strength(action_forward)
	state.throttle_back    = Input.get_action_strength(action_backward)
	state.steer_axis       = Input.get_axis(action_steer_right, action_steer_left)
	state.brake            = Input.get_action_strength(action_brake)

	# Poll pulse events for single-frame actions.
	if Input.is_action_just_pressed(action_shift_up):
		state.shift_up_pulse = true
	if Input.is_action_just_pressed(action_shift_down):
		state.shift_down_pulse = true
	if Input.is_action_just_pressed(action_toggle_auto):
		state.toggle_auto_shift_pulse = true
