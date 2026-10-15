extends Node
class_name SensorManager

var raycast_sensor:Array[RayCastSensor3D] = []
var position_sensor:Array[PositionSensor3D] = []
var rgb_sensor:Array[RGBCameraSensor3D] = []
var grid_sensor:Array[GridSensor3D] = []

@export var raycast_type:Node = null
@export var position_type:Node = null
@export var rgb_type:Node = null
@export var grid_type:Node = null




func _ready() -> void:
	_collect_sensor_children()

## 遍历子节点，把对应类型的传感器收集到各自的数组里。
## （RGBCameraSensor3D 继承 Node3D；其余三种继承 ISensor3D，彼此互不重叠。）
func _collect_sensor_children() -> void:
	raycast_sensor.clear()
	position_sensor.clear()
	rgb_sensor.clear()
	grid_sensor.clear()
	_init_sensor_arr(raycast_type,raycast_sensor)
	_init_sensor_arr(position_type,position_sensor)
	_init_sensor_arr(rgb_type,rgb_sensor)
	_init_sensor_arr(grid_type,grid_sensor)
	
func _init_sensor_arr(sensor_type:Node,sensor_arr:Array):
	if sensor_type:
		for child in sensor_type.get_children():
			sensor_arr.append(child)

# ============================================================================
# 射线传感器（RayCastSensor3D）
# 每个传感器的 get_observation() 返回一个数组，
# 其中偶数位为归一化距离，若开启 class_sensor 则紧随后的奇数位为击中类别。
# ============================================================================

## 拼接全部射线传感器的观测值（用于扩充观测向量）
	#射线传感器,查找周边物体，每个射线传感器返回的result数组为格式为第i根射线 result[i] = 距离 result[i+1] = 击中的碰撞层 这样交替而成
#expose
func get_raycast_observations() -> Array:
	var result:Array = []
	for sensor in raycast_sensor:
		if is_instance_valid(sensor):
			for o in sensor.get_observation():
				result.append(float(o))
	return result

## 返回指定索引射线传感器的观测值
func get_raycast_observation(index: int) -> Array:
	if index < 0 or index >= raycast_sensor.size():
		return []
	var sensor := raycast_sensor[index]
	if not is_instance_valid(sensor):
		return []
	return sensor.get_observation()

## 返回全部射线传感器各自的观测值（外层数组索引对应 raycast_sensor 数组）
func get_raycast_observations_separated() -> Array:
	var result:Array = []
	for sensor in raycast_sensor:
		if is_instance_valid(sensor):
			result.append(sensor.get_observation())
		else:
			result.append([])
	return result

# ============================================================================
# 位置传感器（PositionSensor3D，含 PassengerPositionSensor3D）
# 每个传感器的 get_observation() 返回一个 Array[float]，
# 内容为对每个观测对象的归一化相对位置（可含方向 + 距离）。
# ============================================================================

## 拼接全部位置传感器的观测值
#expose
func get_position_observations() -> Array[float]:
	var result:Array[float] = []
	for sensor in position_sensor:
		if is_instance_valid(sensor):
			for o in sensor.get_observation():
				result.append(float(o))
	return result

## 返回指定索引位置传感器的观测值
func get_position_observation(index: int) -> Array[float]:
	if index < 0 or index >= position_sensor.size():
		return []
	var sensor := position_sensor[index]
	if not is_instance_valid(sensor):
		return []
	return sensor.get_observation()

## 返回全部位置传感器各自的观测值
func get_position_observations_separated() -> Array:
	var result:Array = []
	for sensor in position_sensor:
		if is_instance_valid(sensor):
			result.append(sensor.get_observation())
		else:
			result.append([])
	return result

# ============================================================================
# RGB 相机传感器（RGBCameraSensor3D）
# 该类继承 Node3D，不提供 get_observation()，而是提供像素编码与形状。
#   get_camera_pixel_encoding() -> String  返回 hex 编码的像素数据
#   get_camera_shape()         -> Array    返回 [通道数, 高, 宽]
# ============================================================================

## 返回全部 RGB 传感器的像素 hex 编码（用于观测图像数据）
func get_rgb_observations() -> Array:
	var result:Array = []
	for sensor in rgb_sensor:
		if is_instance_valid(sensor):
			result.append(sensor.get_camera_pixel_encoding())
		else:
			result.append("")
	return result

## 返回指定索引 RGB 传感器的像素 hex 编码
func get_rgb_observation(index: int) -> String:
	if index < 0 or index >= rgb_sensor.size():
		return ""
	var sensor := rgb_sensor[index]
	if not is_instance_valid(sensor):
		return ""
	return sensor.get_camera_pixel_encoding()

## 返回全部 RGB 传感器的图像形状 [通道数, 高, 宽]
func get_rgb_shapes() -> Array:
	var result:Array = []
	for sensor in rgb_sensor:
		if is_instance_valid(sensor):
			result.append(sensor.get_camera_shape())
		else:
			result.append([])
	return result

## 返回指定索引 RGB 传感器的图像形状 [通道数, 高, 宽]
func get_rgb_shape(index: int) -> Array:
	if index < 0 or index >= rgb_sensor.size():
		return []
	var sensor := rgb_sensor[index]
	if not is_instance_valid(sensor):
		return []
	return sensor.get_camera_shape()

# ============================================================================
# 网格传感器（GridSensor3D）
# 每个传感器的 get_observation() 返回一个 PackedFloat64Array，
# 内容为 grid_size_x * grid_size_z * 层数 的命中计数。
# ============================================================================

## 拼接全部网格传感器的观测值
func get_grid_observations() -> PackedFloat64Array:
	var result := PackedFloat64Array()
	for sensor in grid_sensor:
		if is_instance_valid(sensor):
			result.append_array(sensor.get_observation())
	return result

## 返回指定索引网格传感器的观测值
func get_grid_observation(index: int) -> PackedFloat64Array:
	if index < 0 or index >= grid_sensor.size():
		return PackedFloat64Array()
	var sensor := grid_sensor[index]
	if not is_instance_valid(sensor):
		return PackedFloat64Array()
	return sensor.get_observation()

## 返回全部网格传感器各自的观测值
func get_grid_observations_separated() -> Array:
	var result:Array = []
	for sensor in grid_sensor:
		if is_instance_valid(sensor):
			result.append(sensor.get_observation())
		else:
			result.append(PackedFloat64Array())
	return result
