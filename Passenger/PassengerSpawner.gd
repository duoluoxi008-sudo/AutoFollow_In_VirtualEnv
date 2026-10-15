extends Marker3D
class_name PassengerSpawner

# ============================================================================
# PassengerSpawner —— 乘客生成点
#
# 工厂函数 spawn_passenger():
#   - 调用 manager 拿到乘客场景、随机目的地、是否移动等配置
#   - 从 PassengerManager 的对象池里领取实例（池空才新建），放到生成点位置并激活
#   - 把 spawned 置为 true（表示"本点有人"），并把占用登记回 manager
#
# 生命周期信号（boarded / tree_exited）由 PassengerManager 在每个实例创建时
# 只连接一次——池化复用时不会再接，避免重复触发。
#
# spawned 语义（按需求）：
#   - true  = 本生成点当前"有人"：那位乘客要么还在等待，要么已被接走但**行程没结束**。
#             上车**不**释放生成点，否则刚接走人就会在原地（往往就在接客的车旁边）
#             刷出下一个乘客。
#   - false = 还没生成，或者本点那位乘客的行程已结束（送达 / 被回收入池），
#             可以再次生成。释放动作在 PassengerManager.recycle_passenger() 里做。
#
# 生成点会把自己登记进 "passenger_spawners" 组（历史遗留的全局分组标记，
# 收集逻辑已改为"由 PassengerManager 在自己的 spawner_root 下 get_children()"，
# 不再依赖这个组）。
# ============================================================================

signal passenger_spawned(passenger: Passenger)

## 本生成点当前管理的那位乘客（未上车时有效）
var passenger: Passenger = null
## 本生成点当前是否"有人"（等待中，或已被接走但行程未结束）。
## 由 PassengerManager 在生成时置 true、在送达/回收（_release_holder）时置 false。
var spawned: bool = false

## 被 PassengerManager 注入的引用（生成点不自己找 manager）
var manager: PassengerManager = null


func _ready() -> void:
	add_to_group("passenger_spawners")


## 兜底：若未被注入 manager，则沿祖先找一个"直接挂着 PassengerManager"的节点。
##
## 正常情况下 manager 会在 `_collect()` 里把引用注入进来（见 PassengerManager），
## 这个兜底只服务于"生成点没被收集到"的边缘情况。
## 故意**不用全局组**：多 arena 同进程时全局组会拿到别的场地的管理器。
func _resolve_manager() -> PassengerManager:
	if manager != null:
		return manager
	var n: Node = get_parent()
	while n != null:
		for c in n.get_children():
			if c is PassengerManager and is_instance_valid(c):
				manager = c as PassengerManager
				return manager
		n = n.get_parent()
	return manager


## 工厂函数：生成（或从对象池复用一个）乘客并配置好。已在生成状态则返回 null。
func spawn_passenger() -> Passenger:
	if spawned:
		return null
	var mgr := _resolve_manager()
	if mgr == null:
		return null

	# 池优先：回收过的实例直接复用，池空才新建（信号接线在 manager 里只做一次）。
	var p := mgr.acquire_passenger()
	if p == null:
		return null

	# --- 由 factory 决定"会不会移动"与"目的地" ---
	p.is_moving = mgr.roll_moving()
	p.destination = mgr.pick_destination()

	# --- 放到生成点位置，并作为生成点的子节点（方便清场回收） ---
	# ⚠️ 复用池里的实例时它当前挂在 PassengerManager 下，而 add_child() **不会**自动改父级：
	# 直接 add_child 会报 "Can't add child ... already has a parent"，且乘客会留在原地
	# （表现为"生成点逻辑上有乘客，但人站在世界原点"）。所以先摘下来再挂。
	var old_parent := p.get_parent()
	if old_parent != null and old_parent != self:
		old_parent.remove_child(p)
	p.position = Vector3.ZERO
	add_child(p)

	# 复用池里的实例时，这里恢复可见/物理/碰撞并复位内部状态。
	p.activate_as_waiting()

	# 登记生成点占用 + 计入名额。
	mgr.attach_to_spawner(p, self)

	spawned = true
	passenger = p
	passenger_spawned.emit(p)
	return p


## 供 PassengerManager.reset() 调用：清空本生成点的占用记录（乘客本体由池回收）。
func reset_spawn_state() -> void:
	spawned = false
	passenger = null
