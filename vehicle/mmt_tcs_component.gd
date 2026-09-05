# res://vehicle/mmt_tcs_component.gd
extends Node
class_name MMTTCSComponent

## =====================================================================
## MMT 牵引力控制系统（TCS）组件
##
## 职责：监视驱动轮的纵向滑移率。
## 若滑移率超过阈值，则向 MMTInputFilterComponent 注入一个 `throttle_limit`
## 以降低有效油门，防止车轮打滑。
##
## 核心算法：
##   slip_ratio = (轮面速度 - 车轮处车速) / max(车轮处车速, 最小速度)
##   当 slip_ratio > slip_threshold 时，收紧 throttle_limit。
##   当 slip_ratio 回落时，缓慢释放 throttle_limit。
##
## 设计：一个纯计算节点。它读取车轮状态并把限制信号写入 InputFilter。
## 这是一个可选组件；没有它时车辆将无 TCS 运行。
## =====================================================================

@export_category("TCS 设置")
@export var enabled: bool = true
## TCS 介入前允许的最大纵向滑移率。
## 0.10 到 0.15 是干燥沥青路面上现代轿车的典型区间。
@export_range(0.0, 0.5) var slip_threshold: float = 0.12
## 介入期间降低油门的速率（单位：1.0/s）。
## 数值越大，介入越激进。
@export var intervention_rate: float = 3.5
## 在滑移被控制后恢复油门的速率（单位：1.0/s）。
## 该值设置过高会导致振荡。
@export var recovery_rate: float = 0.8
## TCS 失效时的最小车速（m/s）。
## 这能防止除零，也避免起步时过度激进地介入。
@export var min_speed_threshold: float = 0.5

@export_category("连接")
## TCS 将要写入 `tcs_throttle_limit` 的输入滤波组件。
@export var input_filter: MMTInputFilterComponent
## 需要监视的驱动轮列表（例如前驱车的两个前轮）。
@export var driven_wheels: Array[MMTWheelComponent] = []

# 供调试使用的公共状态。
var is_active: bool = false
var current_slip_ratio: float = 0.0
var _throttle_limit: float = 1.0

func process_tcs(dt: float) -> void:
	if not enabled or not input_filter:
		if input_filter:
			input_filter.tcs_throttle_limit = 1.0
		return

	var max_slip = 0.0
	var all_speeds_too_low = true

	for wheel in driven_wheels:
		if not wheel or not wheel.is_grounded:
			continue

		# 获取车轮接地印痕处的真实局部纵向速度。
		var vehicle_speed_at_wheel = wheel.wheel_long_vel

		# 在极低速时不介入，以允许起步时初期的轮胎抓地力。
		if abs(vehicle_speed_at_wheel) < min_speed_threshold:
			continue

		all_speeds_too_low = false

		var wheel_surface_speed = wheel.spin_vel * wheel.wheel_radius
		# 这种精确的滑移率计算消除了 Ackermann 转向和车身偏航带来的几何误差。
		var slip = (wheel_surface_speed - vehicle_speed_at_wheel) / max(abs(vehicle_speed_at_wheel), min_speed_threshold)
		max_slip = max(max_slip, slip)

	# 若所有驱动轮都低于最小速度，则恢复油门并退出。
	if all_speeds_too_low:
		_throttle_limit = move_toward(_throttle_limit, 1.0, recovery_rate * dt)
		input_filter.tcs_throttle_limit = _throttle_limit
		is_active = false
		current_slip_ratio = 0.0
		return

	current_slip_ratio = max_slip

	# 比例控制器：当滑移率超过阈值时收紧油门上限。
	if max_slip > slip_threshold:
		is_active = true
		var excess = max_slip - slip_threshold
		var tighten_amount = intervention_rate * (1.0 + excess * 4.0) * dt
		_throttle_limit = max(_throttle_limit - tighten_amount, 0.05)
	else:
		is_active = false
		_throttle_limit = min(_throttle_limit + recovery_rate * dt, 1.0)

	input_filter.tcs_throttle_limit = _throttle_limit

func get_debug_info() -> Dictionary:
	return {
		"tcs_enabled": enabled,
		"tcs_active": is_active,
		"slip_ratio": current_slip_ratio,
		"slip_threshold": slip_threshold,
		"throttle_limit": _throttle_limit,
	}
