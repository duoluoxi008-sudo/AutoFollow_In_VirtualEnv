# res://vehicle/mmt_differential_component.gd
extends MMTDrivetrainNodeTEMP
class_name MMTDifferentialComponent

@export_category("连接")
@export var output_left: Node
@export var output_right: Node

@export_category("规格")
@export var is_driven: bool = true
## 一个 0.0 到 1.0 的系数，控制从较快车轮向较慢车轮转移多少扭矩，
## 以抵消打滑。
@export_range(0.0, 1.0) var limited_slip_factor: float = 0.0

var _cached_rpm_left: float = 0.0
var _cached_rpm_right: float = 0.0

func get_feedback_rpm(upstream_rpm: float, dt: float) -> float:
	if not is_driven: return 0.0

	_cached_rpm_left = output_left.get_feedback_rpm(upstream_rpm, dt) if output_left and output_left.has_method("get_feedback_rpm") else 0.0
	_cached_rpm_right = output_right.get_feedback_rpm(upstream_rpm, dt) if output_right and output_right.has_method("get_feedback_rpm") else 0.0

	# 差速器的反馈转速是它两个输出端的平均。
	return (_cached_rpm_left + _cached_rpm_right) / 2.0

func push_drive_torque(in_torque: float, in_inertia: float, dt: float) -> void:
	if not is_driven: return

	var base_torque = in_torque * 0.5
	var rpm_diff = _cached_rpm_left - _cached_rpm_right
	var lsd_transfer = rpm_diff * limited_slip_factor * 2.0

	if output_left and output_left.has_method("push_drive_torque"):
		output_left.push_drive_torque(base_torque - lsd_transfer, in_inertia * 0.5, dt)
	if output_right and output_right.has_method("push_drive_torque"):
		output_right.push_drive_torque(base_torque + lsd_transfer, in_inertia * 0.5, dt)

func get_debug_info() -> Dictionary:
	return {
		"rpm_left": _cached_rpm_left,
		"rpm_right": _cached_rpm_right,
		"ls_factor": limited_slip_factor
	}
