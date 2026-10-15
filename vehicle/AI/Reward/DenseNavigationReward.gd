extends RewardFunction3D
class_name DenseNavigationReward

# ============================================================================
# DenseNavigationReward —— 纯导航奖励（Phase 1 学习链路验证用）
#
# ## 用途
#
# 验证"PPO 能不能学会朝目标开"。这是**临时**奖励函数：
# 等确认学习链路通了、`task/pickups` 开始非零之后，就把它关掉，
# 换回 PickUpAndDropRewardFunction。
#
# ## 为什么需要它
#
# 原奖励（PickUpAndDropRewardFunction）是"势函数塑形 + 到达事件"的混合。
# 其中的到达事件奖励要求 **水平距离 ≤ 2m 且车速 ≤ 1.5 m/s** —— 这个事件在
# 连续动作空间里的概率体积极小，随机策略 81 万步 × 600 agent 都撞不上。
# 结果 PPO 从未收到过一次正反馈，`train/std` 一直停在 1.0（策略原地不动）。
#
# 本函数把奖励变成**纯密集信号**：
#
#     r = progress_gain − step_cost − far_penalty − lateral_penalty
#
# 其中 progress_gain 是"本帧相比上帧靠近了多少米"。**注意这是差分形式**，
# 所以要乘回 track_range 换算成米，而不是归一化值。
#
# ## 关键设计：差分形式 vs 绝对距离形式
#
# 形式 A（绝对距离）：r = -dist / track_range
#   - 优点：值域有界 [−1, 0]，value function 好学
#   - 缺点：策略往任意方向开都能"减小"这一项吗？不能 —— 只有靠近才减小。
#     但**静止不动**时它是个常数，策略没有"动起来"的梯度。
#
# 形式 B（差分/势函数，本实现采用）：r = +k · (dist_prev − dist)
#   - 靠近得正分、远离得负分、静止得 0
#   - 这是标准的 potential-based shaping（Ng et al. 1999），
#     **不改变最优策略**，只是给学习提供密集梯度
#
# 选 B：它在"静止"和"靠近"之间有明确区分，而 A 没有。
#
# ## 与 PickUpAndDropRewardFunction 的关系
#
# 两者的塑形项数学形式相同（都是差分），区别在于：
#   - 本函数**去掉了全部事件奖励**，也去掉了减速引导（rw_speed）
#   - 本函数**去掉了 max_track_dist 过滤**，任何目标都参与
# 目的是把"任务"简化成纯导航，隔离变量。
# ============================================================================

@export_category("目标解析")
## 进度归一化的**下限**（米）。目标锁定时距离被夹到不低于它，
## 防止目标正好锁在脚边时 1/d0 极大、一米位移就吃掉整段奖励预算。
@export var track_range: float = 10.0

@export_category("奖励权重（每 env step）")
## 进度权重：每靠近 1 米得多少分（按 d0 归一化后）。
## 它**本身就是每段子目标的奖励预算上限**（因为差分会伸缩求和）。
@export var rw_progress: float = 3.0
## 每步时间代价（负数）。抑制"原地磨蹭刷进度"。
@export var rw_step: float = -0.01

@export_category("辅助项")
## 过远附加惩罚权重（0 = 关闭）。d > far_threshold 时按超出量扣。
@export var rw_far: float = 0.0
## 过远阈值（米），配合 rw_far。
@export var far_threshold: float = 60.0
## 横向滑移惩罚权重（0 = 关闭）。抑制甩尾。
##
## ⚠️ 默认 0（关闭）。原因：这项按**每帧**扣、不做 per_frame 折算，且乘的是
## **绝对**横向速度 —— 随机策略不停打方向时横向速度很大，会持续扣分，
## 于是策略学到的最优解是"别动/慢慢蹭"（实测回报 -5320，约 -0.49/帧，
## 与之量级吻合）。要抑制甩尾请改用 steering_smooth_weight（惩罚转向变化率）
## 而不是惩罚横向速度本身，或者把它调到 0.001 量级再试。
@export var rw_lateral: float = 0.0

## 被注入的出租车控制器
var car_ref: AITaxiController

## 上一相位是否载客（用于检测子目标切换）
var _prev_carrying: bool = false
## 当前锁定的目标节点
var _goal: Node3D = null
## 上一帧到目标的距离
var _prev_dist: float = 0.0
## 当前子目标的归一化距离（米），下限 track_range
var _d0: float = 1.0


#expose
func get_car_ref(ref_car: AITaxiController) -> void:
	car_ref = ref_car


#expose
func get_reward() -> float:
	var r := 0.0

	if car_ref == null or car_ref._vehicle == null or not is_instance_valid(car_ref._vehicle):
		return 0.0

	var carrying: bool = car_ref.has_passenger

	# --- 目标解析 ---
	var goal := _resolve_goal(carrying)
	if goal == null:
		_goal = null
		# 没目标时只扣时间代价，避免"没有目标反而更优"
		return rw_step

	var dist := _planar_dist_to(goal)

	# --- 子目标切换那一帧：重置基线，不施加差分（避免距离跳变造成虚假奖励）---
	if _goal != goal:
		_goal = goal
		_prev_dist = dist
		_d0 = maxf(dist, track_range)
		_prev_carrying = carrying
		return rw_step

	# --- 进度塑形（差分形式，伸缩求和 → 每段总量恒为 rw_progress）---
	r += rw_progress * (_prev_dist - dist) / _d0
	_prev_dist = dist
	_prev_carrying = carrying

	# --- 过远附加惩罚（默认关闭）---
	if rw_far > 0.0 and far_threshold > 0.0 and dist > far_threshold:
		r -= rw_far * ((dist - far_threshold) / far_threshold)

	# --- 横向滑移惩罚（默认关闭）---
	if rw_lateral != 0.0:
		r -= rw_lateral * _norm_speed(_lateral_speed())

	# --- 时间代价 ---
	r += rw_step
	return r


#expose
func reset() -> void:
	_prev_carrying = false
	_goal = null
	_prev_dist = 0.0
	_d0 = maxf(track_range, 0.001)


## 解析当前子目标：载客时是目的地，空车时是目标乘客。
func _resolve_goal(carrying: bool) -> Node3D:
	if carrying:
		var p: Passenger = car_ref.carried_passenger
		if p != null and is_instance_valid(p):
			if p.destination != null and is_instance_valid(p.destination):
				return p.destination
			return p
		return null

	# 空车：目标由业务组件维护（经控制器转发属性读取）
	var t: Passenger = car_ref.current_target
	if t != null and is_instance_valid(t) and t.is_waiting:
		return t
	return null


func _planar_dist_to(target: Node3D) -> float:
	var a: Vector3 = car_ref._vehicle.global_transform.origin
	var b: Vector3 = target.global_position
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _lateral_speed() -> float:
	if car_ref == null or car_ref._vehicle == null or not is_instance_valid(car_ref._vehicle):
		return 0.0
	var v: Vector3 = car_ref._vehicle.linear_velocity
	return absf(car_ref._vehicle.global_transform.basis.x.dot(v))


func _norm_speed(v: float) -> float:
	if car_ref == null:
		return 0.0
	return v / maxf(car_ref.max_speed_mps, 0.001)
