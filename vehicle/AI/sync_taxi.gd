extends Sync
class_name TaxiSync

# ============================================================================
# TaxiSync —— godot_rl `Sync` 的子类：等所有 arena 就绪后再和 Python 握手
#
# 插件本体 `addons/godot_rl_agents/sync.gd` **不做任何修改**，所有定制都在这里。
#
# ----------------------------------------------------------------------------
# 布局（并行训练）
# ----------------------------------------------------------------------------
#     ParaTrainScene (外层场景根)
#     ├── TrainScene  …  TrainSceneN     ← 每个都是一份完整的 arena（TrainingArena）
#     └── TaxiSync                       ← 唯一的 Sync，和各个 arena 并排
#
# 一个进程只能有一个 Sync：它持有到 Python 的 TCP 连接，而 `_get_agents()` 是扫
# **全局 "AGENT" 组**（sync.gd:363），所以放在外层的 Sync 会一次收下所有 arena 里
# 所有车的 AIController —— 这正是"多 arena 同进程"能成立的原因。
#
# ----------------------------------------------------------------------------
# 为什么要等 arena
# ----------------------------------------------------------------------------
# `Sync._ready()` 的第一步是 `await get_parent().ready`：官方示例里 agent 都摆在
# 场景文件里，所以"父节点 ready"就等于"我的世界全就位了"。但本项目的车是
# VehicleSpawnManager 用 `call_deferred("_spawn_fleet")` **运行时生成**的，
# 父节点 ready 那一刻车还不存在 → `_get_agents()` 扫到空数组 → `agents_training`
# 为空 → `connect_to_server()` 根本不会被调用（表现为"不暂停、不等 Python"）。
#
# 所以等待必须发生在 `_initialize()` 之前，而"我这份 arena 就绪了吗"由 arena 自己判断
# （见 TrainingArena.arena_ready）。本类只负责：**收齐父节点下的所有 arena → 等它们全部就绪**。
#
# 为什么要覆写 `_ready()` 而不调 `super._ready()`：
#   `Sync._ready()` 的第一行 `await get_parent().ready` 在 super 调用下会让协程挂住不恢复
#   （父节点此时必然已经 ready，`await` 一个已发出的信号就永远等不到），于是后面的
#   `_initialize()` 永远不执行 —— 实测证据：
#       [SyncDiag] after super._ready(): initialized=false all_agents=0
#   所以这里**复刻** `Sync._ready()` 剩余的逻辑（set_pause → _initialize → 等 1 秒 → unpause），
#   并用 `initialized` 标志防重入。
# ============================================================================

## 等待所有 arena 就绪的超时（秒）。超时后仍然继续初始化，只是会打印告警。
@export var arena_ready_timeout: float = 15.0

## 初始化时是否真的等到了"全部 arena 就绪"（供外部/日志查询）
var arenas_waited_ok: bool = false


func _ready():
	# 1) 先等所有 arena 把世界摆好（否则扫 AGENT 组会得到空数组）
	await _wait_for_arenas()

	# 2) 初始化（复刻 Sync._ready()，见文件头说明：不能走 super._ready()）
	if not initialized:
		get_tree().set_pause(true)
		_initialize()
		await get_tree().create_timer(1.0).timeout
		get_tree().set_pause(false)

	# 3) 报告登记结果（空列表时给出明确诊断）
	_report_agent_state()


## 覆写理由：加防重入保护。父类 `_initialize()` 本身没有幂等保护，
## 如果父类 `_ready()` 的协程之后恢复，会二次调用它（重复连接/重复握手）。
func _initialize():
	if initialized:
		return
	super._initialize()


# ----------------------------------------------------------------------------
# 收集 arena（父节点的直接子级 + 类型判定，不用组）
# ----------------------------------------------------------------------------

## 收齐本进程里的所有训练场地。
##
## 常规布局是"外层场景根下并与 Sync 并排摆 N 个 arena"，所以先看父节点的**直接子级**；
## 万一 arena 被放进某个容器节点里，再退一步在父节点子树里按类型找一次
## （只在启动时做一次，成本可忽略）。
func collect_arenas() -> Array[TrainingArena]:
	var found: Array[TrainingArena] = []
	var parent := get_parent()
	if parent == null:
		return found

	for c in parent.get_children():
		if c is TrainingArena and is_instance_valid(c):
			found.append(c as TrainingArena)
	if not found.is_empty():
		return found

	# owned 必须显式传 false：运行时 instantiate 出来的场景实例没有 owner，
	# owned=true（默认值）会把它们整片跳过。
	for n in parent.find_children("*", "TrainingArena", true, false):
		if n is TrainingArena and is_instance_valid(n):
			found.append(n as TrainingArena)
	return found


## 是否所有 arena 都已就绪（同步判定，便于单测/外部查询）
#expose
func all_arenas_ready(arenas: Array) -> bool:
	for a in arenas:
		if a == null or not is_instance_valid(a) or not a.is_ready:
			return false
	return true


## 等所有 arena 就绪。返回 true 表示确认就绪（或无需等待）。
#expose
func _wait_for_arenas() -> bool:
	var arenas := collect_arenas()
	if arenas.is_empty():
		push_warning(
			"[TaxiSync] 没有在父节点下找到任何 TrainingArena！\n"
			+ "  Sync 必须挂在外层场景里、和各个 arena 并排（每个 arena 的根节点要挂 TrainingArena 脚本），\n"
			+ "  否则 _get_agents() 会扫到空数组、连不上 Python。"
		)
		arenas_waited_ok = false
		return false

	if all_arenas_ready(arenas):
		arenas_waited_ok = true
		print("[TaxiSync] %d 个 arena 均已就绪，跳过等待。" % arenas.size())
		return true

	var pending := _pending_names(arenas)
	print("[TaxiSync] 等待 %d 个 arena 就绪：%s" % [pending.size(), str(pending)])

	var deadline := Time.get_ticks_msec() + int(arena_ready_timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if all_arenas_ready(arenas):
			arenas_waited_ok = true
			print("[TaxiSync] 全部 arena 已就绪（共 %d 个）。" % arenas.size())
			return true
		await get_tree().process_frame

	# 超时：报告谁没就绪（带上已生成的车辆数，方便判断卡在哪一步），但继续初始化，
	# 绝不永久挂住 —— 否则训练侧会一直卡在 "waiting for remote GODOT connection"。
	var stuck: Array[String] = []
	for a in arenas:
		if a != null and is_instance_valid(a) and not a.is_ready:
			stuck.append("%s(车辆=%d)" % [a.name, a.vehicle_count()])
	push_warning(
		"[TaxiSync] 等待 arena 就绪超时（%.1f 秒）。未就绪：%s" % [arena_ready_timeout, str(stuck)]
	)
	arenas_waited_ok = false
	return false


func _pending_names(arenas: Array) -> Array[String]:
	var names: Array[String] = []
	for a in arenas:
		if a != null and is_instance_valid(a) and not a.is_ready:
			names.append(a.name)
	return names


# ----------------------------------------------------------------------------
# 诊断
# ----------------------------------------------------------------------------
## 初始化后检查 agent 是否真的被登记。空列表时给出明确诊断，
## 因为这种情况在 Sync 原逻辑里是静默跳过的（不会连接、不会报错）。
func _report_agent_state() -> void:
	var total := all_agents.size()
	var training := agents_training.size()
	print(
		"[TaxiSync] 已登记 agent：all=%d, training=%d（arena=%d 个，等待就绪=%s）"
		% [total, training, collect_arenas().size(), str(arenas_waited_ok)]
	)

	if training == 0:
		push_error(
			"[TaxiSync] agents_training 为空，Sync 不会连接 Python！\n"
			+ "  可能原因：\n"
			+ "   1) Sync 不在外层场景里（没和 arena 并排），导致没等到 arena 就绪\n"
			+ "   2) arena 根节点没挂 TrainingArena 脚本，收不到 arena_ready\n"
			+ "   3) 车辆没有被生成（检查 VehicleSpawnManager.auto_spawn / car_scene / spawner_root）\n"
			+ "   4) AITaxiController 的 control_mode 不是 TRAINING（且 Sync.control_mode 也不是）\n"
			+ "   5) 车辆在 arena 就绪之后才被加入场景"
		)
