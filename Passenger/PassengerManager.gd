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
# 也支持把目的地标记（组 "destinations" 或导出的 destinations 数组）作为乘客的送达点。
# ============================================================================

## 乘客场景（默认指向真正的 Passenger.tscn）
@export var passenger_scene: PackedScene = preload("res://Passenger/Passenger.tscn")

## 生成点数组：若为空则在 _ready 时按组自动收集
@export var spawners: Array[PassengerSpawner] = []
## 是否在 _ready 时自动收集场景里的生成点
@export var auto_collect: bool = true

## 目的地（送达点）节点数组：若为空且 auto_collect_destinations 为真，则按组收集
@export var destinations: Array[Node3D] = []
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

# --- 已生成（等待中）的乘客，供派单器扫描 ---
var passengers: Array[Passenger] = []

## 合并进来的派单器
var _distribute: PassengerDistributeManager

var _timer: Timer


func _ready() -> void:
	add_to_group("passenger_manager")
	_distribute = PassengerDistributeManager.new()
	_distribute.setup(self)
	add_child(_distribute)

	if auto_collect:
		call_deferred("_collect")
	if auto_spawn:
		_start_timer()


## 收集生成点与目的地。用 deferred 确保所有子节点已 ready（已加入对应 group）。
func _collect() -> void:
	spawners.clear()
	if auto_collect:
		for n in get_tree().get_nodes_in_group("passenger_spawners"):
			if n is PassengerSpawner and n != null and is_instance_valid(n):
				var s := n as PassengerSpawner
				spawners.append(s)
				if s.manager == null:
					s.manager = self

	if destinations.is_empty() and auto_collect_destinations:
		var d: Array[Node3D] = []
		for n in get_tree().get_nodes_in_group("destinations"):
			if n is Node3D and n != null and is_instance_valid(n):
				d.append(n as Node3D)
		destinations = d


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
		var p := free[i % free.size()].spawn_passenger()
		if p != null:
			_on_passenger_spawned(p)


## 乘客生成后登记，便于数量统计与派单扫描。
func _on_passenger_spawned(p: Passenger) -> void:
	passengers.append(p)
	increase_current_number()
	p.tree_exited.connect(func() -> void:
		passengers.erase(p)
		decrease_current_number()
	)


# ----------------------------------------------------------------------------
# 派单接口（委托给合并进来的 PassengerDistributeManager）
# ----------------------------------------------------------------------------
func assign_passenger(taxi: Node3D) -> Passenger:
	if _distribute == null:
		return null
	# 竞争模式：从 taxi 视角挑最佳目标，不做认领
	return _distribute.pick_best_target_for(taxi)


func release_passenger(passenger: Passenger) -> void:
	if _distribute != null:
		_distribute.release(passenger)


func is_claimed(passenger: Passenger) -> bool:
	return _distribute != null and _distribute.is_claimed(passenger)


## RL 回合重置：清空所有乘客、计数，并让每个生成点恢复可再次生成。
## 因为 PassengerManager 是场景节点，随场景/回合重建时自然随之复位；此方法用于手动复位。
func reset() -> void:
	for p in passengers:
		if p != null and is_instance_valid(p):
			p.free()
	passengers.clear()
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


## 随机挑一个目的地；没有目的地则返回 null
func pick_destination() -> Node3D:
	if destinations.is_empty():
		return null
	return destinations[randi_range(0, destinations.size() - 1)]


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


func increase_current_number() -> void:
	current_number += 1


func decrease_current_number() -> void:
	current_number = maxi(0, current_number - 1)
