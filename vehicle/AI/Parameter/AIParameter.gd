@tool
extends Node
class_name AIParameter

# ============================================================================
# AIParameter —— AI/RL 超参数集容器
#
# 用一个数组 parameters: Array[AIParameterEntry] 保存多套超参数；
# 每一套 AIParameterEntry 收集了一个 AITaxiController 及其奖励函数/传感器/训练侧
# 涉及到的全部超参数。
#
# 其他 AI 控制器从中“找到对应的一套参数”：
#   - 先按 id 匹配（entry.id == 目标节点名）
#   - 都没有则取第一套
# 找到后用 AIParameterEntry.apply_to(target) 把字段写入目标。
#
# 面板按钮「一键同步到所有AI节点」：遍历当前场景里的所有 AI 节点，
# 各自匹配一套参数并写入，相当于在面板里统一调参。
# ============================================================================

## 该节点所在的分组（便于控制器用组查找）
const GROUP := &"AIParameter"

## 多套超参数（每套对应一类/一个 AI 节点）
@export var parameters: Array[AIParameterEntry] = []

## 面板按钮：一键把参数同步到当前场景所有 AI 节点（仅编辑器内可见）
@export_tool_button("一键同步到所有AI节点") var sync_to_ai_nodes = _sync_to_all_ai_nodes


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	# 首次使用且为空时，自动放一套默认参数，方便直接在面板里调整
	if parameters.is_empty():
		parameters.append(AIParameterEntry.new())


# ----------------------------------------------------------------------------
# 查找 / 应用
# ----------------------------------------------------------------------------
## 为目标节点找到对应的一套参数。
func get_entry_for(target: Object) -> AIParameterEntry:
	if parameters.is_empty():
		return null

	if target != null:
		# 按节点名 == id 精确匹配
		if target is Node:
			var node_name: String = (target as Node).name
			for e in parameters:
				if e != null and not e.id.is_empty() and e.id == node_name:
					return e

	# 兜底：第一套
	return parameters[0]


## 按阵营/公司 id 匹配一套参数（VehicleSpawnManager 生成车辆时用这个）。
##
## 为什么不复用 get_entry_for() 的"按节点名匹配"：运行时 instantiate 出来的车会被
## Godot 自动加后缀（MMTSedan、MMTSedan2…），拿节点名去比一个固定 id 基本不会命中，
## 结果永远是第一套。按 company_id 匹配才是稳定的。
##
## 匹配顺序：精确命中 company_id → company_id == -1 的通配项 → 第一套。
func get_entry_for_company(company_id: int) -> AIParameterEntry:
	if parameters.is_empty():
		return null
	for e in parameters:
		if e != null and e.company_id == company_id:
			return e
	for e in parameters:
		if e != null and e.company_id == -1:
			return e
	return parameters[0]


## 把匹配到的那套参数写入 target，返回实际写入的字段数量。
func apply_to(target: Object) -> int:
	var entry := get_entry_for(target)
	if entry == null:
		return 0
	return entry.apply_to(target)


## 按 id 精确取一套参数（找不到返回 null）。
func get_entry_by_id(entry_id: String) -> AIParameterEntry:
	for e in parameters:
		if e != null and e.id == entry_id:
			return e
	return null


# ----------------------------------------------------------------------------
# 编辑器一键同步
# ----------------------------------------------------------------------------
## 遍历当前场景里所有 AI 节点，各自匹配一套参数并写入。
func _sync_to_all_ai_nodes() -> void:
	var root := _get_sync_root()
	if root == null:
		push_warning("AIParameter: 找不到可同步的场景根节点。")
		return
	var node_count := 0
	var field_count := 0
	for node in root.find_children("*", "", true, false):
		if node == self or not (node is Node):
			continue
		if not _is_ai_node(node):
			continue
		field_count += apply_to(node)
		node_count += 1
	print("AIParameter: 已同步 %d 个 AI 节点（共写入 %d 个字段）。" % [node_count, field_count])


## 取得要同步的场景根：编辑器里用正在编辑的场景，运行时用当前场景。
func _get_sync_root() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if Engine.is_editor_hint() and tree.edited_scene_root != null:
		return tree.edited_scene_root
	if tree.current_scene != null:
		return tree.current_scene
	return tree.root


## 判断节点是否为 AI 相关节点（控制器 / 奖励函数 / 传感器 / 管理器，或属于 AI 分组）。
func _is_ai_node(node: Node) -> bool:
	if node is AIController3D:
		return true
	if node is RewardFunction3D:
		return true
	if node is ISensor3D:
		return true
	if node is SensorManager:
		return true
	if node is RewardManager:
		return true
	# 与 VehicleSpawnManager._collect_ai_nodes() 保持一致（那边漏了它，
	# 导致 pickup_radius / dropoff_radius / stop_speed_threshold 是死旋钮）
	if node is TaxiServiceComponent:
		return true
	if node.is_in_group("AGENT") or node.is_in_group("taxi_agents"):
		return true
	return false


# ----------------------------------------------------------------------------
# 便捷静态接口
# ----------------------------------------------------------------------------
## 查找场景中的 AIParameter 实例（组 "AIParameter"）。
static func find(tree: SceneTree) -> AIParameter:
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as AIParameter


## 一步取值：为目标节点找到对应参数集并读取某字段（找不到实例/字段时返回 default）。
static func get_param_for(tree: SceneTree, target: Object, field: String, default: float = 0.0) -> float:
	var instance := find(tree)
	if instance == null:
		return default
	var entry := instance.get_entry_for(target)
	if entry == null:
		return default
	for p in entry.get_property_list():
		if p["name"] == field:
			return float(entry.get(field))
	return default
