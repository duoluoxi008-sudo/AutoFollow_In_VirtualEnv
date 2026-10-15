@tool
extends Resource
class_name AIParameterEntry

# 关于 @tool：AIParameter 的面板按钮「一键同步到所有AI节点」会在**编辑器里**
# 调用本类的 apply_to()。如果本脚本不是 @tool，编辑器里加载出来的子资源只是
# "占位实例"，方法调用会直接报
#     Attempt to call a method on a placeholder instance.
# 于是那个按钮点了没有任何反应。（运行时不受影响 —— 这也是为什么
# VehicleSpawnManager 走"生成时下发"这条路更可靠。）
# 本类只有纯数据 + 纯函数，加 @tool 是安全的。

# ============================================================================
# AIParameterEntry —— 一套完整的 AI/RL 超参数（Resource）
#
# 把一个 AITaxiController（及其奖励函数、传感器、训练侧）涉及到的所有超参数
# 收集到同一个类里，作为 AIParameter 数组中“一套参数”的元素。
# 因为字段都是 @export，所以在检查器里可以像普通资源一样逐项调整。
#
# AIParameter 通过 id 把某套参数匹配到对应的 AI 节点，
# 再用 apply_to(target) 把字段写入目标（只覆盖目标上存在的同名字段）。
# ============================================================================

## 参数集标识：可填目标节点名（如 "AITaxiController"）用于精确匹配；留空则取第一套。
##
## ⚠️ 注意：运行时生成的车会被 Godot 自动加后缀（MMTSedan、MMTSedan2…），
## 所以**按节点名匹配对生成出来的车基本不会命中**，最后总是落到第一套。
## 要给不同阵营不同参数，请用下面的 company_id。
@export var id: String = ""

## 该套参数适用的阵营/公司 id（对应 TaxiServiceComponent.company_id）。
## VehicleSpawnManager 生成车辆后按这个字段精确匹配；-1 表示通配（兜底用）。
@export var company_id: int = -1

# ---------------------------------------------------------------------------
@export_group("目标与任务")
## 制动起始距离（米）：进入这个距离就开始减速（配合 PickUpAndDropRewardFunction.rw_speed，
## 越近扣得越狠）。这是"停稳接客"的提前量——给得越大，车越早松油门。
@export var target_follow_distance: float = 12.0
## 观测归一化用的最大车速（米/秒）
@export var max_speed_mps: float = 25.0
## 进度归一化距离的**下限**（米）。进度按"锁定目标那一刻的距离"归一化（与地图尺度无关），
## 这个值只是防御性下限，防止目标正好锁在脚边时每米收益爆炸。换地图不需要改它。
@export var track_range: float = 10.0
## 回合最大物理帧数，超过则判定超时。
## 10800 帧 = 180 秒 @ 60Hz（每个物理帧推进 1/60 秒仿真时间，与 --speedup 无关）。
## 实测跑完一单约 2 分钟，所以给 3 分钟 = 1.5 倍余量。
@export var reset_after: int = 10800

# ---------------------------------------------------------------------------
@export_group("奖励权重")
## 过远惩罚权重：到目标距离 > max_track_dist 时，按 (d/max_track_dist − 1) 扣。
## 与 max_track_dist 必须同时 > 0 才生效。默认关闭。
@export var rw_dist: float = 0.0
## 减速引导权重：进入 target_follow_distance 后按速度扣，越近扣得越狠。
@export var rw_speed: float = 0.05
## 横向滑移惩罚权重：抑制甩尾/侧滑。
@export var rw_lateral: float = 0.01
## 进度奖励权重。按 d_0 归一化，所以它就是"每段子目标的塑形预算"：
## 一次完整送达的塑形上限 = 2 × rw_progress。推荐 2×rw_progress ≈ 0.3~0.5 × 事件总和(12)。
@export var rw_progress: float = 3.0
## 时间代价（负数）。等价关系：旧的 step_cost（每帧）== -rw_step / frames_per_step。
@export var rw_step: float = -0.008
## 每个 env step 对应多少物理帧（= sync.gd 的 action_repeat）。用于"每步"→"每帧"换算。
@export var frames_per_step: float = 8.0
## 失败（超时）奖励
@export var reward_fail: float = -6.0

# ---------------------------------------------------------------------------
@export_group("终止条件")
## 过远阈值（米），配合 rw_dist。默认 0 = 不启用过远惩罚。
@export var max_track_dist: float = 0.0
## 到位确认半径（米）：接送事件发生时若到目标距离超过它，事件奖励不计发。
## ⚠️ 必须 ≥ pickup_radius(2.0) / dropoff_radius(2.5)，否则会误杀真实接送、奖励恒为 0。
@export var success_dist: float = 3.0
## 是否启用成功即终止（接送任务必须打开：否则每回合都拖到超时吃 reward_fail，
## 而且 reward_success 永远不会触发）
@export var enable_success_terminal: bool = true
## 需要持续满足成功条件的帧数
@export var success_hold_frames: int = 8

# ---------------------------------------------------------------------------
@export_group("接送")
## 靠近多近可接客（米）
@export var pickup_radius: float = 2.0
## 靠近多近可送达（米）
@export var dropoff_radius: float = 2.5
## 判定停稳的速度阈值（米/秒）
@export var stop_speed_threshold: float = 1.5
## 目标被对手抢走的惩罚。暂设 0：策略连"接客"都还没学会时，竞争惩罚只会加噪声。
## 等 task/pickups 稳定为正之后再调回 1.5~2.0 引入竞争。
@export var stolen_penalty: float = 0.0

# ---------------------------------------------------------------------------
@export_group("奖励项开关（按奖励函数分别控制）")
## 为什么需要单独开关：`enabled` 是同名匹配的，写在 AIParameterEntry 里会同时作用到
## **所有** RewardFunction3D，无法"只关掉其中一个"。所以下面给每个奖励函数各留一个
## **唯一名字**的字段 —— apply_to 只写目标上真实存在的字段，所以
## enabled_dense_nav 只会命中 DenseNavigationReward，不会碰到别的。
##
## 用途：课程学习时切换奖励组合。例如
##   Phase 1（验证学习链路）：只开 dense_nav，关掉另外两个
##   Phase 2（端到端接客）：关掉 dense_nav，开 pickdrop
## PickUpAndDropRewardFunction（事件奖励 + 进度塑形 + 减速引导）是否启用
@export var enabled_pickdrop: bool = true
## isMovingRewardFunction（低速惩罚）是否启用。
## 它与"必须停稳接客"直接冲突，建议只在稳定接客后再打开，并把 grace_steps 调大。
@export var enabled_moving_penalty: bool = false
## DenseNavigationReward（纯导航密集奖励，Phase 1 用）是否启用
@export var enabled_dense_nav: bool = false
## SteeringSmoothnessReward（转向抖动惩罚）是否启用。
## 默认开：它不改变任务目标（匀速转弯免费，只有来回猛打才扣分），
## 所以 Phase 1 / Phase 2 都该保留。
@export var enabled_smoothness: bool = true
## WallContactReward（撞墙惩罚）是否启用。默认开：它只在**车真的贴着墙**时按帧扣分，
## 空场地里等于不存在；有墙的场景里它提供"离开墙"的持续压力（详见该脚本注释）。
@export var enabled_wall_contact: bool = true


# ---------------------------------------------------------------------------
@export_group("奖励函数")
## 事件奖励。塑形 / 时间代价 / 减速引导的权重统一在「奖励权重」组
## （rw_progress / rw_step / rw_speed），这里不再重复定义 —— 同一个量两个名字只会误导调参。
## 接客事件奖励
@export var reward_pickup: float = 2.0
## 送达事件奖励（任务完成主要奖励）
@export var reward_dropoff: float = 5.0
## 视为“正在移动”的速度阈值（米/秒）
@export var low_speed_threshold: float = 0.5
## 连续低速的宽限期（训练步）
@export var grace_steps: int = 180
## 超宽限期后每步追加惩罚
@export var penalty_per_step: float = 0.003
## 单步最大惩罚
@export var max_step_penalty: float = 0.5

# ---------------------------------------------------------------------------
@export_group("传感器")
## 对手观测中保留的最近对手数量
@export var max_opponents_obs: int = 6
## 是否把同公司队友也当作对手
@export var observe_same_company: bool = false
## 位置传感器归一化最大距离（米）
@export var sensor_max_distance: float = 10.0

# ---------------------------------------------------------------------------
@export_group("训练超参数（PPO / SB3，供 Python 侧记录与同步）")
## 学习率
@export var learning_rate: float = 0.0003
## 每次更新前采样的步数
@export var n_steps: int = 2048
## 小批量大小
@export var batch_size: int = 64
## 折扣因子 γ
@export var gamma: float = 0.99
## GAE λ
@export var gae_lambda: float = 0.95
## PPO 裁剪范围
@export var clip_range: float = 0.2
## 熵奖励系数
@export var entropy_coef: float = 0.01
## 价值函数损失系数
@export var vf_coef: float = 0.5
## 梯度裁剪范数
@export var max_grad_norm: float = 0.5


## 字段名别名映射：本 entry 上的字段名 → { field = 目标上真实字段名, class = 限定脚本类名 }。
##
## 用途：`apply_to` 是按"同名字段"写的，而三个奖励函数都想用基类那一个 `enabled`，
## 所以 entry 侧必须用三个不同的字段名（enabled_pickdrop / enabled_moving_penalty /
## enabled_dense_nav），再在这里映射回目标上的 `enabled`。
##
## ⚠️⚠️ 必须同时限定**目标脚本类名**。曾经的实现只写 `"xxx": "enabled"`，
## 靠"目标上有没有 enabled 字段"来筛选 —— 那是错的：三个别名都会命中
## **同一个** RewardFunction3D，写入顺序 = 字段声明顺序，于是最后写的
## `enabled_dense_nav = true` 把前面两个 false 全部覆盖掉。
## 实测症状：面板里明明关了 isMoving/pickdrop，运行时三项都还在算
## （`[Reward]` 打印里 `禁用:[]`、`isMovingRewardFunction=-0.5000/帧`、
## 甚至 `enabled_pickdrop=false` 的 PickUpAndDropRewardFunction 也在扣分）。
##
## 加上类名限定后，每个别名只会命中自己那一类，顺序不再有影响。
const FIELD_ALIASES := {
	"enabled_pickdrop": {"field": "enabled", "class": "PickUpAndDropRewardFunction"},
	"enabled_moving_penalty": {"field": "enabled", "class": "isMovingRewardFunction"},
	"enabled_dense_nav": {"field": "enabled", "class": "DenseNavigationReward"},
	"enabled_smoothness": {"field": "enabled", "class": "SteeringSmoothnessReward"},
	"enabled_wall_contact": {"field": "enabled", "class": "WallContactReward"},
}


## 取目标节点脚本的"身份名"：优先 class_name，取不到就退回脚本文件名（去扩展名）。
## 供 FIELD_ALIASES 的类名限定使用；目标没有脚本时返回空串。
func _target_class_name(target: Object) -> String:
	var scr = target.get_script()
	if not (scr is Script):
		return ""
	var s := scr as Script
	var global_name := String(s.get_global_name())
	if not global_name.is_empty():
		return global_name
	return s.resource_path.get_file().get_basename()


## 把本套参数写入 target：只覆盖 target 上确实存在的同名字段（跳过 id 与资源内置属性）。
## 字段名会先经 FIELD_ALIASES 转换。
##
## ⚠️ null 必须跳过：场景里"没填"的导出字段读出来是 null，而
## `target.set("enabled", null)` 对 bool 属性**不会**变成 false ——
## Godot 会保留默认值 true（或写入失败）。实测后果：想在 AIParameter 面板里
## 关掉某个奖励项，写了 enabled_xxx = null 却完全没生效，
## isMovingRewardFunction 仍以 -0.5/帧吃满惩罚（× 10500 帧 = -5250，
## 正好等于观测到的 episode_reward）。
##
## 这同时也是"字段留空 = 不覆盖，沿用目标节点自己的值"的正确语义。
##
## 返回实际写入的字段数量。
func apply_to(target: Object) -> int:
	if target == null:
		return 0

	# 先收集目标对象上可写的属性名，避免对不存在的属性 set() 报错。
	var target_names: Dictionary = {}
	for p in target.get_property_list():
		target_names[p["name"]] = true

	var applied := 0
	# 类名只在第一次真的需要时解析（大多数字段都用不到这个限定）
	var target_class := ""
	var target_class_resolved := false
	for p in get_property_list():
		# 只处理脚本里定义的变量（跳过 resource_path / resource_name 等内置属性）
		if not (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var field: String = p["name"]
		# id / company_id 是"这套参数属于谁"的**元数据**（get_entry_for_company 靠它匹配），
		# 不是要写进目标的参数。
		# ⚠️ company_id 必须一起跳过：AITaxiController.company_id 是个 setter 属性
		# （写它会转发给 taxi_service.company_id），而 VehicleSpawner 刚按 faction_id
		# 设好这个值。若某套参数用 company_id = -1 做通配，就会把所有车的阵营身份
		# 都改成 -1 —— 多阵营场景里会直接破坏公司判定。
		if field == "id" or field == "company_id":
			continue
		# 别名转换：entry 字段名 → 目标上的真实字段名（可能还带类名限定）
		var target_field: String = field
		var required_class := ""
		if FIELD_ALIASES.has(field):
			var alias: Dictionary = FIELD_ALIASES[field]
			target_field = String(alias["field"])
			required_class = String(alias["class"])
		if not target_names.has(target_field):
			continue
		# 类名限定：不匹配就跳过 —— 否则各个 enabled_xxx 会互相覆盖（见 FIELD_ALIASES 说明）
		if not required_class.is_empty():
			if not target_class_resolved:
				target_class = _target_class_name(target)
				target_class_resolved = true
			if target_class != required_class:
				continue
		var value: Variant = get(field)
		# null = 未填写，不覆盖（见上面的说明）
		if value == null:
			continue
		target.set(target_field, value)
		applied += 1
	return applied


func _to_string() -> String:
	return "AIParameterEntry(id=%s)" % id
