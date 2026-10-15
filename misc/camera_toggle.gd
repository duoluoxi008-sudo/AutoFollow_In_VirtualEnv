extends Node
class_name CameraToggle

# ============================================================================
# CameraToggle —— 自由相机 / 车辆相机 切换
#
# 在所有相机之间循环切换：
#   - 自由相机：场景根部的 FreeFlyCamera（自由飞行，可环视/飞行）。
#   - 车辆相机：每辆 AI 轿车内的 AIVehicleCam（子相机，随车移动）。
#
# 依据项目已有的输入动作：
#   - switch_form_cam_to_cam ：循环切换到下一台相机（自由 -> 车1 -> 车2 ... -> 自由）。
#   - switch_to_free_cam     ：强制回到自由相机。
#
# 车辆相机通过组 "AIVehicleCam" 查找，因此车辆是动态生成的也能正常工作。
# ============================================================================

## 自由相机节点（场景根部，脚本为 FreeFlyCamera）。留空则自动查找名为 "FreeFlyCamera" 的相机。
@export var free_cam: Camera3D
## 主切换动作：循环切换所有相机。
@export var toggle_vehicle_action: StringName = &"switch_form_cam_to_cam"
## 强制回到自由相机的动作。
@export var free_cam_action: StringName = &"switch_to_free_cam"
## 车辆相机所在的分组。
@export var vehicle_cam_group: StringName = &"AIVehicleCam"

# 当前是否处于车辆视角
var _using_vehicle_cam := false
# 缓存所有车辆相机
var _vehicle_cams: Array[Camera3D] = []


func _ready() -> void:
	if free_cam == null:
		free_cam = _find_free_cam()
	_refresh_vehicle_cams()


## 兜底查找自由相机：按节点名 "FreeFlyCamera" 优先，否则返回第一台非车辆相机。
func _find_free_cam() -> Camera3D:
	for n in get_tree().root.find_children("*", "Camera3D", true, false):
		if n is Camera3D and n.name == "FreeFlyCamera":
			return n as Camera3D
	for n in get_tree().root.find_children("*", "Camera3D", true, false):
		if n is Camera3D and not n.is_in_group(vehicle_cam_group):
			return n as Camera3D
	return null


## 从分组重新收集所有车辆相机（车辆会动态生成，因此每次切换前刷新）。
func _refresh_vehicle_cams() -> void:
	_vehicle_cams.clear()
	for n in get_tree().get_nodes_in_group(vehicle_cam_group):
		if n is Camera3D:
			_vehicle_cams.append(n as Camera3D)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(toggle_vehicle_action):
		_cycle_camera()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(free_cam_action):
		_activate_free_cam()
		get_viewport().set_input_as_handled()


## 循环切换到下一台相机。
func _cycle_camera() -> void:
	var cams := _all_cams()
	if cams.is_empty():
		return
	var cur := _current_cam()
	var idx := cams.find(cur)
	idx = (idx + 1) % cams.size()
	_activate_cam(cams[idx])


## 收集当前有效的全部相机：自由相机在最前，其后是所有车辆相机。
func _all_cams() -> Array[Camera3D]:
	var cams: Array[Camera3D] = []
	if is_instance_valid(free_cam):
		cams.append(free_cam)
	for vc in _vehicle_cams:
		if is_instance_valid(vc):
			cams.append(vc)
	return cams


## 返回当前处于活动状态（current==true）的相机。
func _current_cam() -> Camera3D:
	if is_instance_valid(free_cam) and free_cam.current:
		return free_cam
	for vc in _vehicle_cams:
		if is_instance_valid(vc) and vc.current:
			return vc
	return null


## 激活指定相机。
func _activate_cam(cam: Camera3D) -> void:
	if cam == null or not is_instance_valid(cam):
		return
	if cam == free_cam:
		_activate_free_cam()
		return

	# 关闭自由相机及其输入处理，避免它在后台仍接收飞行/视角输入。
	if is_instance_valid(free_cam):
		free_cam.current = false
		free_cam.set_process(false)
		free_cam.set_process_unhandled_input(false)

	# 只让目标车辆相机处于活动状态。
	for vc in _vehicle_cams:
		if is_instance_valid(vc):
			vc.current = (vc == cam)
	cam.current = true

	_using_vehicle_cam = true
	# 车辆视角为追随相机，不需要捕获鼠标来环视。
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## 切换到自由相机。
func _activate_free_cam() -> void:
	if free_cam == null:
		free_cam = _find_free_cam()
	if not is_instance_valid(free_cam):
		return

	free_cam.current = true
	# 重新启用自由相机的飞行与视角输入处理。
	free_cam.set_process(true)
	free_cam.set_process_unhandled_input(true)

	for vc in _vehicle_cams:
		if is_instance_valid(vc):
			vc.current = false

	_using_vehicle_cam = false
	# 自由飞行视角需要捕获鼠标来控制视角。
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
