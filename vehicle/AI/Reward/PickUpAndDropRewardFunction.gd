extends RewardFunction3D
class_name PickUpAndDropRewardFunction

# ----------------------------------------------------------------------------
# 每帧奖励（get_reward 由 _physics_process 每个物理帧调用一次）
# ----------------------------------------------------------------------------
#   d      = 到当前子目标的平面距离（米）
#   d_n    = d / track_range                        归一化距离
#   v      = |前向车速| / max_speed_mps              归一化速度
#   v_lat  = |横向车速| / max_speed_mps
#   ramp   = max(0, 1 − d / target_follow_distance)  越近越大
#
#   r_t = + reward_pickup  · 1[接客翻转 且 d ≤ success_dist]
#         + reward_dropoff · 1[送达翻转 且 d ≤ success_dist]
#         + rw_progress · (d_prev − d) / d_0                进度塑形（伸缩求和，尺度无关）
#         − rw_speed    · v      · ramp   / frames_per_step 减速引导（进入制动带后）
#         − rw_lateral  · v_lat           / frames_per_step 横向滑移惩罚
#         − rw_dist     · (d/max_track_dist − 1) / frames_per_step
#                                                           过远惩罚（仅 d > max_track_dist）
#         + rw_step                       / frames_per_step 时间代价（rw_step 为负）
#
#   d_0 = maxf(锁定该子目标那一刻的距离, track_range)
#
# ## 为什么进度按 d_0 归一化，而不是按固定的 track_range
#
# 为了让"塑形 : 事件奖励"这个比例**与地图尺度无关**。
# 进度项是伸缩求和，所以一整段子目标（接客一段、送达一段）的塑形总量恰好是：
#
#     Σ = rw_progress × (d_start − d_end) / d_0  ≤  rw_progress      （到达目标时取等号）
#
# 也就是说 **rw_progress 本身就是"每段子目标的塑形预算"**，地图多大都一样。
# 于是一次完整送达的塑形上限 = 2 × rw_progress（两段各一次），而事件奖励总和是
# reward_pickup + reward_dropoff + reward_success = 2 + 5 + 5 = 12。
# 现在 rw_progress = 3.0 → 塑形上限 6 = 事件奖励的 50%，正好落在推荐区间（30%~50%）。
#
# 对比旧写法 `shaping_scale × 总距离`：那是**尺度相关**的。换一张大 3 倍的地图，
# 塑形总量自动变成 3 倍，会静默压过事件奖励、把策略带成"朝目标蹭"而不是"接客送达"，
# 而你必须重新标定才看得出来。改成 d_0 归一化之后，换地图不需要动任何权重。
#
# track_range 在新写法里退化成**归一化距离的下限**：防止某个目标正好锁在脚边
# （比如 0.5 米）时 1/d_0 变得极大、一米的位移就吃掉整段预算。
#
# 为什么有的项要 / frames_per_step：
#   本函数是**按物理帧**调用的，而 action_repeat 个物理帧才构成一个 RL step。
#   rw_step / rw_speed / rw_lateral / rw_dist 这些"随时间线性累加"的项如果不除，
#   实际强度会被放大 action_repeat 倍，跟它们"每步"量级的默认值对不上。
#   进度塑形**不需要**除：它是伸缩求和，与调用了多少次无关。
#
# 等价关系（旧参数 → 新参数）：
#   step_cost（每帧）       == -rw_step / frames_per_step   (0.001 == 0.008 / 8)
#   approach_speed_penalty → 被 rw_speed 取代，并且制动带从
#                            "pickup_radius 内" 扩展为 "target_follow_distance 内 + 线性斜坡"
#   shaping_scale（尺度相关） → 被 d_0 归一化取代 —— 语义变了，不是简单改名
#
# 防坑：
#   1. 目标/相位切换那一帧重置塑形基线（不施加塑形），避免距离跳变造成虚假奖励/惩罚。
#   2. 空车目标由 TaxiServiceComponent 维护（组件负责锁定/重选/判被抢客），
#      本函数只通过 car_ref（AITaxiController）的转发属性读取，避免与驾驶层目标不一致。
#   3. success_dist 必须 ≥ 业务组件的 pickup_radius(2.0) / dropoff_radius(2.5)，
#      否则真实发生的接送会被事件确认过滤掉、事件奖励永远是 0。
#
# car_ref 由 RewardManager 通过 get_car_ref() 注入；由 RewardManager 累计各子奖励。
# ============================================================================

# ---- 环境尺度 ----
## 进度归一化距离的**下限**（米）。每个子目标锁定时的距离会被夹到不低于它，
## 防止"目标正好锁在脚边"（比如 0.5 米）时 1/d_0 极大、一米位移就吃掉整段塑形预算。
## 它不是"地图尺度" —— 换成更大的地图也不需要改它。
@export var track_range: float = 10.0
## 制动起始距离（米）：进入这个距离就开始减速（配合 rw_speed，越近扣得越狠）。
@export var target_follow_distance: float = 12.0
## 到位确认半径（米）：接送事件发生时若到目标距离超过它，事件奖励不计发。
## ⚠️ 必须 ≥ 业务组件的 pickup_radius / dropoff_radius，否则会误杀真实接送。
@export var success_dist: float = 3.0
## 每个 env step 对应多少物理帧（= sync.gd 的 action_repeat）。
## 只用于把"每步"系数换算成"每帧"，见上面文件头的说明。
@export var frames_per_step: float = 8.0

# ---- 事件奖励 ----
## 接客事件奖励
@export var reward_pickup: float = 2.0
## 送达事件奖励（任务完成的主要奖励）
@export var reward_dropoff: float = 5.0

# ---- 连续项（权重一律按"每 env step"给，函数内部会 / frames_per_step）----
## 进度奖励权重。按 d_0 归一化，所以它**本身就是每段子目标的塑形预算**：
##   一次完整送达（接客段 + 送达段）的塑形上限 = 2 × rw_progress
## 推荐让它满足 2 × rw_progress ≈ 0.3~0.5 × 事件奖励总和(=12)，即 rw_progress ≈ 2~3。
## 这个比例与地图尺度无关，换环境不用重调。
@export var rw_progress: float = 3.0
## 时间代价（负数）。
@export var rw_step: float = -0.008
## 减速引导权重（"形式 B"）：进入制动带后按速度扣，越近扣得越狠。
## 为什么不给"停下"正奖励：接客判定一旦因 is_waiting == false 等原因为不触发，
## 正奖励立刻变成"停在目标旁边白拿钱"的刷分点；速度惩罚天然有界。
@export var rw_speed: float = 0.05
## 横向滑移惩罚权重：抑制甩尾/侧滑，让车走得像车。
@export var rw_lateral: float = 0.01
## 过远惩罚权重：d > max_track_dist 时按超出量扣。与 max_track_dist 必须同时 > 0 才生效。
## 默认两者都是 0（关闭）—— 正确取值取决于地图尺度，按实测距离标定后再打开。
@export var rw_dist: float = 0.0
## 过远阈值（米），配合 rw_dist。
@export var max_track_dist: float = 0.0

## 被注入的出租车控制器
var car_ref: AITaxiController

## 记录上一相位是否载客（用于检测接客/送达翻转）
var _prev_carrying: bool = false
## 当前锁定的目标节点（乘客 或 目的地）
var _goal: Node3D = null
## 上一帧到目标的距离
var _prev_dist: float = 0.0
## 上一帧到目标的距离，单独留一份给"事件到位确认"用。
## 为什么不复用 _prev_dist：接送翻转那一帧目标会切换（乘客 → 目的地），
## _prev_dist 已被用来重置塑形基线，值不再代表"翻转发生时离原目标多远"。
var _last_dist: float = INF
## 当前子目标的进度归一化距离（米）= 锁定该目标那一刻的距离，下限 track_range。
## 见文件头"为什么进度按 d_0 归一化"——它让塑形预算与地图尺度无关。
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
	# "每步"→"每帧"的换算系数，见文件头说明
	var per_frame := 1.0 / maxf(frames_per_step, 1.0)

	# --- 1. 事件奖励（接送翻转）。要求翻转发生时确实在 success_dist 内 ---
	# 业务组件的 pickup/dropoff_radius 可能比 success_dist 宽，这里做一次
	# "真的到位了吗"的确认，避免在场地另一头误触发也拿钱。
	if carrying and not _prev_carrying:
		if _last_dist <= success_dist:
			r += reward_pickup
	elif not carrying and _prev_carrying:
		if _last_dist <= success_dist:
			r += reward_dropoff
	_prev_carrying = carrying

	# --- 2. 当前目标与距离 ---
	var goal := _resolve_goal(carrying)
	if goal == null:
		_goal = null
		r += rw_step * per_frame
		return r
	var dist := _planar_dist_to(goal)
	_last_dist = dist

	# --- 3. 进度塑形（目标变更时重置基线与归一化距离，不施加塑形，避免距离跳变造成虚假奖励）---
	if _goal != goal:
		_goal = goal
		_prev_dist = dist
		# 本段子目标的归一化距离。下限 track_range 防止"目标锁在脚边"时每米收益爆炸。
		# 这样每段子目标的塑形总量上限恒为 rw_progress，与地图尺度无关。
		_d0 = maxf(dist, track_range)
	else:
		r += rw_progress * (_prev_dist - dist) / _d0
		_prev_dist = dist

	# --- 4. 减速引导（形式 B）：进入制动带后按速度扣，越近扣得越狠 ---
	# 用速度惩罚而不是"停下奖励"：前者天然有界，不会变成"停在旁边刷分"的通路。
	if rw_speed != 0.0 and target_follow_distance > 0.0 and dist <= target_follow_distance:
		var ramp := 1.0 - dist / target_follow_distance
		r -= rw_speed * _norm_speed(_forward_speed()) * ramp * per_frame

	# --- 5. 横向滑移惩罚：抑制甩尾/侧滑 ---
	if rw_lateral != 0.0:
		r -= rw_lateral * _norm_speed(_lateral_speed()) * per_frame

	# --- 6. 过远惩罚（默认关闭：rw_dist 与 max_track_dist 必须同时 > 0）---
	if rw_dist > 0.0 and max_track_dist > 0.0 and dist > max_track_dist:
		# 按 max_track_dist 自身归一化（尺度无关），不再依赖 track_range
		r -= rw_dist * ((dist - max_track_dist) / max_track_dist) * per_frame

	# --- 7. 时间代价 ---
	r += rw_step * per_frame
	return r


#expose
func reset() -> void:
	_prev_carrying = false
	_goal = null
	_prev_dist = 0.0
	_last_dist = INF
	_d0 = maxf(track_range, 0.001)


## 解析当前子目标（一个 Node3D）；无目标返回 null。
func _resolve_goal(carrying: bool) -> Node3D:
	if carrying:
		var p: Passenger = car_ref.carried_passenger
		if p != null and is_instance_valid(p):
			if p.destination != null and is_instance_valid(p.destination):
				return p.destination
			return p  # 无目的地的兜底（载着去乘客当前位置）
		return null

	# 空车：目标由业务组件维护（经控制器转发属性读取）
	var t := car_ref.current_target
	if t != null and is_instance_valid(t) and t.is_waiting:
		return t
	return null


func _planar_dist_to(target: Node3D) -> float:
	var a: Vector3 = car_ref._vehicle.global_transform.origin
	var b: Vector3 = target.global_position
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


## 本车前向速度绝对值（m/s）。读不到车时返回 0（不施加额外惩罚）。
func _forward_speed() -> float:
	if car_ref == null or car_ref._vehicle == null or not is_instance_valid(car_ref._vehicle):
		return 0.0
	var st: Dictionary = car_ref._vehicle.get_vehicle_state()
	return absf(float(st.get("forward_speed", 0.0)))


## 本车横向速度绝对值（m/s）。
## 与 get_obs() 里 lateral_speed 的算法保持一致（车身右轴 · 世界线速度）。
func _lateral_speed() -> float:
	if car_ref == null or car_ref._vehicle == null or not is_instance_valid(car_ref._vehicle):
		return 0.0
	var v: Vector3 = car_ref._vehicle.linear_velocity
	return absf(car_ref._vehicle.global_transform.basis.x.dot(v))


## 把 m/s 归一化到控制器的 max_speed_mps，使各项权重与车的绝对速度无关。
func _norm_speed(v: float) -> float:
	if car_ref == null:
		return 0.0
	return v / maxf(car_ref.max_speed_mps, 0.001)
