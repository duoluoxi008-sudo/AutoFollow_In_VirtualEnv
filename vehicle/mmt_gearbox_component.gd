# res://vehicle/mmt_gearbox_component.gd
extends Node
class_name MMTGearboxComponentTEMP

@export_category("连接")
@export var output_node: Node

@export_category("变速箱类型")
@export var is_automatic: bool = true
@export var auto_reverse: bool = true
@export var use_fluid_coupling: bool = false

@export_category("发动机同步（对手动/离合至关重要）")
# 这些数值必须与所连接的发动机组件一致，以保证计算准确。
@export var engine_idle_rpm: float = 800.0
@export var engine_max_rpm: float = 6000.0

@export_category("变速箱参数")
@export var gear_ratios: Array[float] = [-4.73, 0.0, 4.73, 2.73, 1.71, 1.13, 0.81]
@export var final_drive_ratio: float = 5.7

@export_category("自动换挡")
@export var shift_up_rpm: float = 1800.0
@export var shift_down_rpm: float = 850.0
@export var shift_duration: float = 0.6
@export var kickdown_up_rpm: float = 1950.0
@export var kickdown_down_rpm: float = 1100.0

@export_category("智能 TCU 逻辑")
## 在大负荷（例如爬坡）时禁止升挡，适用于卡车/坦克。
@export var enable_heavy_load_logic: bool = false
@export var shift_cooldown: float = 1.0
@export var inhibit_upshift_while_steering: bool = false
@export var steer_inhibit_threshold: float = 0.15
## 防止换挡来回跳动（shift hunting）：升挡后的预期转速必须比降挡点高出这么多。
@export var expected_rpm_margin: float = 200.0

var current_gear_index: int = 1
var _target_gear_index: int = 1
var shift_timer: float = 0.0
var clutch_engagement: float = 1.0
var _current_tc_multiplier: float = 1.0
var _last_throttle_intent: float = 0.0
var _post_shift_timer: float = 0.0
var _last_forward_speed: float = 0.0 # 用于计算加速度

func shift_up() -> void:
	if current_gear_index < gear_ratios.size() - 1 and shift_timer <= 0.0:
		_shift_to(current_gear_index + 1)

func shift_down() -> void:
	if current_gear_index > 0 and shift_timer <= 0.0:
		_shift_to(current_gear_index - 1)

func shift_to_gear(target_gear: int) -> void:
	if target_gear >= 0 and target_gear < gear_ratios.size() and shift_timer <= 0.0:
		_shift_to(target_gear)

func _shift_to(target_gear: int) -> void:
	if target_gear != current_gear_index:
		_target_gear_index = target_gear
		shift_timer = shift_duration

func get_current_ratio() -> float:
	var idx = _target_gear_index if shift_timer > 0.0 else current_gear_index
	if idx >= 0 and idx < gear_ratios.size():
		return gear_ratios[idx] * final_drive_ratio
	return 0.0

func update_shift_logic(engine_rpm: float, throttle_intent: float, forward_speed: float, dt: float, steer_intent: float = 0.0) -> void:
	_last_throttle_intent = abs(throttle_intent)

	var accel = (forward_speed - _last_forward_speed) / dt if dt > 0.0 else 0.0
	_last_forward_speed = forward_speed

	if _post_shift_timer > 0.0:
		_post_shift_timer -= dt

	if shift_timer > 0.0:
		shift_timer -= dt
		var progress = 1.0 - shift_timer / shift_duration
		if progress < 0.5:
			clutch_engagement = lerp(1.0, 0.0, progress * 2.0)
		else:
			if current_gear_index != _target_gear_index:
				current_gear_index = _target_gear_index
				_post_shift_timer = shift_cooldown
			clutch_engagement = lerp(0.0, 1.0, pow((progress - 0.5) * 2.0, 2.0))
		return

	clutch_engagement = 1.0
	_target_gear_index = current_gear_index
	if not is_automatic: return

	# 起步逻辑。
	var is_pressing_forward = throttle_intent > 0.1
	var is_pressing_backward = throttle_intent < -0.1

	if abs(forward_speed) < 1.0:
		if is_pressing_forward and current_gear_index <= 1:
			shift_to_gear(2) # 挡位索引 1 是空挡（Neutral），因此换到索引 2（物理 1 挡）。
			return
		elif is_pressing_backward and current_gear_index >= 1 and auto_reverse:
			shift_to_gear(0) # 换到倒挡。
			return

	# --- 智能 TCU 换挡逻辑 ---
	# 仅在物理 1 挡及以上、且当前未在换挡时，才应用自动换挡逻辑。
	if current_gear_index >= 2 and _post_shift_timer <= 0.0:
		var dynamic_up = shift_up_rpm
		var dynamic_down = shift_down_rpm

		# 在大油门（kickdown）下应用更激进的换挡点。
		if _last_throttle_intent > 0.7:
			dynamic_up = kickdown_up_rpm
			dynamic_down = kickdown_down_rpm

		var is_steering_hard = inhibit_upshift_while_steering and abs(steer_intent) > steer_inhibit_threshold

		# --- 发动机红线保护 ---
		# 若发动机濒临爆转，强制升挡，忽略其它逻辑。
		var is_redlining = engine_rpm > (engine_max_rpm * 0.98)

		var can_upshift_safely = true
		if current_gear_index < gear_ratios.size() - 1 and not is_redlining:
			var current_ratio = abs(gear_ratios[current_gear_index])
			var next_ratio = abs(gear_ratios[current_gear_index + 1])

			if current_ratio > 0.01:
				var expected_rpm = engine_rpm * (next_ratio / current_ratio)

				# 1. 基础防跳动：若升挡后转速过低则禁止升挡。
				if expected_rpm < (dynamic_down + expected_rpm_margin):
					can_upshift_safely = false

				# 2. 大负荷逻辑：全油门且加速度很低时（例如爬坡）不要升挡。
				# 该加速度阈值按重型车辆调校。
				if enable_heavy_load_logic and accel < 0.2 and _last_throttle_intent > 0.8:
					can_upshift_safely = false

		# 若正处于红线区，则覆盖安全检查以防止发动机损坏。
		if is_redlining:
			can_upshift_safely = true

		# --- 最终判定 ---
		# 若转速足够高、有油门输入且换挡安全，则升挡。
		if engine_rpm > dynamic_up and _last_throttle_intent > 0.1:
			if not is_steering_hard and can_upshift_safely:
				shift_up()
		# 若转速过低则降挡，但需结合检查以避免非预期行为。
		elif engine_rpm < dynamic_down:
			# 增加油门检查，防止滑行时过早降挡。
			# 同时，如果正在红线区则不要降挡（罕见情况下可能发生）。
			if (_last_throttle_intent > 0.1 or engine_rpm < 1100.0) and not is_redlining:
				# 不要从物理 1 挡自动挂入空挡。
				if current_gear_index > 2:
					shift_down()

func get_feedback_rpm(upstream_rpm: float, dt: float) -> float:
	var out_rpm = output_node.get_feedback_rpm(upstream_rpm, dt) if output_node and output_node.has_method("get_feedback_rpm") else 0.0
	var ratio = get_current_ratio()
	var mechanical_rpm = abs(out_rpm * ratio)

	if clutch_engagement >= 0.99:
		if use_fluid_coupling:
			# ...（此处将实现液力变矩器逻辑）
			return mechanical_rpm
		else: # 直接离合（Direct clutch）
			return mechanical_rpm

	# 当离合分离时，发动机转速向基于油门的目标值逼近。
	var free_target = engine_idle_rpm + (engine_max_rpm - engine_idle_rpm) * _last_throttle_intent
	var free_rpm = move_toward(upstream_rpm, free_target, (engine_max_rpm * 0.8) * dt)
	return lerp(free_rpm, mechanical_rpm, clutch_engagement)

func push_drive_torque(in_torque: float, in_inertia: float, dt: float) -> void:
	var ratio = get_current_ratio()
	var out_torque: float

	if use_fluid_coupling:
		# 液力耦合会削弱发动机制动。
		out_torque = in_torque * _current_tc_multiplier * ratio * clutch_engagement if in_torque > 0 else in_torque * 0.15 * ratio * clutch_engagement
	else:
		out_torque = in_torque * ratio * clutch_engagement

	var out_inertia = in_inertia * (ratio * ratio) * clutch_engagement

	if output_node and output_node.has_method("push_drive_torque"):
		output_node.push_drive_torque(out_torque, out_inertia, dt)

func get_debug_info() -> Dictionary:
	return {
		"current_gear": current_gear_index,
		"current_ratio": get_current_ratio(),
		"is_shifting": shift_timer > 0.0,
		"clutch": clutch_engagement,
		"tc_multiplier": _current_tc_multiplier,
	}
