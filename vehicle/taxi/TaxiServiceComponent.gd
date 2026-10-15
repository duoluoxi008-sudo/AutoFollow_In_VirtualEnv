extends Node3D
class_name TaxiServiceComponent

# ============================================================================
# TaxiServiceComponent —— 出租车"接送业务"组件（与 RL 无关）
#
# 把原来塞在 AITaxiController 里的、跟强化学习毫无关系的出租车业务逻辑抽出来，
# 成为一个可以挂在 **任何车里**（AI 车 / 玩家车 / 脚本控制的演示车）的组件：
#
#   1. 是否载客 / 当前所载乘客 / 当前锁定的目标乘客；
#   2. 接客 / 送达状态机（靠近 + 停稳才生效）；
#   3. 目标失效判定（被别的公司接走 / 被回收 / 消失）与"按本车视角重选目标"；
#   4. 向 PassengerManager 的派单器释放"本车公司的认领"；
#   5. 把手里未送达的乘客归还乘客对象池（回合重置 / 中途放弃）；
#   6. 公司/车队编号（同编号为队友，派单不互相抢）。
#
# 组件只认车、不认"谁在开车"：默认自己向上找 MMTVehicleBody，也可以用 vehicle 显式指定。
# 每个物理帧自己跑状态机（无需外部驱动），因此 AI 车和玩家车挂上就能用。
#
# 对外只发信号，不碰奖励/观测——那是 RL 层的事：
#   carrying_changed / passenger_picked_up / passenger_dropped_off / target_changed / target_stolen
# AITaxiController 只是订阅这些信号，把它们翻译成 reward 与 info 字段（"只收集"）。
# ============================================================================

## 本车公司/车队编号：同编号视为队友（派单互相避让），不同编号视为对手（纯竞争）。
@export var company_id: int = 0
## 靠近多近可以接客（米）
@export var pickup_radius: float = 2.0
## 靠近多近可以送达（米）
@export var dropoff_radius: float = 2.5
## 判定"停稳"的速度阈值（米/秒）：低于它才允许接客/送达
@export var stop_speed_threshold: float = 1.5
## 业务开关：false = 完全不干活（不选目标、不接客、不送达），用于接管/回放/调试
@export var service_enabled: bool = true
## 关联车辆。留空则自动向上查找 MMTVehicleBody。
@export var vehicle: MMTVehicleBody

@export_group("上客点")
## 上客点节点（推荐：在车辆场景里放一个 Marker3D 拖进来）。
## 留空则用 board_offset 按车身局部坐标推算。
@export var board_point: Marker3D
## 上客点相对车身原点的偏移（米，本车局部坐标，+X 为车身右侧）。
## 默认落在车身右侧车门外：车身半宽约 0.85 m，1.5 m 已经在车体外，乘客不会去挤车身。
@export var board_offset: Vector3 = Vector3(1.5, 0.0, 0.0)
## 乘客离上客点多近算"已经到车边"（米）。乘客侧用同一个口径发起上车请求。
@export_range(0.5, 8.0) var board_accept_radius: float = 2.0
## 乘客落座后的坐席位（相对车身原点）。
## 仅在"没有 PassengerManager 接手挂载"时由本组件使用（有管理器时用它的 passenger_seat_offset）。
@export var seat_offset: Vector3 = Vector3(0.0, 1.2, 0.0)

## 载客状态发生变化（接客 / 送达 / 归还）
signal carrying_changed(has_passenger: bool)
## 接到乘客
signal passenger_picked_up(passenger: Passenger)
## 送达乘客
signal passenger_dropped_off(passenger: Passenger)
## 锁定的目标乘客发生变化
signal target_changed(target: Passenger)
## 锁定的目标被**其它公司**抢走（同公司/队友抢走不算）
signal target_stolen(passenger: Passenger, by_company: int)

## 所有接送组件所在的分组（便于全局查找/调试）
const GROUP := &"taxi_services"

## 是否载客
var has_passenger: bool = false
## 当前所载的乘客（送达后置 null）
var carried_passenger: Passenger = null
## 空车时想要前往的目标乘客（载客时置 null）
var current_target: Passenger = null


func _ready() -> void:
	add_to_group(GROUP)
	_resolve_vehicle()


func _physics_process(delta: float) -> void:
	if not service_enabled:
		return
	tick_service(delta)


# ----------------------------------------------------------------------------
# 状态机
# ----------------------------------------------------------------------------

## 推进一帧接送状态机。外部也可以在 service_enabled=false 时手动调用来驱动。
func tick_service(_delta: float = 0.0) -> void:
	if not service_enabled or not has_vehicle():
		return
	var stopped := is_stopped()
	if has_passenger:
		_try_dropoff(stopped)
	else:
		_try_pickup(stopped)


## 车辆是否已经就位（组件可用）
func has_vehicle() -> bool:
	return vehicle != null and is_instance_valid(vehicle)


## 车辆是否"停稳"（低于 stop_speed_threshold）
func is_stopped() -> bool:
	if not has_vehicle():
		return false
	var state: Dictionary = vehicle.get_vehicle_state()
	return absf(float(state.get("forward_speed", 0.0))) <= stop_speed_threshold


## 空车：确保目标有效，并在"靠近 + 停稳"时接客。
func _try_pickup(stopped: bool) -> void:
	if not _is_valid_target(current_target):
		# 目标失效（被抢走 / 已上车 / 被回收）→ 判定被抢客并重选目标
		_on_target_lost()
		return
	if stopped and _planar_dist_to(current_target) <= pickup_radius:
		do_pickup(current_target)


## 载客：靠近目的地并停稳时送达。
func _try_dropoff(stopped: bool) -> void:
	var p := carried_passenger
	if p == null or not is_instance_valid(p):
		# 异常：手里没有人了，把状态复位（避免一直卡在"载客"相位）
		_set_carrying(false)
		carried_passenger = null
		return

	var dest: Node3D = p.destination
	if dest == null or not is_instance_valid(dest):
		dest = p  # 无目的地兜底：就地送达

	if stopped and _planar_dist_to(dest) <= dropoff_radius:
		do_dropoff(p)


## 空车时目标乘客失效：若被**其它公司**抢走则发 target_stolen（奖励由 RL 层自己扣），
## 然后按本车视角重选一个目标。
func _on_target_lost() -> void:
	var lost := current_target
	current_target = null

	if lost != null and is_instance_valid(lost):
		# 释放旧目标的"同车队认领"。不释放的话认领表只增不减，
		# 那个乘客会被本公司永久跳过（队友再也不会把它当目标）。
		release_target_reservation(lost)
		# picked_by 非空 = 真的被某辆车接走了；被回收到池里的乘客 picked_by 是 null，
		# 那种情况不算"被抢客"（旧实现在这里会误判并乱扣分）。
		var thief: Object = lost.picked_by
		if thief != null and is_instance_valid(thief) and lost.picked_by_company != company_id:
			target_stolen.emit(lost, lost.picked_by_company)

	acquire_target()


# ----------------------------------------------------------------------------
# 接客 / 送达（也可以被外部/脚本直接调用）
# ----------------------------------------------------------------------------

## 上客点的世界坐标：优先用显式指定的 board_point，其次按 board_offset 从车身推算。
func get_board_position() -> Vector3:
	if board_point != null and is_instance_valid(board_point):
		return board_point.global_position
	if not has_vehicle():
		return Vector3.ZERO
	return vehicle.global_transform * board_offset


## 乘客是否已经站在上客点附近（水平距离，忽略高度）。
func is_passenger_at_board(p: Passenger) -> bool:
	if p == null or not is_instance_valid(p):
		return false
	var d := _planar_dist_to_point(p.global_position, get_board_position())
	return d <= board_accept_radius


## 乘客侧"我到车边了"的入口 —— 这是**乘客主动上车**那条链路。
##
## 与 `_try_pickup`（车开过去靠近乘客）互补，两条链路最后都汇到 `do_pickup()`，
## 所以载客状态、信号、派单认领、重新挂载的行为完全一致。
##
## 接客条件（缺一不可）：
##   - 业务开启、本车没载人、乘客还在等待（is_waiting）
##   - **本车停稳**（|forward_speed| ≤ stop_speed_threshold）
##   - 乘客在上客点 board_accept_radius 之内
## 该乘客不一定是派单器分配给本车的目标（场景里没有 PassengerManager、
## 或者它自己走到本车旁边都会这样）：先释放旧目标的认领，再把它接上车。
func request_pickup(p: Passenger) -> bool:
	if not service_enabled or not has_vehicle():
		return false
	if has_passenger:
		return false
	if not _is_valid_target(p):
		return false
	if not is_stopped():
		# 车还在动：这是"通知失败但不算错"，乘客继续在车边等，下一帧会再请求。
		return false
	if not is_passenger_at_board(p):
		return false

	if current_target != null and current_target != p:
		clear_target()

	return do_pickup(p)


## 接客。返回 false 表示目标无效（没上车）。
func do_pickup(p: Passenger) -> bool:
	if not _is_valid_target(p):
		return false

	# 先置位、再 pick_up()：pick_up() 会同步发 boarded 信号，
	# PassengerManager 在那个回调里就要读 picked_by / 状态来做重新挂载。
	carried_passenger = p
	current_target = null
	p.picked_by = self
	p.picked_by_company = company_id
	_set_carrying(true)

	# 注意：如果没有任何 PassengerManager（例如纯玩家场景里手摆的乘客），
	# 下面这行不会有人接手"挂到车上"，于是靠后面的兜底自己挂。
	p.pick_up()

	# 兜底挂载：正常情况下 PassengerManager 已经在 boarded 回调里把乘客挂到车上了；
	# 没有管理器（或它没接手）时由本组件补上，保证"上了车"是真的坐在车上、
	# 而不是留在原地而车上却记着载了一个人。
	if has_vehicle() and p.get_parent() != vehicle:
		p.board_into(vehicle, seat_offset)

	passenger_picked_up.emit(p)
	return true


## 送达：通知目的地、发信号、把乘客回收到对象池。
func do_dropoff(p: Passenger) -> void:
	if p == null or not is_instance_valid(p):
		return

	if carried_passenger == p:
		carried_passenger = null
	_set_carrying(false)
	current_target = null

	# 通知目的地：回减占用、统计送达数（若是 PassengerDestination）
	var dest: Node3D = p.destination
	if dest != null and is_instance_valid(dest) and dest.has_method("notify_delivered"):
		dest.notify_delivered()
	p.drop_off()

	passenger_dropped_off.emit(p)

	# 送达的乘客回收到对象池（不再 queue_free）。目的地占用已在上面的
	# notify_delivered() 里结算，所以传 delivered=true 不再重复回减。
	_recycle(p, true)


## 归还手里未送达的乘客 → 回收到乘客对象池（目的地占用一并释放）。
## 供回合重置 / 中途放弃（换车、下车、超时）调用。
func return_carried_passenger() -> void:
	var p := carried_passenger
	carried_passenger = null
	_set_carrying(false)
	if p != null and is_instance_valid(p):
		_recycle(p, false)


# ----------------------------------------------------------------------------
# 目标与派单认领
# ----------------------------------------------------------------------------

## 从 PassengerManager 的派单器按 **本车视角** 重新选一个目标乘客（竞争模式）。
#expose
func acquire_target() -> Passenger:
	var mgr := get_passenger_manager()
	if mgr == null:
		if current_target != null:
			current_target = null
			target_changed.emit(null)
		return null

	var p := mgr.assign_passenger(self)
	if p != current_target:
		current_target = p
		target_changed.emit(p)
	return p


## 释放某个乘客在本车公司的派单认领（PassengerDistributeManager._reservations）。
## 认领表只在"乘客已上车 / 实例失效"时自动清理，所以换目标 / 回合重置时必须显式释放，
## 否则那个乘客会被本公司永久跳过。
func release_target_reservation(p: Passenger) -> void:
	if p == null or not is_instance_valid(p):
		return
	var mgr := get_passenger_manager()
	if mgr != null:
		mgr.release_passenger(p)


## 放弃当前目标（释放认领并置空）。
func clear_target() -> void:
	var p := current_target
	current_target = null
	release_target_reservation(p)
	if p != null:
		target_changed.emit(null)


## 一站式清零：归还手里的人 + 放弃目标 + 清空状态。
## 回合重置（RL）与"重新部署"都调这个。
#expose
func reset_service() -> void:
	return_carried_passenger()
	clear_target()


# ----------------------------------------------------------------------------
# 查询
# ----------------------------------------------------------------------------

func is_carrying() -> bool:
	return has_passenger


func get_vehicle() -> MMTVehicleBody:
	return vehicle


func get_company_id() -> int:
	return company_id


## 取得"本车所属 arena"的乘客管理器。
##
## ⚠️ 多 arena 同进程时必须按 arena 取，不能用全局组：
## `get_first_node_in_group("passenger_manager")` 只会返回第一个场地（arena 1）的管理器，
## 于是 arena 2/3 的车会去 arena 1 的乘客列表里选目标 —— 那个乘客不在自己场地里，
## 永远开不到，表现为 `task/pickups` 恒为 0。
##
## 兜底保留全局查找，是为了兼容"没有 TrainingArena 的旧场景/单场景"用法。
#expose
func get_passenger_manager() -> PassengerManager:
	var arena := TrainingArena.of(self)
	if arena != null:
		var m := arena.get_passenger_manager()
		if m != null:
			return m
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("passenger_manager") as PassengerManager


## 当前"该开去哪"的节点：载客时是送达目的地，空车时是目标乘客；没有则 null。
## 供寻路/HUD/传感器复用，避免各自实现一套。
#expose
func get_navigation_target() -> Node3D:
	if has_passenger:
		var p := carried_passenger
		if p != null and is_instance_valid(p):
			var d: Node3D = p.destination
			if d != null and is_instance_valid(d):
				return d
			return p
		return null
	if _is_valid_target(current_target):
		return current_target
	return null


## 开关业务（false 时不再选目标/接客/送达）
func set_service_enabled(enabled: bool) -> void:
	service_enabled = enabled


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

func _set_carrying(value: bool) -> void:
	if has_passenger == value:
		return
	has_passenger = value
	carrying_changed.emit(value)


func _is_valid_target(p: Passenger) -> bool:
	return p != null and is_instance_valid(p) and p.is_waiting


func _recycle(p: Passenger, delivered: bool) -> void:
	var mgr := get_passenger_manager()
	if mgr != null:
		# delivered=false：这趟没送到，要在这里释放目的地占用
		mgr.recycle_passenger(p, delivered)
	elif not p.is_queued_for_deletion():
		p.queue_free()


func _resolve_vehicle() -> void:
	if vehicle != null and is_instance_valid(vehicle):
		return
	vehicle = find_vehicle_of(self)


## 本车到某个节点的水平距离（忽略高度）。
func _planar_dist_to(node3d: Node3D) -> float:
	if node3d == null or not is_instance_valid(node3d):
		return INF
	if not has_vehicle():
		return INF
	return _planar_dist_to_point(vehicle.global_transform.origin, node3d.global_position)


## 两个世界坐标之间的水平距离（忽略高度）。
func _planar_dist_to_point(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


# ----------------------------------------------------------------------------
# 静态工具：从任意节点找到"所属车辆"与"车上的接送组件"
# ----------------------------------------------------------------------------

## 从任意节点向上找到所属的 MMTVehicleBody。
static func find_vehicle_of(node: Node) -> MMTVehicleBody:
	var n: Node = node
	while n != null:
		if n is MMTVehicleBody:
			return n as MMTVehicleBody
		n = n.get_parent()
	return null


## 找到 node 所属车辆上的接送组件（node 自己就是组件时直接返回）。找不到返回 null。
#expose
static func find_for(node: Node) -> TaxiServiceComponent:
	if node == null or not is_instance_valid(node):
		return null
	if node is TaxiServiceComponent:
		return node as TaxiServiceComponent
	var v := find_vehicle_of(node)
	if v == null:
		return null
	return find_in_subtree(v)


## 在子树里深度优先查找接送组件。
static func find_in_subtree(root: Node) -> TaxiServiceComponent:
	if root == null:
		return null
	for child in root.get_children():
		if child is TaxiServiceComponent:
			return child as TaxiServiceComponent
		var found := find_in_subtree(child)
		if found != null:
			return found
	return null
