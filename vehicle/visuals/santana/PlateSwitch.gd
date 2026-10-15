extends Node

# ============================================================================
# PlateSwitch —— 出租车顶牌外观
#
# "是否载客"这件事现在由 TaxiServiceComponent 负责，所以本节点也改为订阅组件信号，
# 这样 AI 车与玩家车都能用同一套接线。
#
# 接线优先级：
#   1. 检视器里显式指定的 taxi_service；
#   2. 自动从本节点向上找所属车辆上的 TaxiServiceComponent（推荐，留空即可）；
#   3. 都没有时保持场景里的初始外观，并保留旧的控制器信号回调（老场景连线仍然有效）。
# ============================================================================

@export var empty_car:Node3D
@export var full_car:Node3D
## 接送业务组件。留空则自动在本车子树里查找。
@export var taxi_service: TaxiServiceComponent


func _ready() -> void:
	if taxi_service == null or not is_instance_valid(taxi_service):
		taxi_service = TaxiServiceComponent.find_for(self)

	if taxi_service != null:
		if not taxi_service.carrying_changed.is_connected(_set_plate):
			taxi_service.carrying_changed.connect(_set_plate)
		_set_plate(taxi_service.has_passenger)
	else:
		# 没挂接送组件：保持"空车"外观，仍可由旧的控制器信号驱动
		_set_plate(false)


## 载客状态 → 顶牌外观（幂等，重复调用无害）
func _set_plate(has_passenger: bool) -> void:
	if empty_car != null:
		empty_car.visible = not has_passenger
	if full_car != null:
		full_car.visible = has_passenger


## 兼容旧场景连线：AITaxiController.change_taxi_plate_color
func _on_ai_taxi_controller_change_taxi_plate_color(has_passenger: bool) -> void:
	_set_plate(has_passenger)
