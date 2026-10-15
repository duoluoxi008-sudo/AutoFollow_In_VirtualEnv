extends RewardFunction3D
class_name isMovingRewardFunction

# ============================================================================
# isMovingRewardFunction —— 惩罚 Agent"长时间低速运行"（按训练步 n 计时）
#
# 鼓励出租车保持行进（去接客 / 去目的地），不要长时间停在原地或龟速蠕行。
#
# 用"训练步 n"而非"秒"来度量时长（RL 的 MDP 是按步索引的，与 γ 折扣、
# TD 自举、reset_after、观测里的 n_steps 口径一致；且对帧率变化免疫）。
# 逻辑（每个 _physics_process = 一步 = 一次物理帧）：
#   - 速度 >= low_speed_threshold（在正常移动）→ 重置连续低速计数 _slow_steps。
#   - 速度 <  low_speed_threshold（低速/静止）→ _slow_steps += 1。
#   - get_reward()：连续低速超过 grace_steps 后，
#         penalty = min(超标步数 * penalty_per_step, max_step_penalty)，取负返回。
#
# 注意：这里是"连续"低速步数，不是全局 n_steps（全局 n_steps 是回合累计值，无法表示连续）。
#
# car_ref 由外部注入（get_car_ref），用于读取本车运行状态。
# 由 RewardManager 作为子 RewardFunction3D 收集，get_reward() 被累加进总奖励。
# ============================================================================

## 视为"正在移动"的速度阈值（米/秒）；低于该值视为低速/静止
@export var low_speed_threshold: float = 0.5
## 宽限期（训练步）：连续低速超过该步数才开始惩罚。默认 180 步 ≈ 3秒 @ 60Hz。
@export var grace_steps: int = 180
## 超过宽限期后，每多 1 步追加的惩罚。默认 0.003（≈ 0.2 / 60Hz）。
@export var penalty_per_step: float = 0.003
## 单步最大惩罚（避免一步扣太多导致奖励震荡）
@export var max_step_penalty: float = 0.5

## 被注入的出租车控制器引用
var car_ref: AITaxiController
## 累计"连续"低速步数
var _slow_steps: int = 0


#expose
func get_car_ref(ref_car: AITaxiController) -> void:
	car_ref = ref_car


func _ready() -> void:
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	var speed := _get_speed()
	if speed >= low_speed_threshold:
		_slow_steps = 0
	else:
		_slow_steps += 1


#expose
func get_reward():
	var over := _slow_steps - grace_steps
	if over <= 0:
		return 0.0
	var penalty := minf(float(over) * penalty_per_step, max_step_penalty)
	return -penalty


#expose
func reset():
	_slow_steps = 0


func _get_speed() -> float:
	if car_ref == null or car_ref._vehicle == null or not is_instance_valid(car_ref._vehicle):
		return INF  # 还没接好车：视为"在移动"，避免误罚
	var state: Dictionary = car_ref._vehicle.get_vehicle_state()
	return absf(float(state["forward_speed"]))
