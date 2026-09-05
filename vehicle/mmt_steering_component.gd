# res://vehicle/mmt_steering_component.gd
extends Node
class_name MMTSteeringComponent

## =====================================================================
## MMT 转向组件
##
## 职责：平滑化阶梯式数字转向输入，以模拟驾驶员手臂的惯性，
## 并实现速度敏感转向（Speed-Sensitive Steering）。
##
## 核心算法：
##   1. 速率限制：`current_angle` 以 `steer_rate_deg_s` 的速率向目标值移动。
##   2. 速度敏感：`effective_max = max_steer / (1 + speed_sensitivity * |v|)`。
##   3. 自动回正：无输入时，车轮以 `return_rate_deg_s` 的速率回到 0°。
##
## 设计：一个纯计算节点。它读取车辆速度，并把最终的 `current_steer_rad`
## 暴露给 MMTVehicleBody 用于转向计算。它不直接施加力。
## =====================================================================

@export_category("转向几何")
## 车轮的物理最大转向角，单位为度。
@export var max_steer_angle_deg: float = 35.0

@export_category("速率限制（驾驶员手部惯性）")
## 方向盘向目标角度转动的速率（度/秒）。
## 110 度/秒模拟普通驾驶员从居中到打满方向约需 0.32 秒。
@export var steer_rate_deg_s: float = 110.0
## 方向盘自动回正到居中的速率（度/秒）。
## 该值通常高于 `steer_rate`，以模拟自回正力的效果。
@export var return_rate_deg_s: float = 160.0

@export_category("速度敏感转向（助力转向）")
## 速度敏感转向的灵敏度系数（单位：1/(m/s)）。
## 建议取 0.1。在 100 km/h（27.7 m/s）时，有效最大转角变为：
## 35 / (1 + 0.1 * 27.7) ≈ 9.2 度。这模拟了真实车辆在高速时
## 有效车轮转角减小的特性。
@export var speed_sensitivity: float = 0.1

# -- 平滑后的输出信号（由 MMTVehicleBody 直接读取） --
## 当前平滑后的转向角（弧度），可直接用于 Ackermann 计算。
var current_steer_rad: float = 0.0

# 内部状态
var _current_steer_deg: float = 0.0
var effective_max_deg: float = 35.0   ## 当前有效最大转角，用于调试。

## 每物理帧由 MMTVehicleBody._physics_process 调用。
## raw_axis:      原始转向输入轴 [-1, 1]。正值表示向左，与 get_axis("right", "left") 一致。
## forward_speed: 车辆前进速度（m/s），用于速度敏感计算。
## dt:            物理时间步长。
func process_steering(raw_axis: float, forward_speed: float, dt: float) -> void:
	# 第 1 层：速度敏感——计算有效最大转向角。
	# 速度越高，有效锁止角越小。
	effective_max_deg = max_steer_angle_deg / (1.0 + speed_sensitivity * abs(forward_speed))

	# 第 2 层：计算目标角度。
	# `raw_axis * effective_max_deg` 表示驾驶员的意图转向角。
	var target_deg = raw_axis * effective_max_deg

	# 第 3 层：速率限制（模拟驾驶员手臂惯性）。
	# 主动转向输入与自动回正使用不同速率。
	var is_returning = (abs(raw_axis) < 0.01)
	var rate = return_rate_deg_s if is_returning else steer_rate_deg_s

	_current_steer_deg = move_toward(_current_steer_deg, target_deg, rate * dt)

	# 转换为弧度以供外部使用。
	current_steer_rad = deg_to_rad(_current_steer_deg)

func get_debug_info() -> Dictionary:
	return {
		"steer_deg":        _current_steer_deg,
		"steer_rad":        current_steer_rad,
		"effective_max":    effective_max_deg,
		"max_steer":        max_steer_angle_deg,
	}
