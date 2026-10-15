# res://vehicle/mmt_engine_component.gd
extends Node
class_name MMTEngineComponentTEMP

@export_category("连接")
@export var output_node: Node ## 通常连接到一个变速箱（Gearbox）或旋翼（Rotor）节点。

@export_category("发动机参数")
@export var max_rpm: float = 6000.0
@export var rev_limiter_rpm: float = 6400.0
@export var idle_rpm: float = 800.0
@export var max_torque: float = 155.0
@export var torque_curve: Curve

@export_category("发动机动力学")
@export var engine_drag_base: float = 12.0
@export var engine_drag_multiplier: float = 0.008
@export var engine_inertia: float = 0.15

var current_rpm: float = 0.0
var throttle: float = 0.0

func get_output_torque(feedback_rpm: float) -> float:
	current_rpm = max(feedback_rpm, 0.0)

	# 1. 内部机械阻力，始终存在。
	var internal_drag = engine_drag_base + current_rpm * engine_drag_multiplier
	# 超过红线转速后，额外增加显著的阻力惩罚。
	if current_rpm > max_rpm:
		internal_drag += (current_rpm - max_rpm) * 0.5

	# 2. 基于油门输入和扭矩曲线计算驾驶员请求的扭矩。
	var torque_mult: float
	if torque_curve:
		torque_mult = torque_curve.sample_baked(clamp(current_rpm / max_rpm, 0.0, 1.0))
	else:
		# 若未提供扭矩曲线，则用正弦曲线作为回退。
		torque_mult = sin(clamp(current_rpm / max_rpm, 0.0, 1.0) * PI)

	# 模拟限速器（rev limiter）的断油。
	var fuel_cut = 0.0 if current_rpm > rev_limiter_rpm else 1.0
	var driver_torque = max_torque * torque_mult * throttle * fuel_cut

	# 3. 怠速控制（ECU 防熄火）。
	# 仅在松开油门且转速接近怠速时激活，以防止熄火。
	var idle_torque = 0.0
	if throttle <= 0.05 and current_rpm < idle_rpm + 200.0:
		var rpm_drop = idle_rpm - current_rpm
		# ECU 的目标是：补偿内部阻力、维持怠速，并额外提供
		# 一小部分扭矩用于自动变速箱蠕行（+15 Nm）。
		# 注意：internal_drag 最后会在全局减去，以避免重复计算。
		var raw_idle_target = rpm_drop * 1.5 + 15.0
		idle_torque = clamp(raw_idle_target, 0.0, max_torque * 0.85)

	# 最终净输出扭矩。
	# 示例：
	# - 高速滑行：driver=0, idle=0 -> 输出为负 = 发动机制动。
	# - 怠速/蠕行：driver=0, idle≈27 -> 净输出≈15 Nm (27-12=15)。
	# - 全油门：driver=155, idle=0 -> 净输出≈143 Nm。
	return (driver_torque + idle_torque) - internal_drag

## 传动系仿真的双向数据流。
func process_drivetrain(dt: float) -> void:
	# 第 1 遍：从下游组件（如变速箱）获取最终转速。
	var target_rpm = current_rpm
	if output_node and output_node.has_method("get_feedback_rpm"):
		target_rpm = output_node.get_feedback_rpm(current_rpm, dt)

	# 发动机（暂）不会熄火，因此以怠速转速作为下限强制约束。
	current_rpm = max(target_rpm, idle_rpm)

	# 第 2 遍：把计算得到的扭矩传递给下游组件。
	var out_torque = get_output_torque(current_rpm)
	if output_node and output_node.has_method("push_drive_torque"):
		output_node.push_drive_torque(out_torque, engine_inertia, dt)

func get_debug_info() -> Dictionary:
	return {
		"rpm": current_rpm,
		"max_rpm": max_rpm,
		"throttle": throttle,
		"output_torque": get_output_torque(current_rpm),
	}
