extends Node
class_name PassengerManager

# ============================================================================
# PassengerManager —— 游戏主场景的乘客生成/派单总管
#
# 挂在主场景上，职责：
#   1. 收集场景里所有 PassengerSpawner（组 "passenger_spawners"）到 spawners。
#   2. 定时/按需从"尚未生成乘客（spawned == false）"的生成点里随机挑一个或多个，
#      调用其 spawn_passenger()（工厂：控制会不会移动 + 目的地）。
#   3. 合并 PassengerDistributeManager，从而具备"距离 + 等待时长优先级"的派单功能
#      （assign_passenger / release / is_claimed）。
#
# 生成点生命周期（与"上车即补员"不同，见 _on_passenger_boarded）：
#   生成（spawned = true）→ 被接走（**仍然保持占用**，跟着这趟行程）→
#   送达 / 被回收入池（spawned = false，该点可以再次生成）
#
# 也支持把目的地标记（组 "destinations" 或导出的 destinations 数组）作为乘客的送达点。
# ============================================================================

## 乘客场景（默认指向真正的 Passenger.tscn）
@export var passenger_scene: PackedScene = preload("res://Passenger/Passenger.tscn")

## 生成点数组：若为空则在 _ready 时自动收集
@export var spawners: Array[PassengerSpawner] = []
## 是否在 _ready 时自动收集场景里的生成点
@export var auto_collect: bool = true

## 生成点所在的**分组节点**（在检视器里把 arena 里的 "SpawnerMark/PassengerSpawner" 拖进来）。
## 收集就是 `spawner_root.get_children()` + 类型判定：每个 arena 各拖自己的那个，
## 天然只收到本场地的生成点，不需要任何全局组。
## 留空时的兜底：从本节点的父节点往下按类型递归找（同样不用全局组）。
##
## ⚠️ 必须是 `Node3D`（不能是普通 `Node`）：`Node3D` 的 `global_transform` 只在
## **直接父级也是 Node3D** 时逐级相乘，中间夹一个普通 `Node` 会把子节点的世界坐标
## 截断成"局部坐标"（表现为"移动 arena，出生点不跟着走"，多 arena 时所有场地的
## 生成点会挤在同一个地方）。所以场景里这个分组节点也必须是 Node3D。
@export var spawner_root: Node3D

## 目的地所在的**分组节点**（把 arena 里的 "Destination" 拖进来）。同样必须是 Node3D。
@export var destination_root: Node3D

## 目的地（送达点）节点数组：若为空且 auto_collect_destinations 为真，则自动收集
@export var destinations: Array[Marker3D] = []
@export var auto_collect_destinations: bool = true

# --- 数量上限 ---
@export var is_control_max_number: bool = true
@export var max_number: int = 12
var current_number: int = 0

# --- 生成节奏 ---
@export var auto_spawn: bool = true
@export var spawn_interval: float = 2.0
## 每轮最多随机选取的生成点数量
@export var max_spawn_per_tick: int = 1
## 生成的乘客"会不会移动"的概率（其余原地等待）
@export_range(0.0, 1.0) var moving_probability: float = 0.5

# --- 乘客上车 ---
## 乘客被接上后的局部坐席位（相对车的原点）。
## 注意：上车后乘客会被隐藏（见 Passenger.set_carried），这个偏移量只决定
## 隐藏节点的挂载位置，不影响可见效果；保留它是为了让"下车再复用"时位置一致。
@export var passenger_seat_offset: Vector3 = Vector3(0.0, 1.2, 0.0)

# --- 已生成（等待中）的乘客，供派单器扫描 ---
var passengers: Array[Passenger] = []

## 合并进来的派单器
var _distribute: PassengerDistributeManager

var _timer: Timer

# --- 乘客对象池 ---
## 已回收、处于惰性（隐藏 + 无物理 + 无碰撞）状态的乘客实例，下次生成时优先复用。
## 池里的实例**不在** passengers 里，也不计入 current_number。
var _pool: Array[Passenger] = []
## 占用表：Passenger -> PassengerSpawner。用来在"上车 / 回收"时准确释放对应生成点，
## 避免像以前那样靠实例自身的 tree_exited 信号去猜。
var _holder: Dictionary = {}


func _ready() -> void:
	add_to_group("passenger_manager")
	# 让 sync.gd 的 call 广播能把 get_env_stats 查询送到本管理器（它不是 AGENT 节点）
	add_to_group("rl_stats_providers")
	_distribute = PassengerDistributeManager.new()
	_distribute.setup(self)
	add_child(_distribute)

	if auto_collect:
		call_deferred("_collect")
	if auto_spawn:
		_start_timer()


## 收集生成点与目的地。用 deferred 确保所有子节点已 ready。
##
## 收集来源是**场景内的分组节点**（spawner_root / destination_root，在检视器里拖），
## 不是全局组：多 arena 同进程时，全局组会把别的场地的生成点/目的地一起收进来
## （表现为车被传到别的场地、乘客生成在别处、目的地被重复 assign）。
func _collect() -> void:
	spawners.clear()
	if auto_collect:
		for s in collect_spawners():
			spawners.append(s)
			if s.manager == null:
				s.manager = self

	if destinations.is_empty() and auto_collect_destinations:
		destinations = collect_destinations()


## 收集本场地的生成点：优先用显式指定的 spawner_root 的**直接子级**，
## 没配时才从本节点的父节点往下按类型递归找。
func collect_spawners() -> Array[PassengerSpawner]:
	var found: Array[PassengerSpawner] = []
	if spawner_root != null and is_instance_valid(spawner_root):
		for c in spawner_root.get_children():
			if c is PassengerSpawner and is_instance_valid(c):
				found.append(c as PassengerSpawner)
		return found
	var base := get_parent()
	if base == null:
		return found
	# 兜底：递归但不越出"本节点的父节点"这一层，所以仍然是场景作用域。
	# owned 必须显式传 false：运行时 instantiate 出来的节点没有 owner，
	# owned=true 会把它们整片跳过。
	for n in base.find_children("*", "PassengerSpawner", true, false):
		if n is PassengerSpawner and is_instance_valid(n):
			found.append(n as PassengerSpawner)
	return found


## 收集本场地的目的地：优先用显式指定的 destination_root 的**直接子级**，
## 没配时才从父节点往下递归找（目的地文件夹里通常直接摆 Marker3D）。
func collect_destinations() -> Array[Marker3D]:
	var found: Array[Marker3D] = []
	if destination_root != null and is_instance_valid(destination_root):
		for c in destination_root.get_children():
			if c is Marker3D and is_instance_valid(c):
				found.append(c as Marker3D)
		return found
	var base := get_parent()
	if base == null:
		return found
	# 兜底：递归但不越出"本节点的父节点"这一层，所以仍然是场景作用域。
	# owned 必须显式传 false：运行时 instantiate 出来的节点没有 owner，
	# owned=true 会把它们整片跳过。
	#
	# 这里只认 PassengerDestination：普通 Marker3D 目的地没法跟"别的 Marker3D"区分
	# （车辆生成点 VehicleSpawner 的根节点也是 Marker3D），所以想用普通 Marker3D
	# 当目的地就必须显式拖 destination_root。
	for n in base.find_children("*", "PassengerDestination", true, false):
		if n is Marker3D and is_instance_valid(n):
			found.append(n as Marker3D)
	return found


func _start_timer() -> void:
	if _timer != null:
		return
	_timer = Timer.new()
	_timer.wait_time = spawn_interval
	_timer.autostart = true
	_timer.one_shot = false
	_timer.timeout.connect(_on_spawn_tick)
	add_child(_timer)


## 每 tick：随机挑一个或多个"尚未生成的"生成点去生成乘客。
func _on_spawn_tick() -> void:
	if not can_spawn():
		return
	_spawn_random_free_spawners()


func _spawn_random_free_spawners() -> void:
	var free: Array[PassengerSpawner] = []
	for s in spawners:
		if s != null and is_instance_valid(s) and not s.spawned:
			free.append(s)
	if free.is_empty():
		return

	# 随机选 1..max_spawn_per_tick 个（且不超过剩余容量与空闲数量）
	var want := randi_range(1, maxi(1, mini(max_spawn_per_tick, free.size())))
	free.shuffle()

	for i in range(want):
		if not can_spawn():
			break
		# 生成点会在 spawn_passenger() 里调用 attach_to_spawner() 完成登记，
		# 所以这里不再重复登记（否则会重复计入 current_number）。
		free[i % free.size()].spawn_passenger()


# ----------------------------------------------------------------------------
# 乘客对象池：领取 / 登记 / 回收
# ----------------------------------------------------------------------------
## 领取一个乘客实例：优先复用池里的，池空则新建。
func acquire_passenger() -> Passenger:
	while not _pool.is_empty():
		var pooled: Passenger = _pool.pop_back()
		if pooled != null and is_instance_valid(pooled):
			return pooled
	return _make_passenger()


## 新建一个乘客实例并接好生命周期信号。
## 每个实例只在这里接一次信号，池化复用时不会再接，所以不会重复触发。
func _make_passenger() -> Passenger:
	var scene: PackedScene = get_passenger_scene()
	if scene == null:
		return null
	var p := scene.instantiate() as Passenger
	if p == null:
		return null
	# 用 bind 出来的 Callable 是稳定的，便于判断/避免重复连接。
	# 注意用字符串形式的 connect()：脚本自定义信号走 "obj.signal.connect()" 这种
	# 属性访问时，在动态接收者上会报 "Invalid access to property or key"，字符串形式最稳。
	p.connect("boarded", _on_passenger_boarded.bind(p))
	# 兜底：万一有外部代码真的 free 了乘客，也要把名额与生成点占用还回去。
	# 注意池化复用只会 reparent，同样会触发 tree_exited，所以必须区分"真销毁"。
	# 上车后生成点会一直保留到行程结束，所以这里必须连 _release_holder 一起做，
	# 否则中途被 free 的乘客会让那个生成点永远卡在"已占用"。
	p.tree_exited.connect(func() -> void:
		if p.is_queued_for_deletion():
			_release_holder(p)
			_forget_waiting(p)
	)
	return p


## 由 PassengerSpawner 调用：乘客落到某个生成点 → 登记占用 + 计入"等待中"。
func attach_to_spawner(p: Passenger, s: PassengerSpawner) -> void:
	if p == null or not is_instance_valid(p):
		return
	_holder[p] = s
	if s != null:
		s.spawned = true
		s.passenger = p
	if not passengers.has(p):
		passengers.append(p)
		increase_current_number()


## 释放乘客当前占用的生成点（**送达 / 回收 / 清场**时调用；上车时**不**调用）。
##
## 只有"该生成点当前登记的确实是这个乘客"时才清掉它的占用标记：
## 生成点在上车后会一直保留到行程结束，期间万一被清场重置后又复用了
## （例如 PassengerManager.reset() 把生成点全部放开），这次迟到的释放
## 就不该把新乘客的占用标记一起抹掉。
func _release_holder(p: Passenger) -> void:
	var s: Variant = _holder.get(p)
	_holder.erase(p)
	if s == null or not is_instance_valid(s):
		return
	var sp := s as PassengerSpawner
	if sp.passenger == p:
		sp.passenger = null
		sp.spawned = false


## 把乘客从"等待中"名单里摘掉并归还名额（上车 / 回收 / 真销毁时调用）。
func _forget_waiting(p: Passenger) -> void:
	var idx := passengers.find(p)
	if idx >= 0:
		passengers.remove_at(idx)
		decrease_current_number()


## 回收一个乘客实例入池：从车上/生成点上摘下来、停用、放进池子等待复用。
## delivered=true 表示"已送达"（目的地占用已在送达流程里结算过）；
## delivered=false 表示"被回合重置打断"等中途放弃，需要在这里释放目的地占用。
#expose
func recycle_passenger(p: Passenger, delivered: bool = false) -> void:
	if p == null or not is_instance_valid(p):
		return
	_release_holder(p)
	_forget_waiting(p)
	if _distribute != null:
		_distribute.release(p)
	if not delivered and p.destination is PassengerDestination:
		(p.destination as PassengerDestination).unassign()
	# 先把乘客切到惰性态（隐藏 + 挪到不检测层），再改父级。
	# 顺序很重要：反过来的话，乘客会先以可见状态挂在管理器下，
	# 有几率闪一帧。
	p.deactivate_for_pool()
	var prev := p.get_parent()
	if prev != null:
		prev.remove_child(p)
	add_child(p)
	if not _pool.has(p):
		_pool.append(p)


## 清空场上所有"等待中"的乘客（生成点一并释放），池里的实例保留待复用。
func clear_waiting_passengers() -> void:
	for p in passengers.duplicate():
		recycle_passenger(p, false)


## 乘客上车（boarded 信号）：把乘客挂到所载车辆上。
##
## ⚠️ 这里**不释放生成点**：生成点跟着这趟行程走 —— 它那位乘客还在车上，
## 这个点就一直保持"占用"，直到送达 / 被回收入池时由 recycle_passenger() 释放。
## 否则会出现"刚接走人，下一次 spawn tick（≤ spawn_interval）就在同一个点上
## 刷出一个新乘客"，而且那个点往往就在接客的车旁边。
func _on_passenger_boarded(p: Passenger) -> void:
	if p == null or not is_instance_valid(p):
		return

	# 结算"等待中"的登记：等待名单、名额、派单认领。
	# 注意这里**故意不调用** _release_holder()：生成点留到行程结束再释放。
	_forget_waiting(p)
	if _distribute != null:
		_distribute.release(p)

	# 载具解析：picked_by 可能是 AITaxiController（RL/AI 车），也可能是
	# TaxiServiceComponent（玩家车/通用组件）——只要它能给出所属车辆即可。
	var vehicle := _resolve_carrier_vehicle(p.picked_by)
	if vehicle == null:
		return

	# 落座：从原父级摘下来挂到车上、摆到坐席位，并切到"车上态"
	# （隐藏 + 碰撞层挪到不检测层）。具体实现放在 Passenger.board_into()，
	# 这样没有 PassengerManager 的场景（纯玩家场景）里由 TaxiServiceComponent
	# 调用同一个方法兜底，两条路径的落座行为不会跑偏。
	p.board_into(vehicle, passenger_seat_offset)


## 把"接走乘客的一方"解析成车辆。
## 兼容两类载体：TaxiServiceComponent（玩家/通用）与 AITaxiController（旧/RL），
## 也允许直接传车辆本身。
func _resolve_carrier_vehicle(carrier: Object) -> MMTVehicleBody:
	if carrier == null or not is_instance_valid(carrier):
		return null
	if carrier is MMTVehicleBody:
		return carrier as MMTVehicleBody
	if carrier.has_method("get_vehicle"):
		var v: Variant = carrier.call("get_vehicle")
		if v is MMTVehicleBody:
			return v as MMTVehicleBody
	return null


# ----------------------------------------------------------------------------
# 派单接口（委托给合并进来的 PassengerDistributeManager）
# ----------------------------------------------------------------------------
#expose
func assign_passenger(taxi: Node3D) -> Passenger:
	if _distribute == null:
		return null
	# 竞争模式：从 taxi 视角挑最佳目标，不做认领
	return _distribute.pick_best_target_for(taxi)


## 只读版派单查询（**不写认领表**）。传感器 / 观测一律用这个：
## 观测函数调用会写认领表的版本，会造成"传感器先把乘客认领掉、业务层再也拿不到"
## 的死锁（详见 PassengerDistributeManager.peek_best_target_for 的说明）。
#expose
func peek_passenger(taxi: Node3D) -> Passenger:
	if _distribute == null:
		return null
	return _distribute.peek_best_target_for(taxi)


#expose
func release_passenger(passenger: Passenger) -> void:
	if _distribute != null:
		_distribute.release(passenger)


#expose
func is_claimed(passenger: Passenger) -> bool:
	return _distribute != null and _distribute.is_claimed(passenger)


## RL 回合重置：把所有"等待中"的乘客回收入池，并让每个生成点恢复可再次生成。
## 注意：这里**不再 free**（对象池化）；已被接上车的那部分由各自车辆在
## AITaxiContorller._reset_episode() 里调用 recycle_passenger() 归还。
func reset() -> void:
	clear_waiting_passengers()
	current_number = 0
	for s in spawners:
		if s != null and is_instance_valid(s):
			s.reset_spawn_state()


# ----------------------------------------------------------------------------
# 工厂需要的配置来源
# ----------------------------------------------------------------------------
## 随机决定新乘客"会不会移动"
func roll_moving() -> bool:
	return randf() < moving_probability


## 随机挑一个目的地；没有可用目的地则返回 null。
## 只选 active 的目的地，并优先选当前占用（assigned_count）最少者以做负载均衡。
func pick_destination() -> Node3D:
	if destinations.is_empty():
		return null
	var best: Marker3D = null
	var best_count := 0
	for d in destinations:
		if d == null or not is_instance_valid(d):
			continue
		if d is PassengerDestination:
			var pd := d as PassengerDestination
			if not pd.is_active():
				continue
			var c := pd.assigned_count
			if best == null or c < best_count:
				best = d
				best_count = c
		else:
			# 普通 Marker3D 目的地：始终可用，取第一个
			if best == null:
				best = d
	if best == null:
		return null
	if best is PassengerDestination:
		(best as PassengerDestination).assign()
	return best


func get_passenger_scene() -> PackedScene:
	return passenger_scene


# ----------------------------------------------------------------------------
# 数量控制
# ----------------------------------------------------------------------------
func can_spawn() -> bool:
	if is_control_max_number and current_number >= max_number:
		return false
	return true


## 兼容旧接口
func request_spawn() -> bool:
	return can_spawn()


# ----------------------------------------------------------------------------
# Python 训练侧接口
# ----------------------------------------------------------------------------
## 上帝视角统计：供 Python 侧判断"环境是否还在正常运转"（乘客是否还在生成）。
## 通过 sync 的 call 消息调用：env.call("get_env_stats")
func get_env_stats() -> Dictionary:
	var waiting := 0
	for p in passengers:
		if p != null and is_instance_valid(p) and p.is_waiting:
			waiting += 1
	var free_spawners := 0
	for s in spawners:
		if s != null and is_instance_valid(s) and not s.spawned:
			free_spawners += 1
	return {
		"passengers_alive": passengers.size(),
		"passengers_waiting": waiting,
		"current_number": current_number,
		"free_spawners": free_spawners,
		"max_number": max_number,
		"pool_size": _pool.size(),
	}


func increase_current_number() -> void:
	current_number += 1


func decrease_current_number() -> void:
	current_number = maxi(0, current_number - 1)
