extends Node
class_name MMTFourWheelD

@export var output_front_diff: MMTDifferentialComponent
@export var output_rear_diff: MMTDifferentialComponent
@export_range(0.0,1.0,0.1) var coupling_stiffness:float = 0.0
@export_range(0.0,1.0,0.1) var front_bias:float = 0.635
@onready var rear_bias:float = 1 - front_bias
var front_diff_rpm:float = 0.0
var rear_diff_rpm:float = 0.0

func push_drive_torque(in_torque: float, in_inertia: float, dt: float) -> void:
	var transfer :float = (front_diff_rpm - rear_diff_rpm) * coupling_stiffness * signf(in_torque)
	var front_torque:float = in_torque * front_bias - transfer
	var rear_torque:float = in_torque * rear_bias + transfer
	var front_inertia:float = in_inertia * front_bias
	var rear_inertia:float = in_inertia * rear_bias
	if output_front_diff and output_rear_diff:
		output_front_diff.push_drive_torque(front_torque, front_inertia, dt)
		output_rear_diff.push_drive_torque(rear_torque,rear_inertia,dt)

func get_feedback_rpm(upstream_rpm: float, dt: float) -> float:
	front_diff_rpm = output_front_diff.get_feedback_rpm(upstream_rpm, dt) if output_front_diff  else 0.0
	rear_diff_rpm = output_rear_diff.get_feedback_rpm(upstream_rpm, dt) if output_rear_diff else 0.0
	# 差速器的反馈转速是它两个输出端的平均。
	return (front_diff_rpm + rear_diff_rpm) / 2.0


func get_debug_info() -> Dictionary:
	return {
		"front_diff_rpm": front_diff_rpm,
		"rear_diff_rpm": rear_diff_rpm,
		"transfer": (front_diff_rpm - rear_diff_rpm) * coupling_stiffness,
	}
