extends PositionSensor3D
class_name PassengerPositionSensor3D

# ============================================================================
# PassengerPositionSensor3D —— 乘客目标的 PositionSensor
#
# 感知"本车当前应前往的目标乘客"的相对位置，为策略提供导航目标。
# 目标解析：
#   - 若设置了 objects_to_observe（手动指定目标），直接使用它。
#   - 否则，通过 PassengerManager（"passenger_manager" 组）按本车视角取最佳目标
#     （空车时 assign_passenger()；竞争场景下每车独立选最佳，先到先得）。
#   - 载客时（have_passenger）改报所载乘客的目的地（若存在）。
#
# 继承 PositionSensor3D，会被 SensorManager 自动收集进 position_sensor 数组。
# ============================================================================

## 是否载客（接送逻辑负责维护；本传感器据此决定报"乘客"还是"目的地"）
var have_passenger: bool = false


func add_object_to_observe(target: Passenger) -> void:
	objects_to_observe.append(target)


func _find_vehicle() -> MMTVehicleBody:
	var n: Node = get_parent()
	while n != null:
		if n is MMTVehicleBody:
			return n as MMTVehicleBody
		n = n.get_parent()
	return null


func _get_own_controller() -> AITaxiController:
	var v := _find_vehicle()
	if v == null:
		return null
	for n in get_tree().get_nodes_in_group("taxi_agents"):
		if n is AITaxiController and (n as AITaxiController).get_vehicle() == v:
			return n as AITaxiController
	return null


func _get_manager() -> PassengerManager:
	return get_tree().get_first_node_in_group("passenger_manager") as PassengerManager


## 解析当前要报告的目标（一个 Node3D）；无目标返回 null。
func _resolve_target() -> Node3D:
	# 手动指定优先
	for obj in objects_to_observe:
		if is_instance_valid(obj):
			return obj

	var ctrl := _get_own_controller()
	if ctrl == null:
		return null

	have_passenger = ctrl.has_passenger

	# 载客：报所载乘客的目的地（若已设置）
	if have_passenger and ctrl.carried_passenger != null and is_instance_valid(ctrl.carried_passenger):
		var dest: Node3D = ctrl.carried_passenger.destination
		if dest != null and is_instance_valid(dest):
			return dest

	# 空车：报当前最佳目标乘客
	var mgr := _get_manager()
	if mgr != null:
		return mgr.assign_passenger(ctrl)
	return null


func get_observation():
	var observations: Array[float] = []

	if debug_lines:
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_set_color(debug_color)

	var target := _resolve_target()
	var relative_position := Vector3.ZERO
	if target != null and is_instance_valid(target):
		relative_position = to_local(target.global_position)

	if debug_lines:
		mesh.surface_add_vertex(Vector3.ZERO)
		mesh.surface_add_vertex(relative_position)

	var direction := Vector3.ZERO
	var distance := 0.0
	if use_separate_direction:
		direction = relative_position.normalized()
		distance = min(relative_position.length() / max_distance, 1.0)
		if include_x:
			observations.append(direction.x)
		if include_y:
			observations.append(direction.y)
		if include_z:
			observations.append(direction.z)
		observations.append(distance)
	else:
		relative_position = relative_position.limit_length(max_distance) / max_distance
		if include_x:
			observations.append(relative_position.x)
		if include_y:
			observations.append(relative_position.y)
		if include_z:
			observations.append(relative_position.z)

	if debug_lines:
		mesh.surface_end()
	return observations
