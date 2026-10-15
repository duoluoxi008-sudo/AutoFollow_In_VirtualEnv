extends Node3D
class_name TrainingArena

# ============================================================================
# TrainingArena —— 训练场地（arena）根节点
#
# 一个 arena = 一份完整的训练环境：地图 + 生成点 + 目的地 + 两个管理器 + 运行时生成的车。
# 同一个 Godot 进程里可以并排实例化多份 arena，外面套**一个** Sync 就能一次收下所有车
# （godot_rl 的 Sync._get_agents() 扫的是全局 "AGENT" 组，所以 N 个 arena 的车天然都被它收走）。
#
# 这个脚本干两件事：
#
#   1. **自报就绪**：车不是摆在场景文件里的，而是 VehicleSpawnManager 用
#      `call_deferred("_spawn_fleet")` 运行时造的。所以"arena 就绪"必须由 arena 自己判断：
#      等自己的车队生成完（fleet_ready）再 emit arena_ready。
#      外层 Sync 只需要等所有 arena 的 arena_ready —— 这就是把"等待"从 Sync 下沉到 arena。
#
#   2. **当本场地的锚点**：arena 内部的任何节点都能用 `TrainingArena.of(self)` 沿祖先找到它，
#      再从它身上拿本场地的 manager/上下文。纯类型判定，不用全局组，天然不会串场地。
#
# 收集方式遵循项目约定：**父节点.get_children() + 类型判定**，不用组、不递归。
# ============================================================================

## 本场地就绪：地图摆好、车队生成完、乘客/目的地收集完
signal arena_ready

## 等待车队生成的超时（秒）。超时只告警、不阻塞（避免某个生成器没启动就永久挂住）
@export var ready_timeout: float = 12.0
## 是否在 _ready 后自动走就绪流程（关掉就完全手动，由外部调 mark_ready()）
@export var auto_setup: bool = true

## 本场地的车辆生成管理器（= 直接子节点里的那个 VehicleSpawnManager）
var vehicle_spawn_manager: VehicleSpawnManager
## 本场地的乘客管理器（= 直接子节点里的那个 PassengerManager）
var passenger_manager: PassengerManager
## 是否已经就绪
#expose
var is_ready: bool = false


func _ready() -> void:
	if auto_setup:
		# deferred：等本节点的所有子节点 _ready 跑完（管理器会把它们的 deferred 生成排好队）
		call_deferred("_setup")


func _setup() -> void:
	resolve_managers()
	if needs_to_wait_for_fleet():
		await _wait_for_fleet()
	# 再放一帧：让两个管理器 deferred 的 _collect() / _spawn_fleet() 也跑完
	await get_tree().process_frame
	mark_ready()


# ----------------------------------------------------------------------------
# 就绪流程（拆成几个同步小函数，方便单测/外部驱动）
# ----------------------------------------------------------------------------

## 找到本场地的管理器：**直接子节点 + 类型判定**（不用组、不递归）
func resolve_managers() -> void:
	for c in get_children():
		if c is VehicleSpawnManager:
			vehicle_spawn_manager = c as VehicleSpawnManager
		elif c is PassengerManager:
			passenger_manager = c as PassengerManager
	if vehicle_spawn_manager == null:
		push_warning("[TrainingArena] %s：没找到 VehicleSpawnManager（它应该是本节点的直接子节点）。" % name)
	if passenger_manager == null:
		push_warning("[TrainingArena] %s：没找到 PassengerManager（它应该是本节点的直接子节点）。" % name)


## 是否需要等车队：只有"自动生成 + 一辆都还没造出来"时才等。
## （车静态摆在场景里、或已经生成完了，都不需要等。）
func needs_to_wait_for_fleet() -> bool:
	if vehicle_spawn_manager == null or not is_instance_valid(vehicle_spawn_manager):
		return false
	if not vehicle_spawn_manager.auto_spawn:
		return false
	return vehicle_spawn_manager.vehicles.is_empty()


## 等车队生成完（fleet_ready），带**真实超时**：超时只告警，不会永久挂住。
func _wait_for_fleet() -> void:
	var mgr := vehicle_spawn_manager
	var done := [false]
	var on_ready := func() -> void: done[0] = true
	mgr.fleet_ready.connect(on_ready)
	# 再确认一次：deferred 的顺序有可能让车队在我们连信号之前就生成完了
	if mgr.vehicles.is_empty():
		var deadline := Time.get_ticks_msec() + int(ready_timeout * 1000.0)
		while not done[0] and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if not done[0]:
			push_warning(
				"[TrainingArena] %s：等待车队生成超时（%.1f 秒）。请检查 VehicleSpawnManager "
				% [name, ready_timeout]
				+ "的 car_scene / spawner_root / 生成点数量。"
			)
	if mgr.fleet_ready.is_connected(on_ready):
		mgr.fleet_ready.disconnect(on_ready)


## 标记就绪并发信号（幂等；手动流程也可以直接调它）
func mark_ready() -> void:
	if is_ready:
		return
	is_ready = true
	arena_ready.emit()


# ----------------------------------------------------------------------------
# 取本场地的管理器（arena 内部节点用；带懒解析）
# ----------------------------------------------------------------------------

#expose
func get_passenger_manager() -> PassengerManager:
	if passenger_manager == null or not is_instance_valid(passenger_manager):
		resolve_managers()
	return passenger_manager


#expose
func get_vehicle_spawn_manager() -> VehicleSpawnManager:
	if vehicle_spawn_manager == null or not is_instance_valid(vehicle_spawn_manager):
		resolve_managers()
	return vehicle_spawn_manager


## 本场地当前车辆数（诊断用）
#expose
func vehicle_count() -> int:
	if vehicle_spawn_manager == null or not is_instance_valid(vehicle_spawn_manager):
		return 0
	return vehicle_spawn_manager.vehicles.size()


func _to_string() -> String:
	return "TrainingArena(%s, ready=%s, vehicles=%d)" % [name, is_ready, vehicle_count()]


# ----------------------------------------------------------------------------
# 静态工具：沿祖先找到"我属于哪个 arena"（纯类型判定，不用组）
# ----------------------------------------------------------------------------

## 从任意节点向上找到所属的 TrainingArena；不在任何 arena 里时返回 null。
#expose
static func of(node: Node) -> TrainingArena:
	var n: Node = node
	while n != null:
		if n is TrainingArena:
			return n as TrainingArena
		n = n.get_parent()
	return null
