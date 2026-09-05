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
# ============================================================================

signal boarded          ## 被出租车接走（上车）
signal delivered        ## 被送达目的地
signal despawned        ## 从场景中移除/销毁

## 目的地节点（送达点）。若不设置，则 passenger 只等待/游走，不产生送达目标。
@export var destination: Node3D = null
## 是否移动：false = 原地等待；true = 在 wander_radius 范围内随机游走
@export var is_moving: bool = false
## 游走范围（米）
@export_range(0.0, 30.0) var wander_radius: float = 6.0
## 游走速度（米/秒）
@export_range(0.0, 10.0) var move_speed: float = 1.2

## 是否仍在等待被接走（true = 还没上车）
var is_waiting: bool = true
## 是否已被某辆车认领（派单防撞单）
var claimed: bool = false
## 认领该乘客的车
var claimed_by: Node = null

## 生成时刻（秒）
var spawn_time: float = 0.0
## 累计等待时长（秒），派单器据此提升优先级
var wait_time: float = 0.0

var _wander_target: Vector3 = Vector3.ZERO
var _wander_timer: float = 0.0


func _ready() -> void:
	spawn_time = Time.get_ticks_msec() / 1000.0
	_wander_target = global_position
	add_to_group("waiting_passengers")


func _physics_process(delta: float) -> void:
	if not is_waiting:
		return
	wait_time += delta
	if is_moving:
		_wander(delta)


func _wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_timer = randf_range(2.0, 5.0)
		_wander_target = global_position \
			+ Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * wander_radius
	var to: Vector3 = _wander_target - global_position
	to.y = 0.0
	if to.length() > 0.5:
		velocity = to.normalized() * move_speed
		move_and_slide()
	else:
		velocity = Vector3.ZERO


## 被出租车接走（上车）。发出 boarded 信号，停止等待与游走。
## 出租车侧负责把本节点重新父级到车上。
func pick_up() -> void:
	if not is_waiting:
		return
	is_waiting = false
	remove_from_group("waiting_passengers")
	boarded.emit()


## 送达目的地。发出 delivered 信号。
func drop_off() -> void:
	delivered.emit()


## 到目的地的距离；无目的地时返回 0。
func distance_to_destination() -> float:
	if destination == null or not is_instance_valid(destination):
		return 0.0
	return global_position.distance_to(destination.global_position)
