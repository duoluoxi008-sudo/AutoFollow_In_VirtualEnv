extends PositionSensor3D
class_name RivalPositionSensor

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
# ⚠️ 对手来源必须限定在**本车所属 arena**：
# 多 arena 同进程时用全局 `taxi_agents` 组会把别的场地的车也算成对手 ——
# 它们物理上相距几百米（arena 之间靠 transform 平移分开），
# 归一化后偶尔落进 [-1,1]，变成凭空出现的"幽灵对手"，污染观测。
# 因此改为从 arena 的 VehicleSpawnManager.vehicles（本场地的车辆池）里取。
#
# 由于继承 PositionSensor3D，SensorManager 会自动把它收集进 position_sensor 数组，
# 其 get_observation() 结果会被拼接进观测向量。
# ============================================================================

## 观察最近几辆对手（定长）
@export_range(1, 15) var max_opponents_obs: int = 6
## 若为 true，把同公司队友也当作对手（关闭车队机制）；默认 false（队友不算对手）
@export var observe_same_company: bool = false


## 沿父链找到本车。
func _get_own_vehicle() -> MMTVehicleBody:
	var n: Node = get_parent()
	while n != null:
		if n is MMTVehicleBody:
			return n as MMTVehicleBody
		n = n.get_parent()
	return null


## 取得本车的接送组件（读 company_id / is_carrying 用）。
func _get_own_service() -> TaxiServiceComponent:
	return TaxiServiceComponent.find_for(self)


## 收集**本 arena** 内所有车辆的接送组件。不越出所属 TrainingArena。
func _collect_arena_services() -> Array[TaxiServiceComponent]:
	var out: Array[TaxiServiceComponent] = []
	var arena := TrainingArena.of(self)
	if arena == null:
		return out
	var vsm := arena.get_vehicle_spawn_manager()
	if vsm == null:
		return out
	for v in vsm.vehicles:
		if v == null or not is_instance_valid(v):
			continue
		var svc := TaxiServiceComponent.find_for(v)
		if svc != null:
			out.append(svc)
	return out


#expose
func get_observation():
	var obs: Array[float] = []

	if debug_lines:
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_set_color(debug_color)

	var own_vehicle := _get_own_vehicle()
	var own_service := _get_own_service()
	if own_vehicle == null or own_service == null:
		for i in range(max_opponents_obs):
			obs.append_array([0.0, 0.0, 0.0, 0.0])
		if debug_lines:
			mesh.surface_end()
		return obs

	var my_company: int = own_service.company_id
	var entries: Array = []

	# 只看本场地的车
	for svc in _collect_arena_services():
		var v: MMTVehicleBody = svc.vehicle
		if v == null or not is_instance_valid(v):
			continue
		if v == own_vehicle:
			continue
		if not observe_same_company and svc.company_id == my_company:
			continue  # 队友不算对手（车队机制）
		var rel: Vector3 = to_local(v.global_transform.origin)
		var d: float = Vector2(rel.x, rel.z).length()
		entries.append({
			"x": rel.x, "z": rel.z, "d": d,
			"carry": 1.0 if svc.is_carrying() else 0.0,
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
