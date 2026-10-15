extends CharacterBody3D
class_name Passenger

# ============================================================================
# Passenger —— 乘客
#
# 被动实体：由 PassengerSpawner 的工厂函数生成本体并配置属性。
#   - destination：此乘客的目的地（送达点），可为 null（null 时仅原地等待/游走）
#   - is_moving  ：是否移动（决定它呆在原地还是在小范围内游走）
#   - wait_time  ：累计等待时长，供派单器做"等待优先级"
#   - claimed    ：是否已被某辆车认领（防撞单）
#
# 事件流：
#   生成 → is_waiting = true（等待被接走）
#   接走 → pick_up() 发出 boarded 信号，is_waiting = false，并从等待组中移除
#   送达 → drop_off() 发出 delivered 信号
#
# 物理（每帧 _physics_process 的顺序）：
#   1. _apply_gravity()                 —— 累加竖直向下的重力（本类自行处理，不依赖 RigidBody）
#   2. 行为决策：跟随出租车 > 随机游走 > 原地待机（只写速度的 **水平分量**）
#   3. align_ground_check_ray_to_velocity() —— 让地面检测射线的水平投影与速度的水平投影同向
#   4. has_ground_ahead()               —— 探不到地面就 _turn_away_from_edge() 随机换向
#   5. move_and_slide()                 —— 全帧只调用一次
# ============================================================================

signal boarded          ## 被出租车接走（上车）
signal delivered        ## 被送达目的地
signal despawned        ## 从场景中移除/销毁
## 走到了某辆车的上客点（此刻已向该车的 TaxiServiceComponent 发起上车请求）。
## 只作观测/调试用；真正的上车请求是直接调用组件方法（乘客事先不知道会遇到哪辆车，
## 没法在编辑器里预先连线），见 _follow_nearest_taxi()。
signal arrived_at_vehicle(vehicle: Node3D)

## 目的地节点（送达点）。若不设置，则 passenger 只等待/游走，不产生送达目标。
#expose
@export var destination: Marker3D = null
## 是否移动：false = 原地等待；true = 在 wander_radius 范围内随机游走
@export var is_moving: bool = false
## 前方地面检测射线。其与当前速度方向二者的在水平方向上的投影平行
@export var ground_check_ray:RayCast3D
## 游走范围（米）
@export_range(0.0, 30.0) var wander_radius: float = 6.0
## 游走速度（米/秒）
@export_range(0.0, 10.0) var move_speed: float = 1.2
## 跟车上客时的停步距离（米）：走到离"上客点"这么近就站住等车停稳。
## 必须小于车侧 TaxiServiceComponent.board_accept_radius，否则会"到了却不发请求"。
@export_range(0.1, 3.0) var board_stop_distance: float = 0.6
## 竖直向下的重力加速度（米/秒²）。默认取项目设置 physics/3d/default_gravity。
@export var gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
## 下落速度上限（米/秒）：从高处掉下去时限制速度，避免单帧位移过大而穿模。
@export_range(1.0, 100.0) var max_fall_speed: float = 25.0

# ---------------------------------------------------------------------------
# 碰撞层配置
# ---------------------------------------------------------------------------
## 乘客层（项目设置 3d_physics/layer_3 = "乘客"），位掩码 1 << 2
const PASSENGER_LAYER: int = 1 << 2
## 不检测层（项目设置 3d_physics/layer_15 = "不检测层"），位掩码 1 << 14
## 上车后 / 入池后把碰撞层挪到这里，等于"退出一切碰撞检测"。
## 之所以用换层而不是直接禁用碰撞：RigidBody3D/CharacterBody3D 的根节点在移动中
## 不能禁用碰撞（Godot 会报错），而换层对所有查询都是等效的。
const NO_DETECT_LAYER: int = 1 << 14
## 等待状态下乘客要检测的世界层（地面 + 墙壁 = 层1|层2）
const PASSENGER_MASK: int = (1 << 0) | (1 << 1)

## 是否仍在等待被接走（true = 还没上车）
var is_waiting: bool = true
## 是否已被某辆车认领（派单防撞单）
var claimed: bool = false
## 认领该乘客的车
var claimed_by: Node = null
## 实际接走本乘客的车（接送逻辑设置；用于判断"被敌人抢客"）
var picked_by: Node3D = null
## 实际接走本乘客的车所属公司编号（同 company_id 为队友，不同为敌人）
var picked_by_company: int = -1

## 生成时刻（秒）
var spawn_time: float = 0.0
## 累计等待时长（秒），派单器据此提升优先级
var wait_time: float = 0.0

var _wander_target: Vector3 = Vector3.ZERO
var _wander_timer: float = 0.0
## 游走锚点 = 本回合的出生点。游走目标以它为圆心取随机点，
## 否则"以当前位置为圆心"的随机游走会随时间越漂越远，直接走出 wander_radius。
var _wander_anchor: Vector3 = Vector3.ZERO

## ground_check_ray 在场景里 authored 的基准姿态。每帧的对齐都以它为基准重算，
## 而不是在上一次的结果上继续旋转，因此倾角/自转不会随时间累积误差。
var _ray_rest_transform: Transform3D = Transform3D.IDENTITY
## 基准姿态下，射线方向在本体局部空间中的单位向量（竖直向下 + 倾角）。
var _ray_rest_dir: Vector3 = Vector3.DOWN
## 射线的倾角（弧度）：基准方向与 Vector3.DOWN 的夹角；对齐时保持它不变。
var _ray_tilt: float = 0.0
## 基准姿态是否已成功缓存
var _ray_rest_ready: bool = false
## 缓存对应的射线节点：若运行时换了另一根射线，则重新缓存基准。
var _ray_rest_node: RayCast3D = null

## 当前进入跟随范围（WaitingArea）的出租车列表。
## 由 _on_taxi_enter_follow_range/_on_taxi_exit_follow_range 维护。
var _taxis_in_range: Array = []

## 当前正在靠近的目标出租车；null 表示未处于跟随模式。
var _approach_target: Node3D = null

## 已经走到其"上客点"的那辆车（用于 arrived_at_vehicle 只在刚到达时发一次）。
var _arrived_vehicle: Node3D = null

## 车辆 -> TaxiServiceComponent 的缓存。值为 null 表示"查过，这辆车没挂业务组件"。
## 跟随判定每帧都要用，不能每帧递归找子树。
var _service_cache: Dictionary = {}

## 当前被临时取消碰撞的车辆：乘客是去上车的，不该用身体去推车。
var _no_push_body: Node = null

## 水平方向的最小有效长度（平方）：小于它视作"没有方向"，不做对齐/换向。
const _MIN_DIR_SQ: float = 0.000001


func _ready() -> void:
	spawn_time = Time.get_ticks_msec() / 1000.0
	_wander_target = global_position
	_wander_anchor = global_position
	add_to_group("waiting_passengers")
	_cache_ground_ray_rest()


func _physics_process(delta: float) -> void:
	if not is_waiting:
		return
	wait_time += delta

	# 1) 重力：只写速度的竖直分量。
	_apply_gravity(delta)

	# 2) 行为决策：跟随出租车 > 随机游走 > 原地待机。
	#    这些分支只写速度的 **水平分量**，不会把上面累加的重力冲掉。
	var following: bool = _follow_nearest_taxi()
	if not following:
		if is_moving:
			_wander(delta)
		else:
			_stop_horizontal()

	# 3) 地面预检：先把射线摆到前进方向上，再探地面。
	#    跟随出租车时不打断（否则会一边跟车一边乱走）。
	if not following and is_moving:
		align_ground_check_ray_to_velocity()
		if not has_ground_ahead():
			# 前方探不到地面（悬崖/断口）：立刻随机换向……
			_turn_away_from_edge()
			# ……换完再对齐一次，保证"射线指向 = 新的前进方向"。
			align_ground_check_ray_to_velocity()

	# 4) 唯一一次实际位移。
	move_and_slide()


# ----------------------------------------------------------------------------
# 重力
# ----------------------------------------------------------------------------

## 累加竖直向下的重力。落地时把向下的速度清零，避免贴地时速度不断累积。
func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = 0.0
		return
	velocity.y = maxf(velocity.y - gravity * delta, -max_fall_speed)


## 只停水平分量，保留竖直分量（否则会把下落速度清掉，人就会飘在空中）。
func _stop_horizontal() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


# ----------------------------------------------------------------------------
# 随机游走 / 跟随出租车（都只负责"决定水平速度"，位移统一在 _physics_process 里做）
# ----------------------------------------------------------------------------

func _wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(2.0, 5.0)
		# 以出生点（锚点）为圆心取随机目标，保证始终待在 wander_radius 范围内。
		_wander_target = _wander_anchor \
			+ Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * wander_radius
	var to: Vector3 = _wander_target - global_position
	to.y = 0.0
	if to.length() > 0.5:
		var dir: Vector3 = to.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		_stop_horizontal()


## 射线探不到地面（前方是悬崖/断口）时的随机换向：
## 以"来路方向"为基准随机偏转一个角度，保证不会继续朝悬空方向走；
## 若已经漂出 wander_radius，则直接改朝出生点（锚点）走。
func _turn_away_from_edge() -> void:
	var new_dir: Vector3
	var to_anchor: Vector3 = _wander_anchor - global_position
	to_anchor.y = 0.0
	if to_anchor.length() > wander_radius:
		new_dir = to_anchor.normalized()
	else:
		# 折返方向 = 当前速度水平分量的反向，让乘客先离开悬空处。
		new_dir = Vector3(-velocity.x, 0.0, -velocity.z)
		if new_dir.length_squared() < _MIN_DIR_SQ:
			new_dir = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
			if new_dir.length_squared() < _MIN_DIR_SQ:
				new_dir = Vector3.FORWARD
		# 在折返方向上再随机偏转 ±72°：既离开悬空处，又保留"随机游走"的随机性。
		new_dir = new_dir.normalized().rotated(Vector3.UP, randf_range(-PI * 0.4, PI * 0.4))

	_wander_target = global_position + new_dir * wander_radius
	_wander_timer = randf_range(1.0, 3.0)
	velocity.x = new_dir.x * move_speed
	velocity.z = new_dir.z * move_speed


# --- 跟随出租车（等待范围内） ---

## 移除列表里已销毁/失效的出租车引用，避免残留失效节点。
func _prune_dead_taxis() -> void:
	for i in range(_taxis_in_range.size() - 1, -1, -1):
		if not is_instance_valid(_taxis_in_range[i]):
			_taxis_in_range.remove_at(i)
	# 组件缓存同样要清掉已失效的车，否则键会越积越多
	for car in _service_cache.keys():
		if not is_instance_valid(car):
			_service_cache.erase(car)


## 取某辆车上的接送业务组件（带缓存；null = 这辆车没挂组件）。
func _get_service_of(car: Node3D) -> TaxiServiceComponent:
	if car == null or not is_instance_valid(car):
		return null
	if _service_cache.has(car):
		var cached: Variant = _service_cache[car]
		if cached == null or is_instance_valid(cached):
			return cached as TaxiServiceComponent
		_service_cache.erase(car)
	var svc := TaxiServiceComponent.find_for(car)
	_service_cache[car] = svc
	return svc


## 朝某个世界坐标走：距离大于 stop_distance 就按 move_speed 靠近，否则站住。
## 返回**走动前**的水平距离（米），供调用方判断"到了没"。
func _walk_towards(point: Vector3, stop_distance: float) -> float:
	var to: Vector3 = point - global_position
	to.y = 0.0
	var dist: float = to.length()
	if dist > stop_distance:
		var dir: Vector3 = to.normalized()
		velocity.x = dir.x * move_speed
		velocity.z = dir.z * move_speed
	else:
		_stop_horizontal()
	return dist


## 临时取消与某辆车的碰撞（跟随/上客期间）。
func _set_no_push(car: Node) -> void:
	if _no_push_body == car:
		return
	_clear_no_push()
	if car != null and is_instance_valid(car):
		add_collision_exception_with(car)
		_no_push_body = car


func _clear_no_push() -> void:
	if _no_push_body != null and is_instance_valid(_no_push_body):
		remove_collision_exception_with(_no_push_body)
	_no_push_body = null


## 清掉全部碰撞例外（上车 / 入池 / 复活时用，避免把上一段的例外带到下一段）。
func _clear_all_collision_exceptions() -> void:
	for b in get_collision_exceptions():
		if b != null and is_instance_valid(b):
			remove_collision_exception_with(b)
	_no_push_body = null


## 朝向范围内最近的出租车移动（只设置水平速度，位移由 _physics_process 统一执行）。
## 返回 true 表示当前处于跟随状态。
##
## 两种情况：
##   1. 该车挂了 TaxiServiceComponent —— 走向它的**上客点**（车侧车门附近），
##      到了就调用组件的 request_pickup() 请求上车；车没停稳时会被拒绝，
##      乘客就站在车门边继续请求，直到车停稳为止。这是"乘客主动上车"那条链路。
##   2. 该车没挂组件 —— 保持旧的"朝车走"行为（这种车本来也没有上车流程）。
##
## 跟随期间会临时取消与目标车的碰撞：否则乘客是用身体去挤车（把车推走、
## 自己也永远到不了目标点），而不是走到车门边等上车。
##
## 若范围内没有有效的出租车，则清理列表并把 _approach_target 置空，返回 false，
## 由调用方回退到游走（is_moving）或原地待机。
func _follow_nearest_taxi() -> bool:
	_prune_dead_taxis()
	if _taxis_in_range.is_empty():
		_approach_target = null
		_clear_no_push()
		_arrived_vehicle = null
		return false

	var nearest: Node3D = _taxis_in_range[0]
	var nearest_dist: float = global_position.distance_to(nearest.global_position)
	for t in _taxis_in_range:
		var d: float = global_position.distance_to(t.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = t
	_approach_target = nearest

	var svc := _get_service_of(nearest)
	if svc == null:
		# 没挂业务组件的车：保持旧的"朝车走"行为
		_clear_no_push()
		_arrived_vehicle = null
		_walk_towards(nearest.global_position, 0.5)
		return true

	_set_no_push(nearest)

	var dist: float = _walk_towards(svc.get_board_position(), board_stop_distance)

	if dist <= svc.board_accept_radius:
		# 到车边 → 通知车侧接客（车没停稳时会被拒绝，下一帧继续请求）
		if _arrived_vehicle != nearest:
			_arrived_vehicle = nearest
			arrived_at_vehicle.emit(nearest)
		svc.request_pickup(self)
	else:
		_arrived_vehicle = null
	return true


# ----------------------------------------------------------------------------
# ground_check 射线：方向对齐 + 地面预检
# ----------------------------------------------------------------------------

## 缓存 ground_check_ray 在场景里 authored 的基准姿态、基准方向与倾角。
## 只会真正缓存一次（除非运行时换了另一根射线）：绝不能拿"对齐后的姿态"当基准，
## 否则倾角会在每帧的旋转里一点点漂掉。
func _cache_ground_ray_rest() -> void:
	if ground_check_ray == null or not is_instance_valid(ground_check_ray):
		_ray_rest_ready = false
		_ray_rest_node = null
		return
	if _ray_rest_ready and _ray_rest_node == ground_check_ray:
		return

	_ray_rest_ready = false
	var rest: Transform3D = ground_check_ray.transform
	var ray_dir_local: Vector3 = ground_check_ray.target_position
	if ray_dir_local.length_squared() < _MIN_DIR_SQ:
		return
	# 射线在本体局部空间中的方向 = 基准基向量 × 局部射线方向（target_position 的朝向）。
	var dir: Vector3 = (rest.basis * ray_dir_local.normalized()).normalized()
	if dir.length_squared() < _MIN_DIR_SQ:
		return

	_ray_rest_transform = rest
	_ray_rest_dir = dir
	_ray_tilt = dir.angle_to(Vector3.DOWN)
	_ray_rest_node = ground_check_ray
	_ray_rest_ready = true


## 把射线复位到场景里的基准姿态（池化复用时调用，避免带着上一次的朝向复活）。
func _reset_ground_ray() -> void:
	_cache_ground_ray_rest()
	if _ray_rest_ready:
		ground_check_ray.transform = _ray_rest_transform


## 把 ground_check_ray 绕本体的竖直轴旋转，使其方向在水平面上的投影，
## 与速度（或传入方向）在水平面上的投影同向。效果：
##   - 射线方向与速度向量始终共面于同一个竖直平面；
##   - 射线相对竖直向下的倾角 = 场景里 authored 的倾角，始终不变（只绕竖直轴转）。
##
## horizontal_dir 传 Vector3.ZERO（默认）时使用当前 velocity；传入的方向会被压平到水平面。
## 返回 true 表示已对齐；返回 false 表示没有可对齐的方向
## （水平速度为 0、未配置射线、射线方向无效），此时保持原朝向不动。
func align_ground_check_ray_to_velocity(horizontal_dir: Vector3 = Vector3.ZERO) -> bool:
	if ground_check_ray == null or not is_instance_valid(ground_check_ray):
		return false
	if not _ray_rest_ready or _ray_rest_node != ground_check_ray:
		_cache_ground_ray_rest()
		if not _ray_rest_ready:
			return false

	# 1) 取水平方向：优先用调用方给的方向，否则用当前速度；两者都压平到水平面。
	var flat: Vector3 = horizontal_dir
	if flat.length_squared() < _MIN_DIR_SQ:
		flat = velocity
	flat.y = 0.0
	if flat.length_squared() < _MIN_DIR_SQ:
		# 水平速度为 0：没有"前进方向"可言，保持现状，避免原地来回抽搐。
		return false

	# 2) 换算到本体局部空间（射线是本体子节点，是绕着本体的竖直轴转的）。
	var flat_local: Vector3 = global_transform.basis.inverse() * flat
	flat_local.y = 0.0
	if flat_local.length_squared() < _MIN_DIR_SQ:
		return false
	flat_local = flat_local.normalized()

	# 3) 目标方向：倾角不变，只把水平投影摆到 flat_local 上。
	#    d = cos(倾角)·竖直向下 + sin(倾角)·水平方向，这样 d 与 DOWN 的夹角恒为倾角。
	var target_dir: Vector3 = (Vector3.DOWN * cos(_ray_tilt) + flat_local * sin(_ray_tilt)).normalized()

	# 4) 用"基准方向 → 目标方向"的最小旋转去旋转基准姿态。
	#    最小旋转不引入额外的自转（roll），也严格保持上面算好的倾角。
	var q := Quaternion(_ray_rest_dir, target_dir)
	ground_check_ray.transform = Transform3D(Basis(q) * _ray_rest_transform.basis, _ray_rest_transform.origin)
	return true


## 用 ground_check_ray 朝"当前前进方向"探一次地面：命中返回 true。
## 未配置射线时返回 true（fail-open：不能因为没挂射线就让乘客原地不动）。
## 调用前请先用 align_ground_check_ray_to_velocity() 把射线摆到前进方向上。
func has_ground_ahead() -> bool:
	if ground_check_ray == null or not is_instance_valid(ground_check_ray):
		return true
	ground_check_ray.force_raycast_update()
	return ground_check_ray.is_colliding()


## 被出租车接走（上车）。发出 boarded 信号，停止等待与游走。
## 出租车侧负责把本节点重新父级到车上。
func pick_up() -> void:
	if not is_waiting:
		return
	is_waiting = false
	remove_from_group("waiting_passengers")
	boarded.emit()


## 切换「车上态」：隐藏自己 + 把碰撞层挪到不检测层 + 停掉物理。
##
## 上车后乘客只是挂在车节点下跟随，**不需要可见**，也不应参与任何碰撞/射线检测：
##   - `visible = false`：不再渲染
##   - `collision_layer = 不检测层`、`collision_mask = 0`：退出一切碰撞与射线查询
##   - WaitingArea 停止检测：否则仍会把路过的出租车记进 `_taxis_in_range`
##
## 另外必须停掉 `_physics_process`：接送流程里 `pick_up()` 先于重新挂父级执行，
## 而这个节点当帧的 `_physics_process` 还没跑（其中第 139 行是无条件
## `move_and_slide()`）。如果不停，乘客会在"已挂到车上、但还是旧碰撞层"的那一帧
## 被物理引擎按旧层再推一次位置。停掉最稳，也省掉每帧一次无意义的物理步进。
##
## 与 `_set_pooled()` 是同一套状态（车上 == 池中，都是"惰性不可见"），
## 所以这里直接复用。
func set_carried(carried: bool) -> void:
	_set_pooled(carried)
	set_physics_process(not carried)


## 上车落座：重新父级到所乘车辆、摆到坐席位，并切到"车上态"
## （隐藏 + 碰撞层挪到不检测层 + 停物理，见 set_carried）。
##
## 由 PassengerManager（有管理器时，在 boarded 回调里）与
## TaxiServiceComponent（没有管理器时兜底）共同调用，保证两条路径落座方式一致。
func board_into(target_vehicle: Node3D, seat_offset: Vector3) -> void:
	if target_vehicle == null or not is_instance_valid(target_vehicle):
		return
	var prev := get_parent()
	if prev != null and prev != target_vehicle:
		prev.remove_child(self)
	if get_parent() != target_vehicle:
		target_vehicle.add_child(self)
	position = seat_offset
	rotation = Vector3.ZERO
	set_carried(true)


## 送达目的地。发出 delivered 信号。
func drop_off() -> void:
	delivered.emit()


## 到目的地的距离；无目的地时返回 0。
func distance_to_destination() -> float:
	if destination == null or not is_instance_valid(destination):
		return 0.0
	return global_position.distance_to(destination.global_position)


func _on_taxi_enter_follow_range(body: Node3D) -> void:
	# 仅对出租车（第 5 层 / MMTVehicleBody）响应。
	if body is MMTVehicleBody:
		if not _taxis_in_range.has(body):
			_taxis_in_range.append(body)
		# 停止游走并靠近最近的出租车：该逻辑在 _physics_process 里由
		# _follow_nearest_taxi 统一处理（每帧重新选择最近的出租车）。


func _on_taxi_exit_follow_range(body: Node3D) -> void:
	if body is MMTVehicleBody:
		_taxis_in_range.erase(body)
		# 离开范围的车：清掉它的组件缓存与临时碰撞例外
		if _service_cache.has(body):
			_service_cache.erase(body)
		if _no_push_body == body:
			_clear_no_push()
		if _arrived_vehicle == body:
			_arrived_vehicle = null
		# 若范围内已没有出租车，立即清空跟随目标，
		# 下一帧 _physics_process 会回退到游走或原地待机。
		if _taxis_in_range.is_empty():
			_approach_target = null


# ----------------------------------------------------------------------------
# 对象池生命周期（由 PassengerManager 调用）
#
# 乘客不再 queue_free，而是被回收进池、下次复用。原因：
#   - 送达/回合重置时反复 instantiate + free 会持续分配/释放节点；
#   - 复用实例必须把上一次的状态（等待标记、认领、跟随列表、碰撞）全部复位，
#     否则会把上一回合的 destination/picked_by 带进下一回合。
# ----------------------------------------------------------------------------

## 从池中取出、作为"等待中"的乘客复活：恢复可见、物理与全部状态。
func activate_as_waiting() -> void:
	is_waiting = true
	claimed = false
	claimed_by = null
	picked_by = null
	picked_by_company = -1
	spawn_time = Time.get_ticks_msec() / 1000.0
	wait_time = 0.0
	_wander_target = global_position
	_wander_timer = 0.0
	_wander_anchor = global_position
	_taxis_in_range.clear()
	_approach_target = null
	velocity = Vector3.ZERO
	rotation = Vector3.ZERO
	_reset_ground_ray()
	if not is_in_group("waiting_passengers"):
		add_to_group("waiting_passengers")
	_set_pooled(false)
	set_physics_process(true)


## 回收入池：停止一切行为并隐藏（不销毁，供下次复用）。
#expose
func deactivate_for_pool() -> void:
	is_waiting = false
	if is_in_group("waiting_passengers"):
		remove_from_group("waiting_passengers")
	claimed = false
	claimed_by = null
	picked_by = null
	picked_by_company = -1
	wait_time = 0.0
	_taxis_in_range.clear()
	_approach_target = null
	velocity = Vector3.ZERO
	destination = null
	_set_pooled(true)
	set_physics_process(false)


## 统一开关"能参与世界交互"的部件：自身可见性 + 碰撞层 + 碰撞形状 + WaitingArea 的检测。
##
## 池中的乘客必须完全惰性：
##   - 不可见（藏起来）
##   - 碰撞层挪到「不检测层」（Layer 15），这样不会被射线/车身/其它乘客碰到
##   - WaitingArea 停止检测，否则它仍会把路过的出租车记进 _taxis_in_range
##
## 这个函数是**唯一**的可见性/碰撞开关，`activate_as_waiting()` 与
## `deactivate_for_pool()` 都通过它切换，避免两处状态不一致。
func _set_pooled(pooled: bool) -> void:
	# 1) 可见性
	visible = not pooled

	# 2) 根节点碰撞层：在「乘客层(3)」与「不检测层(15)」之间切换
	collision_layer = NO_DETECT_LAYER if pooled else PASSENGER_LAYER
	collision_mask = 0 if pooled else PASSENGER_MASK

	# 3) 子部件：碰撞形状 + Area3D 检测
	for child in get_children():
		if child is CollisionShape3D:
			(child as CollisionShape3D).disabled = pooled
		elif child is Area3D:
			var area := child as Area3D
			area.monitoring = not pooled
			area.monitorable = not pooled
			# Area3D 自身也挪到不检测层：即便还有 body_entered 连接，
			# 层不匹配就不会再触发（_taxis_in_range 不会被污染）
			area.collision_layer = NO_DETECT_LAYER if pooled else PASSENGER_LAYER
			for sub in area.get_children():
				if sub is CollisionShape3D:
					(sub as CollisionShape3D).disabled = pooled

	# 4) 惰性状态下清空"范围内的出租车"记录。
	# 检测关掉后不会再收到 body_exited，残留引用会一直留着；
	# 上车/入池期间也绝不该继续跟随任何出租车。
	if pooled:
		_taxis_in_range.clear()
		_service_cache.clear()
		_approach_target = null
		_arrived_vehicle = null
		_clear_all_collision_exceptions()
