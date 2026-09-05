extends Marker3D
class_name PassengerSpawner

# ============================================================================
# PassengerSpawner —— 乘客生成点
#
# 工厂函数 spawn_passenger():
#   - 调用 manager 拿到乘客场景、随机目的地、是否移动等配置
#   - 实例化 Passenger 并放到生成点位置
#   - 把 spawned 置为 true（表示"已生成、仍在等待被接走"），并连接 boarded 信号
#
# spawned 语义（按需求）：
#   - true  = 本生成点已经生成了一个"还没上车"的乘客
#   - false = 还没生成，或者生成的乘客已被接走（上车了），可以再次生成
#
# 生成点会把自己登记进 "passenger_spawners" 组，供 PassengerManager 收集。
# ============================================================================

signal passenger_spawned(passenger: Passenger)

## 本生成点当前管理的那位乘客（未上车时有效）
var passenger: Passenger = null
## 是否已经生成了一个尚未上车的乘客；上车后置为 false
var spawned: bool = false

## 被 PassengerManager 注入的引用（生成点不自己找 manager）
var manager: PassengerManager = null


func _ready() -> void:
	add_to_group("passenger_spawners")


## 兜底：若未被注入 manager，则按组查找场景里的 PassengerManager。
func _resolve_manager() -> PassengerManager:
	if manager != null:
		return manager
	var m := get_tree().get_first_node_in_group("passenger_manager")
	if m is PassengerManager:
		manager = m as PassengerManager
	return manager


## 工厂函数：生成一个乘客并配置好。已在生成状态则返回 null。
func spawn_passenger() -> Passenger:
	if spawned:
		return null
	var mgr := _resolve_manager()
	if mgr == null:
		return null

	var scene: PackedScene = mgr.get_passenger_scene()
	if scene == null:
		return null

	var p := scene.instantiate() as Passenger
	if p == null:
		return null

	# --- 由 factory 决定"会不会移动"与"目的地" ---
	p.is_moving = mgr.roll_moving()
	p.destination = mgr.pick_destination()

	# --- 放到生成点位置，并作为生成点的子节点（方便清场回收） ---
	p.global_position = global_position
	add_child(p)

	# --- 监听上车事件：一旦上车，生成点恢复可再次生成 ---
	p.boarded.connect(_on_passenger_boarded)
	p.tree_exited.connect(_on_passenger_exited)

	spawned = true
	passenger = p
	passenger_spawned.emit(p)
	return p


## 乘客被接走：把生成点释放，允许再次生成。
func _on_passenger_boarded() -> void:
	spawned = false
	# 此时乘客已被车上接管，不再由本生成点保存
	passenger = null


## 乘客从场景移除（销毁/送达后清理）：同样释放生成点。
func _on_passenger_exited() -> void:
	if passenger != null and not is_instance_valid(passenger):
		passenger = null
	if spawned and (passenger == null or not is_instance_valid(passenger)):
		spawned = false


## 供 PassengerManager.reset() 调用：清空本生成点状态，允许再次生成。
func reset_spawn_state() -> void:
	spawned = false
	if passenger != null and is_instance_valid(passenger) and passenger.get_parent() == self:
		passenger.free()
	passenger = null
