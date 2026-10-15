extends Node
class_name RewardManager

# ============================================================================
# RewardManager —— 收集并累加本车所有 RewardFunction3D 子节点的奖励
#
# 调试支持：`debug_breakdown = true` 时，每 `debug_interval` 个物理帧打印一次
# **各奖励项的原始贡献（每帧平均）**。
#
# 为什么需要它：只看累加值无法判断是哪一项在扣分。实测遇到过
# episode_reward ≈ -5320（约 -0.49/帧），而 rw_step 换算后只有 -0.00125/帧 ——
# 差了 400 倍，靠读代码和猜都定位不到，必须把各分量打出来。
# ============================================================================

## 是否打印各奖励项的分解（调奖励时打开，训练稳定后关掉）
@export var debug_breakdown: bool = false
## 打印间隔（物理帧）。默认 600 帧 = 10 秒 @60Hz，避免刷屏。
@export var debug_interval: int = 600

@export var car_ref:AITaxiController
var reward_funcs:Array[RewardFunction3D] = []
var _debug_tick: int = 0
## 各奖励项的区间累计值（打印后清空）
var _debug_accum: Dictionary = {}
## 本区间内"策略下达了倒车指令"的帧数（用来确认"它到底有没有在用倒车"）
var _debug_reverse_frames: int = 0


#expose
func _ready() -> void:
	assert(car_ref != null, 'RewardManager的car_ref未设置')
	reward_funcs.clear()
	for child in get_children():
		# 只收集确实是 RewardFunction3D 的子节点（跳过非奖励节点/占位实例，避免 TypedArray 校验崩溃）
		if child is RewardFunction3D:
			var rw := child as RewardFunction3D
			reward_funcs.append(rw)
			if rw.has_method("get_car_ref"):
				rw.get_car_ref(car_ref)


#expose
func get_reward()->float:
	var reward:float = 0.0
	for rw in reward_funcs:
		# 只有**显式 true** 才参与计算。用 `rw.enabled == true` 而不是 `rw.enabled`，
		# 因为 AIParameterEntry 用 target.set(field, value) 写值，若 value 是 null
		# 或类型不符，`enabled` 可能不是干净的 bool —— 那种情况应按"未启用"处理，
		# 而不是靠 truthy/falsy 猜。
		if rw.enabled != true:
			continue
		var v := float(rw.get_reward())
		reward += v
		if debug_breakdown:
			_debug_accum[rw.name] = float(_debug_accum.get(rw.name, 0.0)) + v

	if debug_breakdown:
		_debug_tick += 1
		# 统计倒车指令占比：这是"它到底有没有学会用倒车"的唯一直接读数。
		# （只读 _last_action，不改任何状态；配合 AITaxiController.reverse_hold_steps 一起看。）
		if car_ref != null and is_instance_valid(car_ref):
			var la: Array[float] = car_ref._last_action
			if la.size() >= 3 and la[2] > 0.0:
				_debug_reverse_frames += 1
		if _debug_tick >= maxi(debug_interval, 1):
			#_debug_print()
			_debug_tick = 0
			_debug_accum.clear()
			_debug_reverse_frames = 0

	return reward


## 打印本区间内各奖励项的**平均每帧贡献**，便于直接对比量级。
func _debug_print() -> void:
	var n := float(maxi(debug_interval, 1))
	var parts: Array[String] = []
	var disabled: Array[String] = []
	var total := 0.0
	for rw in reward_funcs:
		if rw.enabled != true:
			disabled.append("%s(enabled=%s)" % [rw.name, str(rw.enabled)])
			continue
		var avg := float(_debug_accum.get(rw.name, 0.0)) / n
		total += avg
		parts.append("%s=%+.4f" % [rw.name, avg])
	# 把**运行时真正生效**的接送容差一起打出来。
	# 为什么值得多打这几个数：这些值由 AIParameter 在生成车辆时下发，面板改了、
	# 场景改了、忘了重启 Godot，日志里完全看不出来 —— 排查"为什么接不上客"时
	# 第一件要确认的就是它们，而这个信息此前只能靠人去猜场景有没有重新加载。
	var tol := "-"
	if car_ref != null and is_instance_valid(car_ref) and car_ref.taxi_service != null \
			and is_instance_valid(car_ref.taxi_service):
		var svc := car_ref.taxi_service
		tol = "容差:接%.1f/送%.1f/停%.1fm/s" % [
			float(svc.pickup_radius), float(svc.dropoff_radius), float(svc.stop_speed_threshold)]
	# 目标距离 / 车速 / 载客相位 / **跨 arena 泄漏检测**
	#
	#   d=-1.0m  ⟹ 这一帧**没有目标**（get_navigation_target() 返回 null）。
	#              传感器和奖励共用这条链路，所以"传感器不画线"和"d=-1.0"是同一件事。
	#   ⚠️跨场!  ⟹ 目标不在本车的场地里 = 又发生泄漏了。
	#              这个项目里"取到别的场地的目标"已经犯过好几次
	#              （PassengerManager / RivalSensor / TaxiService 都中过），
	#              而场地间距 150~300 m，泄漏时 d 会大得离谱。
	#              直接在日志里比对 arena，比事后靠人眼推理便宜得多。
	if car_ref != null and is_instance_valid(car_ref) and car_ref._vehicle != null \
			and is_instance_valid(car_ref._vehicle):
		var st: Dictionary = car_ref._vehicle.get_vehicle_state()
		var v_now := absf(float(st.get("forward_speed", 0.0)))
		var d_now := -1.0
		var phase := "空"
		var arena_tag := "arena?"
		var tgt: Node3D = null
		if car_ref.taxi_service != null and is_instance_valid(car_ref.taxi_service):
			if car_ref.taxi_service.has_passenger:
				phase = "载"
			tgt = car_ref.taxi_service.get_navigation_target()
		# 本场地乘客池状况：用来区分"真没乘客"（正常）和"有乘客却没锁定"（bug）
		var my_arena := TrainingArena.of(car_ref)
		if my_arena != null:
			# 打印**场地名**：多套变体场景（ParaFlatWallTrainScene 里一个 arena 一种布局）时，
			# 这是唯一能把每辆车对应回"哪一种布局"的办法 —— TB 里所有指标都是混在一起平均的，
			# 想知道"是哪个变体学不会"就只能靠这一列。
			arena_tag = String(my_arena.name)
			var mgr := my_arena.get_passenger_manager()
			if mgr != null:
				var es: Dictionary = mgr.get_env_stats()
				# 挂=场上活着的乘客数，等=其中还在等待的，空点=空闲生成点数。
				# "空 d=-1.0 挂1等1" = 有乘客却没锁定（真 bug）；
				# "空 d=-1.0 挂0等0 空点1" = 生成点空着、还没刷出来（正常的 ≤2s 空窗）；
				# "空 d=-1.0 挂1等0 空点0" = 唯一那位乘客正被本车拉着（不该出现，载客时 phase 应是"载"）。
				arena_tag += " 挂%s等%s/空点%s" % [
					str(es.get("passengers_alive", "?")),
					str(es.get("passengers_waiting", "?")),
					str(es.get("free_spawners", "?"))]
		if tgt != null and is_instance_valid(tgt):
			var a: Vector3 = car_ref._vehicle.global_transform.origin
			var b: Vector3 = tgt.global_position
			d_now = Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
			var tgt_arena := TrainingArena.of(tgt)
			if tgt_arena == null or my_arena == null:
				arena_tag = "arena?"
			elif my_arena != tgt_arena:
				arena_tag = "⚠️跨场!本场%s" % String(my_arena.name)
		tol += " | %s d=%.1fm v=%.1fm/s 倒车%.0f%% %s" % [
			phase, d_now, v_now, 100.0 * float(_debug_reverse_frames) / n, arena_tag]
	print("[Reward] %s | 每帧: %s | 合计=%+.4f | 禁用:[%s] | %s"
		% [name, " , ".join(parts), total, ", ".join(disabled), tol])


## 回合重置：调用各子 RewardFunction3D 的 reset()，清空其内部状态。
## 被禁用的项也调 reset —— 否则它下次被启用时会带着上一回合的陈旧基线。
#expose
func reset()->void:
	for rw in reward_funcs:
		rw.reset()
	_debug_tick = 0
	_debug_accum.clear()
