extends Node
class_name PassengerDistributeManager

# ============================================================================
# PassengerDistributeManager —— 手写"距离 + 等待时长"优先级的竞争派单器
#
# 这是"派单层"：只负责"给候选乘客打分"，不负责开车，也不做全局唯一分配。
# 打分规则（分数越低优先级越高）：
#   score = w_dist * 出租车到乘客的距离  +  w_wait * min(乘客等待时长, wait_cap)
#
# 竞争 + 车队机制：
#   - pick_best_target_for(agent)：每个 agent 独立按"自己的视角"挑当前打分最高的乘客。
#   - 不同公司之间：**不认领**，纯竞争（谁先到谁先接到，先到先得）。
#   - 同一公司之内：**按公司认领**（cooperative_within_fleet），队友不会重复去抢同一个乘客
#     —— 这就是"同公司不互相竞争"的车队机制。
#
# 由 PassengerManager 合并（new + add_child）进来，通过 setup() 拿到 manager 引用。
# ============================================================================

## 距离权重
@export_range(0.0, 10.0) var w_dist: float = 1.0
## 等待时长权重
@export_range(0.0, 10.0) var w_wait: float = 0.5
## 等待时长上限（秒），防止等待过久的乘客权重无限放大
@export_range(1.0, 300.0) var wait_cap: float = 30.0
## 是否开启车队内协作：同公司车不会重复认领同一乘客（默认开启）
@export var cooperative_within_fleet: bool = true

## 被合并进来的 PassengerManager 引用
var manager: PassengerManager

## 认领表：passenger_instance_id -> { company_id: true }（记录哪些公司在前往该乘客）
var _reservations: Dictionary = {}


func setup(m: PassengerManager) -> void:
	manager = m


## 竞争派单：从 agent 视角挑打分最高的等待中乘客。
## 跨公司纯竞争；同公司协作（cooperative_within_fleet）时会避开队友已认领的乘客。
func pick_best_target_for(agent: Node3D) -> Passenger:
	if manager == null or agent == null:
		return null

	var company := _get_company_of(agent)
	_prune_reservations()

	var best: Passenger = null
	var best_score: float = INF
	for p in manager.passengers:
		if p == null or not is_instance_valid(p):
			continue
		if not p.is_waiting:
			continue  # 已上车（含被其它车接走）的目标直接跳过
		var pid := p.get_instance_id()
		# 同公司协作：若队友已认领该乘客，则本车跳过（避免同队内卷）
		if cooperative_within_fleet and _reservations.has(pid) and _reservations[pid].has(company):
			continue
		var dist: float = agent.global_position.distance_to(p.global_position)
		var score: float = w_dist * dist + w_wait * minf(p.wait_time, wait_cap)
		if score < best_score:
			best_score = score
			best = p

	if best != null and cooperative_within_fleet:
		var pid2 := best.get_instance_id()
		if not _reservations.has(pid2):
			_reservations[pid2] = {}
		_reservations[pid2][company] = true
	return best


## 兼容旧接口：等价于 pick_best_target_for。
func assign_passenger(taxi: Node3D) -> Passenger:
	return pick_best_target_for(taxi)


## 乘客上/下车、被移除后，清理它的认领记录。
func release(passenger: Passenger) -> void:
	if passenger != null and is_instance_valid(passenger):
		_reservations.erase(passenger.get_instance_id())


## 兼容旧接口：仅当同公司协作且该乘客已被本车公司认领时为 true（用于查询）。
func is_claimed(passenger: Passenger) -> bool:
	return passenger != null and is_instance_valid(passenger) \
		and _reservations.has(passenger.get_instance_id()) \
		and not _reservations[passenger.get_instance_id()].is_empty()


## 从 agent 读取公司编号；无 company_id 属性则返回一个永不冲突的哨兵值。
func _get_company_of(agent: Node3D) -> int:
	if agent.has_method("get_company_id"):
		return agent.get_company_id()
	if agent.get("company_id") != null:
		return int(agent.get("company_id"))
	return -1  # 哨兵：无公司信息时，用 -1 使其不与任何已注册公司冲突


## 清理失效（已释放）与已上车（不再等待）的认领记录。
func _prune_reservations() -> void:
	for id in _reservations.keys():
		if not is_instance_id_valid(id):
			_reservations.erase(id)
			continue
		var p := instance_from_id(id) as Object
		if p == null or not is_instance_valid(p):
			_reservations.erase(id)
			continue
		if p is Passenger and not (p as Passenger).is_waiting:
			_reservations.erase(id)
