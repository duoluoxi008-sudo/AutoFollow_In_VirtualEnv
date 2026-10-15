extends Marker3D
class_name VehicleSpawner

# ============================================================================
# VehicleSpawner —— 车辆生成点
#
# 作为"在哪个位置生成一辆车"的标记节点：
#   - spawn_vehicle() 实例化 car_scene，设置其阵营/公司(faction_id)，
#     放到本生成点的位姿，并挂到指定父节点（默认挂到 spawner 之外，车可自由开走）。
#   - spawned 标记本生成点当前是否已有车（配合车队/回合重置使用）。
#
# 车队机制：通过写入车内 TaxiServiceComponent.company_id（旧路径：AITaxiController）
# 来区分公司/阵营，供 RivalSensor（对手感知）与同车队不互斥的派单逻辑使用。
# ============================================================================

signal vehicle_spawned(vehicle: Node3D)   ## 成功生成一辆车时发出

## 本生成点是否已经生成过一辆车（尚未被回收/重置）
var spawned: bool = false


## 生成一辆车：实例化 car_scene，设置阵营 faction_id，放到本生成点，并挂到 target_parent。
##
## yaw_offset_rad：在本生成点自身朝向**之上**再绕世界 Y 轴转的角度（弧度），
## 0 表示完全沿用生成点朝向（旧行为）。随机朝向由 VehicleSpawnManager 掷好传进来；
## 之所以要在这里、而不是生成完再改：函数末尾会 `capture_spawn_transform()` 记录出生位姿，
## 车摆好之后再转就会让"记录的出生位姿"和"实际朝向"不一致（回合重置会转回旧朝向）。
##
## 返回实例；若已生成或资源为空则返回 null。
func spawn_vehicle(car_scene: PackedScene, faction_id: int = 0, target_parent: Node = null, yaw_offset_rad: float = 0.0) -> Node3D:
	if spawned:
		return null
	if car_scene == null:
		push_warning("VehicleSpawner: car_scene 为空")
		return null

	var inst := car_scene.instantiate() as Node3D
	if inst == null:
		return null

	# 设置阵营/公司（优先写入 TaxiServiceComponent，其次控制器）
	_set_faction(inst, faction_id)

	# 确定父节点：默认挂在生成点之外（车可以开走），即生成点的父节点
	var parent := target_parent
	if parent == null:
		parent = get_parent()
	if parent == null:
		return null

	parent.add_child(inst)

	# 放到生成点位姿（含朝向）；yaw_offset_rad 用**左乘**叠加上去，
	# 这样不会破坏生成点自身的俯仰/侧倾（生成点通常只有偏航，等于纯随机朝向）。
	var pose := global_transform
	if not is_zero_approx(yaw_offset_rad):
		pose.basis = Basis(Vector3.UP, yaw_offset_rad) * pose.basis
	inst.global_transform = pose

	# 位姿摆好之后，再让控制器记录"出生位姿"。
	# 必须放在这里：add_child() 会**同步**触发整棵子树的 _ready()，那一刻车还停在
	# .tscn 的出厂位姿上（mmt_sedan.tscn 的根节点没有 transform → 单位矩阵），
	# 控制器若在 _ready() 里直接记录就会把"出生位姿"记成世界原点，
	# 于是回合重置会把所有车传送到原点（表现为"车辆消失"）。
	#
	# 记录工作现在由 VehicleStateResetter 组件负责（AI/玩家通用），
	# 找不到组件时回落到旧的控制器接口。
	var resetter: VehicleStateResetter = VehicleStateResetter.find_in_subtree(inst)
	if resetter != null:
		resetter.capture_spawn_transform()
	else:
		var ctrl := _find_controller(inst)
		if ctrl != null:
			ctrl.capture_spawn_transform()

	spawned = true
	vehicle_spawned.emit(inst)
	return inst


## 供 VehicleSpawnManager.reset() 调用：释放本生成点，允许再次生成。
func reset_spawn_state() -> void:
	spawned = false


## 把车辆的公司/阵营设为 faction_id（车队机制）。
## 公司编号的"真身"在 TaxiServiceComponent 上（玩家车没有控制器也必须能设阵营）；
## 找不到组件时回落到旧的控制器字段。
func _set_faction(vehicle: Node3D, faction_id: int) -> void:
	var svc: TaxiServiceComponent = TaxiServiceComponent.find_in_subtree(vehicle)
	if svc != null:
		svc.company_id = faction_id
	var ctrl := _find_controller(vehicle)
	if ctrl != null:
		ctrl.company_id = faction_id


## 递归查找车辆子树里的 AITaxiController。
func _find_controller(node: Node) -> AITaxiController:
	if node is AITaxiController:
		return node as AITaxiController
	for child in node.get_children():
		var r := _find_controller(child)
		if r != null:
			return r
	return null


func _on_car_exited(body: Node3D) -> void:
	if body is MMTVehicleBody:
		spawned = false


func _on_car_entered(body: Node3D) -> void:
	if body is MMTVehicleBody:
		spawned = true
