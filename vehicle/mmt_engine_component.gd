# res://vehicle/mmt_engine_component.gd
extends Node
class_name MMTEngineComponentTEMP

# 规格缺省兜底值（仅在 spec 为空时使用，并会给出一次警告）。
const FALLBACK_IDLE_RPM := 800.0
const FALLBACK_MAX_RPM := 6000.0
const FALLBACK_REV_LIMITER_RPM := 6400.0
const FALLBACK_MAX_TORQUE := 155.0
const FALLBACK_DRAG_BASE := 12.0
const FALLBACK_DRAG_MULTIPLIER := 0.008
const FALLBACK_INERTIA := 0.15

@export_category("连接")
@export var output_node: Node ## 通常连接到一个变速箱（Gearbox）或旋翼（Rotor）节点。

@export_category("规格")
## 发动机规格资源：扭矩 / 转速 / 惯量的唯一真相来源。
## 换发动机或改装 = 换一份 .tres（建议 EngineSpec.duplicate_spec() 后改名再调）。
## 变速箱会通过 set_engine_spec() 自动拿到同一份规格，不再需要手工对齐参数。
@export var spec: EngineSpec

@export_category("运行时修正（天气 / 海拔 / 温度 / 损伤）")
## 输出扭矩的整体倍率，1.0 = 规格原值。
## 天气、高原进气稀薄、进气过热等系统在运行时写它。
## 不要直接改 spec：那是共享资源，改了会同时影响所有使用它的车。
## 例：高原 0.85、进气过热 0.9。
@export_range(0.0, 2.0) var torque_scale: float = 1.0

# --- 规格只读访问器 ---
# 保留 engine.max_rpm / engine.idle_rpm 等旧调用点（调试面板、AI 控制器、
# 车辆复位器都在读），但它们不再是"可以被各处改写的副本"，一律来源于 spec。
var idle_rpm: float:
	get: return spec.idle_rpm if spec else FALLBACK_IDLE_RPM
var max_rpm: float:
	get: return spec.max_rpm if spec else FALLBACK_MAX_RPM
var rev_limiter_rpm: float:
	get: return spec.rev_limiter_rpm if spec else FALLBACK_REV_LIMITER_RPM
var max_torque: float:
	get: return spec.max_torque if spec else FALLBACK_MAX_TORQUE
var torque_curve: Curve:
	get: return spec.torque_curve if spec else null
var engine_drag_base: float:
	get: return spec.engine_drag_base if spec else FALLBACK_DRAG_BASE
var engine_drag_multiplier: float:
	get: return spec.engine_drag_multiplier if spec else FALLBACK_DRAG_MULTIPLIER
var engine_inertia: float:
	get: return spec.engine_inertia if spec else FALLBACK_INERTIA

var current_rpm: float = 0.0
var throttle: float = 0.0

# 规格推送去重：只在 spec 变化时通知下游，运行中换发动机也能自动跟上。
var _pushed_spec: EngineSpec = null


func _ready() -> void:
	if spec == null:
		push_warning("%s 未指定 EngineSpec，正在使用内置兜底参数（max_torque=%.0f, max_rpm=%.0f, idle_rpm=%.0f）"
			% [name, FALLBACK_MAX_TORQUE, FALLBACK_MAX_RPM, FALLBACK_IDLE_RPM])


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
	# torque_scale 只作用于"驾驶员请求扭矩"：环境/海拔影响的是发动机出力，
	# 不应连带缩放内部阻力（否则发动机制动会随天气乱变）。
	var driver_torque = max_torque * torque_mult * throttle * fuel_cut * torque_scale

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
	# 规格同步：变速箱没有指回引擎的引用（协议只允许向下引用），
	# 所以由我们把规格推给它。只在 spec 变化时推一次。
	if output_node and output_node.has_method("set_engine_spec") and _pushed_spec != spec:
		_pushed_spec = spec
		output_node.set_engine_spec(spec)

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
		"torque_scale": torque_scale,
		"spec": spec.resource_path if spec else "<内建兜底>",
	}
