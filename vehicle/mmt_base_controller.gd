# res://vehicle/mmt_base_controller.gd
extends Node
class_name MMTBaseController

@export var target_vehicle: RigidBody3D
@export var auto_possess_on_ready: bool = true

# Use RefCounted for polymorphism. This allows derived controllers to use their
# own specific input state classes (e.g., MMTVehicleInputState, MMTHeliInputState).
var _input_state: RefCounted = null


func _ready() -> void:
	if auto_possess_on_ready and target_vehicle:
		possess(target_vehicle)


func _physics_process(delta: float) -> void:
	if _input_state == null or target_vehicle == null:
		return
	_compute_input(delta)


func possess(vehicle: RigidBody3D) -> void:
	if target_vehicle and target_vehicle != vehicle:
		unpossess()

	target_vehicle = vehicle
	
	# Create the specific input state object using the factory method, which is
	# expected to be overridden by subclasses.
	_input_state = _create_input_state()
	
	if target_vehicle.has_method("set_controller_input"):
		target_vehicle.set_controller_input(_input_state)
		
	_on_possess(vehicle)


func unpossess() -> void:
	if target_vehicle == null:
		return
		
	# Create a blank input state to reset the vehicle's inputs, preventing
	# it from continuing its last action after being unpossessed.
	var blank_input = _create_input_state()
	if target_vehicle.has_method("set_controller_input"):
		target_vehicle.set_controller_input(blank_input)
		
	_on_unpossess(target_vehicle)
	_input_state = null


# -----------------------------------------------------------------------------
# Virtual Functions (for subclasses to override)
# -----------------------------------------------------------------------------

## Factory method for creating the input state object.
## Subclasses should override this to provide their specific state type.
## By default, it returns an input state for ground vehicles.
func _create_input_state() -> RefCounted:
	return MMTVehicleInputState.new()


## Called every physics frame to poll inputs and update the `_input_state` object.
## To be implemented by subclasses.
func _compute_input(_delta: float) -> void:
	pass


## Callback for when this controller possesses a vehicle.
## Can be used for subclass-specific logic.
func _on_possess(_vehicle: RigidBody3D) -> void:
	pass


## Callback for when this controller unpossesses a vehicle.
## Can be used for subclass-specific logic.
func _on_unpossess(_vehicle: RigidBody3D) -> void:
	pass
