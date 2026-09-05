extends AIController3D
class_name AITaxiController

# ============================================================================
# AITaxiController —— 跟车（AutoFollow）任务的 AI 控制器
#
# 参考 godot_rl_agents 的 3DCarParking 示例实现：
#   - get_obs()      组装观测向量（自身车辆状态 + 目标相对状态 + 射线传感器）
#   - get_reward()   返回本步累计的奖励（在 _physics_process 中累加）
#   - get_action_space()  定义连续动作空间
#   - set_action()   把 Python 传来的连续动作写入 MMTVehicleInputState
#   - _physics_process 负责计时、结束判定与重置
#
# 车辆侧（MMTVehicleBody / mmt_sedan.gd）：
#   - 通过 set_controller_input() 接收共享输入对象，每个物理帧从中读取。
#   - 通过 get_vehicle_state() 暴露自身运行状态。
# ============================================================================

# --- 目标与任务配置 ---
## 当进入乘客多少范围时则刹车距离，期望令Agent能够正好在乘客附近刹停
@export var target_follow_distance: float = 1.5
## 用于归一化的最大车速（米/秒）
@export_range(1.0, 60.0) var max_speed_mps: float = 25.0
## 用于归一化的最大横向/纵向目标偏移（米）
@export_range(1.0, 40.0) var track_range: float = 10.0
# --- 车队/公司机制 ---
## 公司编号：同编号为同一车队（队友），彼此不被视为对手、不互相竞争
@export var company_id: int = 0
# --- 传感器 ---
@export_group("传感器")
@export var sensor_manager:SensorManager
# --- 奖励权重 ---
@export_group("奖励权重")
@export var reward_manager:RewardManager
@export var rw_dist: float = 2.0        ## 距离误差惩罚
@export var rw_speed: float = 0.6       ## 相对速度惩罚
@export var rw_lateral: float = 0.8     ## 横向偏差惩罚
@export var rw_progress: float = 3.0    ## 靠近目标的进度奖励
@export var rw_step: float = -0.01      ## 每步微小代价（鼓励尽快完成任务）
@export var reward_fail: float = -6.0   ## 失败（丢失目标/翻车/超时）奖励

# --- 终止条件 ---
@export_group("终止条件")
@export var max_track_dist: float = 12.0         ## 超出该距离视为丢失目标
@export var success_dist: float = 0.8            ## 判定"成功"的距离
@export var enable_success_terminal: bool = false ## 是否启用成功终止（跟车任务通常不启用）
@export var success_hold_frames: int = 8         ## 需要持续满足成功条件的帧数

# --- 内部引用 ---
var _vehicle: MMTVehicleBody
var _input: MMTVehicleInputState
var _initial_transform: Transform3D
var _smallest_dist: float = INF

# 上一帧动作（用于专家演示录制）
var _last_action: Array[float] = [0.0, 0.0, 0.0]
# 成功状态（供 get_info 使用）
var _is_success: bool = false
var _success_frames: int = 0
# 竞争多智能体：本车是否正在载客（接送逻辑在接客时置 true、送达时置 false）
var has_passenger: bool = false
# 当前所载的乘客（接送逻辑接客时赋值，送达置 null；供 PassengerPositionSensor3D 读目的地）
var carried_passenger: Passenger = null


func _ready() -> void:
	super._ready()          # 调用基类：加入 "AGENT" 组
	add_to_group("taxi_agents")   # 供对手观测查找其它出租车
	_vehicle = _find_vehicle()
	if _vehicle == null:
		push_warning("AITaxiController: 未找到 MMTVehicleBody，AI 控制不可用。")
		return

	# 创建共享输入状态并交给车辆，车辆每个物理帧从该对象读取输入。
	_input = MMTVehicleInputState.new()
	_vehicle.set_controller_input(_input)

	_initial_transform = _vehicle.transform
	_smallest_dist = INF


func init(player: Node3D) -> void:
	super.init(player)
	_vehicle = player as MMTVehicleBody


# ----------------------------------------------------------------------------
# 观测
# ----------------------------------------------------------------------------
func get_obs() -> Dictionary:
	var observations: Array[float] = []

	if _vehicle == null:
		return {"obs": observations}

	# --- 1. 自身车辆状态 ---
	var state: Dictionary = _vehicle.get_vehicle_state()
	var forward_speed: float = state["forward_speed"]
	var lateral_speed: float = _vehicle.global_transform.basis.x.dot(_vehicle.linear_velocity)
	var yaw_rate: float = _vehicle.angular_velocity.y
	var gear_idx: int = state["gear_index"]

	var gear_max: float = 1.0
	if _vehicle.gearbox != null:
		gear_max = max(float(_vehicle.gearbox.gear_ratios.size() - 1), 1.0)

	var steer_ratio: float = 0.0
	if _vehicle.steering != null and _vehicle.steering.max_steer_angle_deg > 0.0:
		steer_ratio = _vehicle.steering.current_steer_rad / deg_to_rad(_vehicle.steering.max_steer_angle_deg)

	var rpm_norm: float = 0.0
	if _vehicle.engine != null and _vehicle.engine.max_rpm > 0.0:
		rpm_norm = _vehicle.engine.current_rpm / _vehicle.engine.max_rpm

	observations.append_array([
		n_steps / float(reset_after),
		clampf(forward_speed / max_speed_mps, -1.0, 1.0),   # 前向车速
		clampf(lateral_speed / max_speed_mps, -1.0, 1.0),   # 横向车速
		clampf(yaw_rate * 0.5, -1.0, 1.0),                  # 横摆角速度
		clampf(steer_ratio, -1.0, 1.0),                     # 当前转向角
		clampf(rpm_norm, 0.0, 1.0),                         # 发动机转速
		clampf(gear_idx / gear_max, 0.0, 1.0),              # 挡位
		1.0 if state["is_grounded"] else 0.0,               # 是否着地
	])
	# --- 2. 传感器（含乘客目标/对手等，由 SensorManager 拼接） ---
	#传感器值
	observations.append_array(sensor_manager.get_raycast_observations())
	observations.append_array(sensor_manager.get_position_observations())
	return {"obs": observations}


func get_obs_space():
	var obs: Dictionary = get_obs()
	return {
		"obs": {"size": [len(obs["obs"])], "space": "box"},
	}


# ----------------------------------------------------------------------------
# 动作
# ----------------------------------------------------------------------------
func get_action_space() -> Dictionary:
	return {
		"throttle": {"size": 1, "action_type": "continuous"},
		"steering": {"size": 1, "action_type": "continuous"},
		"brake":    {"size": 1, "action_type": "continuous"},
	}


func set_action(action) -> void:
	if _input == null:
		return

	# 连续动作，值为 [-1, 1]（throttle/steering）与 [0, 1]（brake）。
	#油门
	var throttle: float = clampf(_get_action_val(action, "throttle"), -1.0, 1.0)
	#左右旋转轮胎
	var steer: float = clampf(_get_action_val(action, "steering"), -1.0, 1.0)
	#刹车
	var brake: float = clampf(_get_action_val(action, "brake"), 0.0, 1.0)

	# 把 [-1, 1] 的油门意图分解为前向/后向油门，
	# 车辆的 auto_reverse 逻辑会自动把"反向油门"当作刹车处理。
	if throttle >= 0.0:
		_input.throttle_forward = throttle
		_input.throttle_back = 0.0
	else:
		_input.throttle_forward = 0.0
		_input.throttle_back = -throttle

	_input.steer_axis = steer
	_input.brake = brake

	_last_action = [throttle, steer, brake]


func get_action() -> Array:
	return _last_action


# ----------------------------------------------------------------------------
# 奖励与终止
# ----------------------------------------------------------------------------
func get_reward() -> float:
	return reward


func get_info() -> Dictionary:
	return {"is_success": _is_success}


func _physics_process(delta):
	if _vehicle == null:
		return

	n_steps += 1

	# 需要重置时（由超时/终止或 Python reset 触发）
	if needs_reset:
		_reset_episode()
		return

	# 时间上限
	if n_steps > reset_after:
		_end_episode(reward_fail)
		return




# 结束当前回合：把最终奖励累加进去并置 done。
func _end_episode(final_reward: float) -> void:
	reward += final_reward
	needs_reset = true
	done = true

# 重置车辆与控制器状态。
func _reset_episode() -> void:
	reset()                 # 基类：n_steps = 0；needs_reset = false
	done = false
	_is_success = false
	_success_frames = 0
	_smallest_dist = INF

	# 车辆归位到初始位姿并清零速度。
	if _vehicle != null:
		_vehicle.transform = _initial_transform
		_vehicle.linear_velocity = Vector3.ZERO
		_vehicle.angular_velocity = Vector3.ZERO
	if _input != null:
		_input.reset()


func reset_if_done():
	if done:
		reset()

# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------
func _find_vehicle() -> MMTVehicleBody:
	var n: Node = get_parent()
	while n != null:
		if n is MMTVehicleBody:
			return n as MMTVehicleBody
		n = n.get_parent()
	return null


## 供对手观测读取其它车运行状态
func get_vehicle() -> MMTVehicleBody:
	return _vehicle


func is_carrying() -> bool:
	return has_passenger





func _get_action_val(action: Variant, key: String) -> float:
	# action 是包含 "key": [value] 的字典。
	if not (action is Dictionary):
		return 0.0
	var d: Dictionary = action
	var arr: Variant = d.get(key, null)
	if arr == null:
		return 0.0
	if arr is Array:
		return float(arr[0])
	if arr is Dictionary:
		return float(arr.get("value", 0.0))
	if arr is float or arr is int:
		return float(arr)
	return 0.0
