extends PositionSensor3D
class_name RivalSensor

# ============================================================================
# RivalSensor —— 对手位置的 PositionSensor
#
# 竞争多智能体场景：感知"其它公司"的出租车，为策略提供对手信息以预测竞争/拥堵。
# 规则（车队机制）：
#   - 只观察与本车 **company_id 不同** 的出租车（同公司的队友不是对手）。
#   - 输出定长观测：最近 max_opponents_obs 辆对手，每辆 4 维：
#         [归一化 x, 归一化 z, 归一化距离, 是否载客(0/1)]
#   - 按到本车距离升序排列（置换不变，避免"谁是第几个输入"敏感），不足则补零。
#
# 由于继承 PositionSensor3D，SensorManager 会自动把它收集进 position_sensor 数组，
# 其 get_observation() 结果会被拼接进观测向量。
# ============================================================================

## 观察最近几辆对手（定长）
@export_range(1, 15) var max_opponents_obs: int = 6
## 若为 true，把同公司队友也当作对手（关闭车队机制）；默认 false（队友不算对手）
@export var observe_same_company: bool = false


func _find_vehicle() -> MMTVehicleBody:
	var n: Node = get_parent()
	while n != null:
		if n is MMTVehicleBody:
			return n as MMTVehicleBody
		n = n.get_parent()
	return null


## 找到本车所属的 AITaxiController（用于读取 company_id / is_carrying）
func _get_own_controller() -> AITaxiController:
	var v := _find_vehicle()
	if v == null:
		return null
	for n in get_tree().get_nodes_in_group("taxi_agents"):
		if n is AITaxiController and (n as AITaxiController).get_vehicle() == v:
			return n as AITaxiController
	return null


func get_observation():
	var obs: Array[float] = []

	if debug_lines:
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_set_color(debug_color)

	var self_ctrl := _get_own_controller()
	if self_ctrl == null:
		for i in range(max_opponents_obs):
			obs.append_array([0.0, 0.0, 0.0, 0.0])
		return obs

	var my_company: int = self_ctrl.company_id
	var entries: Array = []

	for n in get_tree().get_nodes_in_group("taxi_agents"):
		if n is AITaxiController and n != self_ctrl:
			var o := n as AITaxiController
			if not observe_same_company and o.company_id == my_company:
				continue  # 队友不算对手（车队机制）
			var v: MMTVehicleBody = o.get_vehicle()
			if v == null or not is_instance_valid(v):
				continue
			var rel: Vector3 = to_local(v.global_transform.origin)
			var d: float = Vector2(rel.x, rel.z).length()
			entries.append({
				"x": rel.x, "z": rel.z, "d": d,
				"carry": 1.0 if o.is_carrying() else 0.0,
				"pos": v.global_transform.origin,
			})

	entries.sort_custom(func(a, b) -> bool: return a["d"] < b["d"])

	for i in range(max_opponents_obs):
		if i < entries.size():
			var e: Dictionary = entries[i]
			obs.append(clampf(float(e["x"]) / max_distance, -1.0, 1.0))
			obs.append(clampf(float(e["z"]) / max_distance, -1.0, 1.0))
			obs.append(clampf(float(e["d"]) / max_distance, 0.0, 1.0))
			obs.append(float(e["carry"]))
			if debug_lines:
				mesh.surface_add_vertex(Vector3.ZERO)
				mesh.surface_add_vertex(to_local(e["pos"]))
		else:
			obs.append_array([0.0, 0.0, 0.0, 0.0])

	if debug_lines:
		mesh.surface_end()
	return obs
