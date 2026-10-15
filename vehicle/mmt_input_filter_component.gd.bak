# res://vehicle/mmt_input_filter_component.gd
extends Node
class_name MMTInputFilterComponent

## =====================================================================
## MMT 输入滤波组件
##
## 职责：平滑化阶梯式数字输入（例如来自键盘），以模拟驾驶员四肢的惯性
## 和 ECU 扭矩速率限制。它还会接收来自 TCS 的 `throttle_limit`，
## 并作为最终上限应用。
##
## 设计：这是一个数据处理节点。它不直接施加力，
## 而是把平滑后的信号暴露为属性，供上游节点（例如 MMTVehicleBody）读取。
## =====================================================================

@export_category("油门斜坡")
## 油门施加速率（单位：1.0/s）。取值 1.0 表示用 1 秒从 0% 到 100%。
## 数值越小越平滑，数值越大越激进。
@export var throttle_rise_rate: float = 2.0
## 油门释放速率（单位：1.0/s）。油门回零的速度，通常高于上升速率。
@export var throttle_fall_rate: float = 6.0

@export_category("刹车斜坡")
## 刹车施加速率。模拟踩下刹车踏板的速度。
@export var brake_rise_rate: float = 8.0
## 刹车释放速率。
@export var brake_fall_rate: float = 10.0

@export_category("ECU 扭矩速率限制")
## 启用后，ECU 限制扭矩上升速率，以防止车轮打滑，尤其是在静止起步时。
@export var enable_torque_rate_limit: bool = true
## 有效油门每秒钟的最大变化率。
## 例如 0.8 表示油门从 0 到 100% 至少需要 1.25 秒。
## 这作为基础油门斜坡之上的一层额外平滑。
@export var torque_rate_limit: float = 1.5

# -- 平滑后的输出信号（由 MMTVehicleBody 直接读取） --
var smoothed_throttle: float = 0.0  ## 当前平滑后的油门值 [0, 1]。
var smoothed_brake: float = 0.0     ## 当前平滑后的刹车值 [0, 1]。

## 由 TCS 组件注入的油门上限。默认 1.0（无限制）。
var tcs_throttle_limit: float = 1.0

# 用于 ECU 限制油门的内部状态。
var _ecu_limited_throttle: float = 0.0

## 每物理帧由 MMTVehicleBody._physics_process 调用。
## raw_throttle: 驾驶员原始油门输入 [0, 1]。
## raw_brake:    驾驶员原始刹车输入 [0, 1]。
## dt:           物理时间步长。
func process_input(raw_throttle: float, raw_brake: float, dt: float) -> void:
	# -- 第 1 层：模拟驾驶员四肢惯性 --
	var target_throttle = raw_throttle
	if target_throttle > smoothed_throttle:
		smoothed_throttle = min(smoothed_throttle + throttle_rise_rate * dt, target_throttle)
	else:
		smoothed_throttle = max(smoothed_throttle - throttle_fall_rate * dt, target_throttle)

	var target_brake = raw_brake
	if target_brake > smoothed_brake:
		smoothed_brake = min(smoothed_brake + brake_rise_rate * dt, target_brake)
	else:
		smoothed_brake = max(smoothed_brake - brake_fall_rate * dt, target_brake)

	# -- 第 2 层：ECU 扭矩速率限制 --
	if enable_torque_rate_limit:
		if smoothed_throttle > _ecu_limited_throttle:
			_ecu_limited_throttle = min(_ecu_limited_throttle + torque_rate_limit * dt, smoothed_throttle)
		else:
			# 松开油门时不需要速率限制，应立即可用。
			_ecu_limited_throttle = smoothed_throttle
	else:
		_ecu_limited_throttle = smoothed_throttle

	# -- 第 3 层：TCS 油门上限 --
	# `tcs_throttle_limit` 由 MMTTCSComponent 每帧写入。
	smoothed_throttle = min(_ecu_limited_throttle, tcs_throttle_limit)

func get_debug_info() -> Dictionary:
	return {
		"smoothed_throttle": smoothed_throttle,
		"smoothed_brake": smoothed_brake,
		"tcs_limit": tcs_throttle_limit,
		"ecu_limited_throttle": _ecu_limited_throttle,
	}
