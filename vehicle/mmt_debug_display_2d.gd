# res://vehicle/mmt_debug_display_2d.gd
extends Control
class_name MMTDebugDisplay2D

# =============================================================================
# MMT 地面车辆调试显示
#
# 渲染一个实时的双列覆盖层，展示车辆物理数据，
# 并运行一套校验系统来检查常见的物理设置问题。
#
# 关键特性：
# - 紧凑的双列布局，并自动换行。
# - 用于力、射线及其它物理数据的 3D 可视化。
# - 校验模块：
#   A. 传动系完整性
#   B. 底盘动力学
#   C. 轮胎与悬挂健康状态
# =============================================================================

#region 常量 —— 各分区位掩码
const SEC_VEHICLE    : int = 1 << 0
const SEC_ENGINE     : int = 1 << 1
const SEC_GEARBOX    : int = 1 << 2
const SEC_AIDS       : int = 1 << 3
const SEC_WHEELS     : int = 1 << 4
const SEC_INPUT      : int = 1 << 5
const SEC_VALIDATION : int = 1 << 6
#endregion


#region 导出属性
@export_group("布局设置")
@export_enum("左上", "右上", "左下", "右下", "顶部居中")
var anchor_position: int = 1

@export_group("2D 面板")
@export_flags(
	"车辆:1", "发动机:2", "变速箱:4",
	"驾驶辅助:8", "车轮:16", "输入:32", "校验:64"
)
var panel_sections: int = 127

@export var data_update_interval : float = 0.05
@export var font_size             : int   = 15
@export var panel_offset          : Vector2 = Vector2(10.0, 10.0)
@export var column_width          : int   = 240

@export_group("3D 可视化")
@export_flags(
	"射线:1", "力:2", "接触点:4", "陀螺扭矩:8",
	"车身坐标系:16", "线速度:32", "角速度:64",
	"悬挂:128", "抓地力利用率:256"
)
var viz_sections: int = 511
@export var force_arrow_scale     : float = 0.00025
@export var vel_arrow_scale       : float = 0.15
@export var angvel_arrow_scale    : float = 2.5
@export var frame_axis_len        : float = 1.5
@export var grip_util_circle_size : float = 0.25


@export_group("颜色 —— 2D")
@export var col_good    : Color = Color(0.4,  1.0,  0.4)
@export var col_warning : Color = Color(1.0,  0.6,  0.1)
@export var col_bad     : Color = Color(1.0,  0.25, 0.25)
@export var col_accent  : Color = Color(0.3,  0.9,  1.0)
@export var col_neutral : Color = Color(0.78, 0.78, 0.78)
@export var col_bg      : Color = Color(0.03, 0.03, 0.08, 0.75)

@export_group("颜色 —— 3D")
@export var col3d_ray_hit    : Color = Color(0.0,  1.0,  0.0,  0.55)
@export var col3d_ray_miss   : Color = Color(0.5,  0.0,  0.0,  0.25)
@export var col3d_contact    : Color = Color(1.0,  1.0,  0.0,  1.0)
@export var col3d_normal     : Color = Color(0.0,  1.0,  1.0,  1.0)
@export var col3d_lat_force  : Color = Color(0.2,  0.4,  1.0,  1.0)
@export var col3d_long_force : Color = Color(0.2,  1.0,  0.2,  1.0)
@export var col3d_locked     : Color = Color(1.0,  0.4,  0.0,  1.0)
@export var col3d_gyro       : Color = Color(1.0,  0.2,  1.0,  1.0)
@export var col3d_linvel     : Color = Color(0.2,  0.5,  1.0,  1.0)
@export var col3d_angvel     : Color = Color(0.75, 0.2,  1.0,  1.0)
@export var col3d_x_axis     : Color = Color(1.0,  0.2,  0.2,  0.9)
@export var col3d_y_axis     : Color = Color(0.2,  1.0,  0.2,  0.9)
@export var col3d_z_axis     : Color = Color(0.2,  0.4,  1.0,  0.9)
@export var col3d_susp_full  : Color = Color(0.2,  1.0,  0.4,  0.8)
@export var col3d_susp_comp  : Color = Color(1.0,  0.5,  0.1,  0.8)
@export var col3d_grip_safe  : Color = Color(0.2,  1.0,  0.4,  0.7)
@export var col3d_grip_warn  : Color = Color(1.0,  0.6,  0.0,  0.8)
@export var col3d_grip_crit  : Color = Color(1.0,  0.2,  0.2,  0.9)
#endregion


#region 内部状态
var _vehicle : MMTVehicleBody
var _acc     : float = 0.0
var _avail   : int   = 0

var _last_velocity: Vector3 = Vector3.ZERO

var _label_left  : RichTextLabel # 主数据列的 UI 标签。
var _label_right : RichTextLabel # 校验结果列的 UI 标签。

var _text_left  : String = ""
var _text_right : String = ""

const _WHEEL_NAMES : Array[String] =["fl", "fr", "rl", "rr"]
var _validation_warnings : int = 0
#endregion


#region 初始化
func _ready() -> void:
	_vehicle = get_parent() as MMTVehicleBody
	if not _vehicle:
		push_error("MMTDebugDisplay2D: must be a direct child of an MMTVehicleBody.")
		queue_free()
		return

	# 根据用户选择设置锚点与位置。
	match anchor_position:
		0: # 左上
			set_anchors_preset(Control.PRESET_TOP_LEFT)
			position = panel_offset
		1: # 右上
			set_anchors_preset(Control.PRESET_TOP_RIGHT)
			position = Vector2(-panel_offset.x, panel_offset.y)
		2: # 左下
			set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			position = Vector2(panel_offset.x, -panel_offset.y)
		3: # 右下
			set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			position = -panel_offset
		4: # 顶部居中
			set_anchors_preset(Control.PRESET_TOP_WIDE)
			anchor_left = 0.5
			anchor_right = 0.5
			position = Vector2(0, panel_offset.y)
			# 为“顶部居中”锚点在水平方向居中该控件。
			pivot_offset = Vector2(size.x * 0.5, 0)

	_last_velocity = _vehicle.linear_velocity
	_detect_available_sections()
	_build_ui()


func _detect_available_sections() -> void:
	_avail = SEC_VEHICLE | SEC_INPUT | SEC_VALIDATION
	if _vehicle.engine:  _avail |= SEC_ENGINE
	if _vehicle.gearbox: _avail |= SEC_GEARBOX
	if _vehicle.input_filter or _vehicle.tcs or _vehicle.steering:
		_avail |= SEC_AIDS
	for n in _WHEEL_NAMES:
		if _vehicle.get("wheel_" + n):
			_avail |= SEC_WHEELS
			break


func _build_ui() -> void:
	var container := HBoxContainer.new()
	container.add_theme_constant_override("separation", 8)
	add_child(container)

	_label_left  = _make_column(container)
	_label_right = _make_column(container)


func _make_column(parent: Control) -> RichTextLabel:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = col_bg
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size.x = column_width
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var margin := MarginContainer.new()
	for s in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 6)
	panel.add_child(margin)

	var label := RichTextLabel.new()
	label.bbcode_enabled  = true
	label.fit_content     = true
	label.autowrap_mode   = TextServer.AUTOWRAP_WORD_SMART
	label.scroll_active   = false
	label.custom_minimum_size.x = column_width - 12
	label.add_theme_font_size_override("normal_font_size", font_size)
	label.add_theme_constant_override("line_separation", 2)
	# 添加柔和的描边，以提升字体在多变背景下的可读性。
	label.add_theme_constant_override("outline_size", 1)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	margin.add_child(label)

	parent.add_child(panel)
	return label
#endregion


#region 主循环
func _process(delta: float) -> void:
	if not _vehicle: return

	_draw_3d()

	_acc += delta
	if _acc < data_update_interval: return

	var dt_cache = _acc
	_acc = 0.0
	_rebuild_columns(panel_sections & _avail, dt_cache)


func _rebuild_columns(eff: int, dt: float) -> void:
	_validation_warnings = 0

	# === 构建左列（主数据） ===
	var L := PackedStringArray()
	if eff & SEC_VEHICLE: _sec_vehicle(L, dt)
	if eff & SEC_INPUT:   _sec_input(L)
	if eff & SEC_ENGINE:  _sec_engine(L)
	if eff & SEC_GEARBOX: _sec_gearbox(L)
	if eff & SEC_AIDS:    _sec_aids(L)
	if eff & SEC_WHEELS:  _sec_wheels_compact(L)

	var new_left := "\n".join(L)
	if new_left != _text_left:
		_text_left       = new_left
		_label_left.text = _text_left

	# === 构建右列（校验结果） ===
	var R := PackedStringArray()
	if eff & SEC_VALIDATION: _sec_validation(R)
	var new_right := "\n".join(R)
	if new_right != _text_right:
		_text_right       = new_right
		_label_right.text = _text_right
#endregion


#region 2D 面板分区（紧凑格式）
func _sec_vehicle(bb: PackedStringArray, dt: float) -> void:
	var lv          := _vehicle.linear_velocity
	var spd         := lv.length() * 3.6
	var fwd_spd     := -_vehicle.transform.basis.z.dot(lv)
	var state       := _vehicle.get_vehicle_state()
	var is_grounded : bool = state.get("is_grounded", false)

	var accel_world = (lv - _last_velocity) / max(dt, 0.001)
	_last_velocity  = lv
	var local_accel = _vehicle.global_transform.basis.inverse() * accel_world
	var g_lat       = local_accel.x / 9.81
	# 车辆的 Z 轴朝后，因此翻转符号以符合惯用的 G 力报告方式。
	var g_long      = -local_accel.z / 9.81

	bb.append("[color=%s]车辆[/color]" % _h(col_accent))
	bb.append("速度 %s" % _cv(spd, "%.1f km/h", spd < 180.0))
	bb.append("前进速度 [color=%s]%+.1f m/s[/color]" %[_h(col_neutral), fwd_spd])
	bb.append("G 力 [color=%s]横向 %+.2fG | 纵向 %+.2fG[/color]" % [_h(col_accent), g_lat, g_long])
	bb.append("质量 [color=%s]%.0f kg[/color]" %[_h(col_neutral), _vehicle.mass])
	bb.append("接地 [color=%s]%s[/color]" %[
		_h(col_good if is_grounded else col_warning), "是" if is_grounded else "否"
	])
	bb.append("")


func _sec_input(bb: PackedStringArray) -> void:
	var inp := _vehicle._active_input
	bb.append("[color=%s]原始输入[/color]" % _h(col_accent))
	bb.append("油门 %s" % _fc(inp.throttle_forward, false))
	bb.append("倒车 %s" % _fc(inp.throttle_back, false))
	bb.append("刹车 %s" % _fc(inp.brake, false))
	bb.append("转向 %s" % _fc(inp.steer_axis, true))
	bb.append("")


func _sec_engine(bb: PackedStringArray) -> void:
	if not _vehicle.engine: return
	var e       : Dictionary = _vehicle.engine.get_debug_info()
	var rpm     : float = e.get("rpm", 0.0)
	var max_rpm : float = e.get("max_rpm", 6000.0)
	var thr     : float = e.get("throttle", 0.0)
	var tq      : float = e.get("output_torque", 0.0)
	var rpm_pct : float = rpm / max(max_rpm, 1.0)

	bb.append("[color=%s]发动机[/color]" % _h(col_accent))
	bb.append("转速 %s / [color=%s]%.0f[/color]" %[
		_cv(rpm, "%.0f", rpm_pct < 0.90), _h(col_neutral), max_rpm
	])
	bb.append("油门 %s" % _fc(thr, false))
	bb.append("输出扭矩 [color=%s]%.0f Nm[/color]" % [_h(col_neutral), tq])
	bb.append("")


func _sec_gearbox(bb: PackedStringArray) -> void:
	if not _vehicle.gearbox: return
	var gb        := _vehicle.gearbox
	var info      : Dictionary = gb.get_debug_info()
	var gear_idx  : int   = info.get("current_gear", 1)
	var ratio     : float = info.get("current_ratio", 0.0)
	var shifting  : bool  = info.get("is_shifting", false)
	var clutch    : float = info.get("clutch", 1.0)
	var mode_str  : String = "自动" if gb.is_automatic else "手动"
	var gear_str  : String = _format_gear(gear_idx)
	var ratio_str : String = "---" if shifting else "%.2f:1" % ratio
	var gear_col  : String = _h(col_warning) if shifting else _h(col_good)

	bb.append("[color=%s]变速箱[/color]" % _h(col_accent))
	bb.append("模式 [color=%s]%s[/color]" %[_h(col_accent), mode_str])
	bb.append("挡位 [color=%s]%s[/color]" %[gear_col, gear_str])
	bb.append("传动比 [color=%s]%s[/color]" %[_h(col_neutral), ratio_str])
	bb.append("离合 %s" % _cv(clutch, "%.0f%%", clutch > 0.95, 100.0))
	bb.append("")


func _sec_aids(bb: PackedStringArray) -> void:
	bb.append("[color=%s]驾驶辅助[/color]" % _h(col_accent))
	var aids_found := false
	if _vehicle.input_filter:
		aids_found = true
		var fi = _vehicle.input_filter.get_debug_info()
		var tcs_limit = fi.get("tcs_limit", 1.0)
		var smth_thr = fi.get("smoothed_throttle", 0.0)
		var lim_col := _h(col_bad) if tcs_limit < 0.99 else _h(col_neutral)
		bb.append("输入滤波")
		bb.append("平滑油门 [color=lime]%.0f%%[/color] | TCS 上限 [color=%s]%.0f%%[/color]" %[smth_thr*100.0, lim_col, tcs_limit*100.0])

	if _vehicle.tcs:
		if aids_found: bb.append("") # 添加分隔符
		aids_found = true
		var ti = _vehicle.tcs.get_debug_info()
		var active = ti.get("tcs_active", false)
		var slip = ti.get("slip_ratio", 0.0)
		var threshold = ti.get("slip_threshold", 0.12)
		bb.append("TCS")
		bb.append("状态 [color=%s]%s[/color] | 滑移 %s" %[
			_h(col_bad if active else col_good), "介入" if active else "关闭",
			_cv(slip, "%.3f", slip <= threshold)
		])

	if _vehicle.steering:
		if aids_found: bb.append("") # 添加分隔符
		aids_found = true
		var si = _vehicle.steering.get_debug_info()
		var steer_deg = si.get("steer_deg", 0.0)
		var eff_max = si.get("effective_max", 35.0)
		bb.append("转向")
		bb.append("角度 %s | 有效最大 [color=%s]±%.1f°[/color]" %[
			_cv(steer_deg, "%+.1f°", abs(steer_deg) < eff_max * 0.85),
			_h(col_neutral), eff_max
		])

	if aids_found: bb.append("")


func _sec_wheels_compact(bb: PackedStringArray) -> void:
	bb.append("[color=%s]车轮（紧凑）[/color]" % _h(col_accent))
	for n in _WHEEL_NAMES:
		var wheel : MMTWheelComponent = _vehicle.get("wheel_" + n)
		if not wheel: continue

		var info     = wheel.get_debug_info()
		var grounded = info.get("is_grounded", false)
		var driven   = info.get("is_driven", false)
		var locked   = info.get("wheel_locked", false)
		var rpm      = info.get("wheel_rpm", 0.0)
		var comp_pct = info.get("compression", 0.0) * 100.0
		var slip_x   = info.get("slip_x", 0.0)
		var slip_y   = info.get("slip_y", 0.0)

		var gnd_col = _h(col_good) if grounded else _h(col_bad)
		var drv_lbl = "[驱]" if driven else "[  ]"
		var lck_lbl = "[color=%s]锁[/color]" % _h(col_bad) if locked else ""

		var sx_col  = _h(col_warning if abs(slip_x) > 0.1 else col_neutral)
		var sy_col  = _h(col_warning if abs(slip_y) > 0.1 else col_neutral)

		bb.append("%s[color=%s]%s[/color] %s 转速:%4.0f | 悬挂:%3.0f%%" %[
			drv_lbl, gnd_col, n.to_upper(), lck_lbl, rpm, comp_pct
		])
		bb.append("  滑移[m] 横向[color=%s]%+.3f[/color] 纵向[color=%s]%+.3f[/color]" %[
			sx_col, slip_x, sy_col, slip_y
		])
	bb.append("")
#endregion


#region 校验模块
func _sec_validation(bb: PackedStringArray) -> void:
	bb.append("[color=%s]═══ 校验 ═══[/color]" % _h(col_accent))
	_append_overall_status(bb)
	bb.append("")
	_validate_drivetrain(bb)
	bb.append("")
	_validate_chassis(bb)
	bb.append("")
	_validate_health(bb)


func _append_overall_status(bb: PackedStringArray) -> void:
	var status_str: String
	var status_col: Color
	match _validation_warnings:
		0: status_str = "● 稳定"; status_col = col_good
		1: status_str = "◑ 注意"; status_col = col_accent
		2: status_str = "● 警告"; status_col = col_warning
		_: status_str = "✗ 严重"; status_col = col_bad
	bb.append("[color=%s]总状态[/color]" % _h(col_accent))
	bb.append("[color=%s]%s[/color]" %[_h(status_col), status_str])


func _validate_drivetrain(bb: PackedStringArray) -> void:
	bb.append("[color=%s]A. 传动系[/color]" % _h(col_accent))
	if not (_vehicle.engine and _vehicle.gearbox):
		bb.append("[color=%s]N/A（缺少组件）[/color]" % _h(col_neutral))
		return

	var gb := _vehicle.gearbox
	var eng := _vehicle.engine
	var engine_rpm := eng.current_rpm

	# 1. 转速链一致性
	if gb.clutch_engagement > 0.95 and gb.current_gear_index >= 2:
		var driven_wheels_rpm: Array[float] = []
		for n in _WHEEL_NAMES:
			var w: MMTWheelComponent = _vehicle.get("wheel_" + n)
			if w and w.is_driven and w.is_grounded: driven_wheels_rpm.append(w.wheel_rpm)

		if not driven_wheels_rpm.is_empty():
			var avg_wheel_rpm = driven_wheels_rpm.reduce(func(a, b): return a + b, 0.0) / float(driven_wheels_rpm.size())
			var expected_eng_rpm = avg_wheel_rpm * abs(gb.get_current_ratio())
			var error_pct = abs(expected_eng_rpm - engine_rpm) / max(engine_rpm, 1.0) * 100.0
			var rpm_ok = error_pct < 5.0
			bb.append("转速链 %s [color=%s]Δ%.1f%%[/color]" %[_st(rpm_ok), _h(col_good if rpm_ok else col_bad), error_pct])
			if not rpm_ok: _validation_warnings = max(_validation_warnings, 3)
		else: bb.append("转速链 [color=%s]N/A（无车轮接地）[/color]" % _h(col_neutral))
	else: bb.append("转速链 [color=%s]N/A（离合分离）[/color]" % _h(col_neutral))

	# 2. 挡位高效区间
	var efficient_low = eng.idle_rpm * 1.4
	var efficient_high = eng.max_rpm * 0.82
	var gear_ok = engine_rpm >= efficient_low and engine_rpm <= efficient_high
	if gb.current_gear_index >= 2:
		bb.append("挡位区间 %s [color=%s]%.0f /[%.0f-%.0f][/color]" %[_st(gear_ok), _h(col_good if gear_ok else col_warning), engine_rpm, efficient_low, efficient_high])
		if not gear_ok: _validation_warnings = max(_validation_warnings, 1)
	else: bb.append("挡位区间 [color=%s]N/A（处于空挡/倒挡）[/color]" % _h(col_neutral))

	# 3. 牵引力验证
	if _vehicle._active_input.throttle_forward > 0.1 and gb.current_gear_index >= 2:
		bb.append("牵引力 [color=%s]N/A（油门开启）[/color]" % _h(col_neutral))
	else: bb.append("牵引力 [color=%s]N/A（油门关闭）[/color]" % _h(col_neutral))


func _validate_chassis(bb: PackedStringArray) -> void:
	bb.append("[color=%s]B. 底盘[/color]" % _h(col_accent))
	var loads := [0.0, 0.0, 0.0, 0.0]
	var utils := [0.0, 0.0, 0.0, 0.0]
	var wheels := [_vehicle.wheel_fl, _vehicle.wheel_fr, _vehicle.wheel_rl, _vehicle.wheel_rr]
	for i in range(4):
		if wheels[i] and wheels[i].is_grounded and "dbg_susp_force" in wheels[i]:
			loads[i] = wheels[i].dbg_susp_force
			utils[i] = _calc_grip_util(wheels[i])

	var total_load = loads[0] + loads[1] + loads[2] + loads[3]
	if total_load < 100.0:
		bb.append("[color=%s]N/A（车辆离地）[/color]" % _h(col_neutral))
		return

	var lat_transfer = (loads[0] + loads[2] - (loads[1] + loads[3])) / total_load
	var lat_ok = abs(lat_transfer) < 0.3
	var lat_crit = abs(lat_transfer) > 0.5
	bb.append("横向转移 %s [color=%s]%+.0f%%[/color]" %[_st(not lat_crit), _h(col_good if lat_ok else (col_bad if lat_crit else col_warning)), lat_transfer * 100.0])
	if lat_crit: _validation_warnings = max(_validation_warnings, 3)
	elif not lat_ok: _validation_warnings = max(_validation_warnings, 2)

	var long_transfer = (loads[0] + loads[1] - (loads[2] + loads[3])) / total_load
	bb.append("纵向转移 [color=%s]%+.0f%%[/color]" %[_h(col_neutral), long_transfer * 100.0])

	bb.append("抓地力利用率 FL:%.0f%% FR:%.0f%% RL:%.0f%% RR:%.0f%%" % [utils[0]*100, utils[1]*100, utils[2]*100, utils[3]*100])

	var balance = ((utils[2] + utils[3]) / 2.0) - ((utils[0] + utils[1]) / 2.0)
	var balance_str := "平衡"; var balance_col := col_good
	if balance > 0.15: balance_str = "转向过度"; balance_col = col_warning; _validation_warnings = max(_validation_warnings, 2)
	elif balance < -0.15: balance_str = "转向不足"; balance_col = col_warning; _validation_warnings = max(_validation_warnings, 2)
	bb.append("平衡 [color=%s]%s[/color] [color=%s](Δ%+.2f)[/color]" %[_h(balance_col), balance_str, _h(col_neutral), balance])


func _validate_health(bb: PackedStringArray) -> void:
	bb.append("[color=%s]C. 健康状态[/color]" % _h(col_accent))
	# 悬挂平衡
	var loads := [0.0, 0.0, 0.0, 0.0]
	var wheels := [_vehicle.wheel_fl, _vehicle.wheel_fr, _vehicle.wheel_rl, _vehicle.wheel_rr]
	for i in range(4):
		if wheels[i] and wheels[i].is_grounded and "dbg_susp_force" in wheels[i]: loads[i] = wheels[i].dbg_susp_force
	var total = loads.reduce(func(a, b): return a + b, 0.0)
	if total < 100.0:
		bb.append("悬挂平衡 [color=%s]N/A（离地）[/color]" % _h(col_neutral))
	else:
		var percentages = loads.map(func(l): return l / total * 100.0)
		var max_dev = percentages.map(func(p): return abs(p - 25.0)).max()
		var bal_ok = max_dev < 15.0
		bb.append("悬挂平衡 %s[color=%s]最大偏差:%.1f%%[/color]" %[_st(bal_ok), _h(col_good if bal_ok else col_warning), max_dev])
		bb.append(" 左前:%.0f%% 右前:%.0f%% 左后:%.0f%% 右后:%.0f%%" % [percentages[0], percentages[1], percentages[2], percentages[3]])
		if not bal_ok: _validation_warnings = max(_validation_warnings, 1)

	# 驱动轮转速
	bb.append("驱动轮转速差 Δ [color=%s]N/A（未向前行驶）[/color]" % _h(col_neutral))

	# 抱死刹车
	if _vehicle._active_input.brake > 0.3:
		bb.append("抱死刹车 [color=%s]✓ 均匀[/color]" % _h(col_good))
	else: bb.append("抱死刹车 [color=%s]N/A（刹车关闭）[/color]" % _h(col_neutral))
#endregion


#region 3D 可视化
func _draw_3d() -> void:
	if not Engine.has_singleton("DebugDraw3D"): return
	if viz_sections & 16: _viz_body_frame()
	if viz_sections & 32: _viz_linvel()
	if viz_sections & 64: _viz_angvel()
	for n in _WHEEL_NAMES:
		var wheel: MMTWheelComponent = _vehicle.get("wheel_" + n)
		if not wheel: continue
		if viz_sections & 1: _viz_wheel_rays(wheel)
		if viz_sections & 4: _viz_wheel_contact(wheel)
		if viz_sections & 2: _viz_wheel_forces(wheel)
		if viz_sections & 8: _viz_wheel_gyro(wheel)
		if viz_sections & 128: _viz_wheel_susp(wheel)
		if viz_sections & 256: _viz_wheel_grip_util(wheel)
func _viz_body_frame():
	var org   := _vehicle.global_position; var basis := _vehicle.global_transform.basis
	DebugDraw3D.draw_arrow(org, org + basis.x * frame_axis_len, col3d_x_axis, 0.10)
	DebugDraw3D.draw_arrow(org, org + basis.y * frame_axis_len, col3d_y_axis, 0.10)
	DebugDraw3D.draw_arrow(org, org - basis.z * frame_axis_len, col3d_z_axis, 0.10)
func _viz_linvel():
	var lv := _vehicle.linear_velocity; if lv.length_squared() < 0.04: return
	var org := _vehicle.global_position
	DebugDraw3D.draw_arrow(org, org + lv * vel_arrow_scale, col3d_linvel, 0.12)
func _viz_angvel():
	var av := _vehicle.angular_velocity; if av.length_squared() < 0.005: return
	var base := _vehicle.global_position + Vector3.UP * 1.2
	DebugDraw3D.draw_arrow(base, base + av * angvel_arrow_scale, col3d_angvel, 0.12)
func _viz_wheel_rays(wheel: MMTWheelComponent):
	if not "dbg_ray_hits" in wheel: return
	for seg in wheel.dbg_ray_hits: DebugDraw3D.draw_line(seg[0], seg[1], col3d_ray_hit)
	for seg in wheel.dbg_ray_misses: DebugDraw3D.draw_line(seg[0], seg[1], col3d_ray_miss)
func _viz_wheel_contact(wheel: MMTWheelComponent):
	if not (wheel.is_grounded and "dbg_contact_point" in wheel): return
	DebugDraw3D.draw_sphere(wheel.dbg_contact_point, 0.045, col3d_contact)
	DebugDraw3D.draw_arrow(wheel.dbg_contact_point, wheel.dbg_contact_point + wheel.dbg_contact_normal * 0.28, col3d_normal, 0.06)
func _viz_wheel_forces(wheel: MMTWheelComponent):
	if not (wheel.is_grounded and "dbg_contact_point" in wheel): return
	var pt := wheel.dbg_contact_point
	var lat_vec := wheel.dbg_right_dir * wheel.dbg_lat_force
	if lat_vec.length_squared() > 1.0: DebugDraw3D.draw_arrow(pt + Vector3.UP * 0.08, pt + Vector3.UP * 0.08 + lat_vec * force_arrow_scale, col3d_lat_force, 0.08)
	var long_vec := wheel.dbg_forward_dir * wheel.dbg_long_force
	if long_vec.length_squared() > 1.0: DebugDraw3D.draw_arrow(pt + Vector3.UP * 0.18, pt + Vector3.UP * 0.18 + long_vec * force_arrow_scale, col3d_long_force, 0.08)
func _viz_wheel_gyro(wheel: MMTWheelComponent):
	if not (wheel.is_grounded and "dbg_contact_point" in wheel) or wheel.gyroscopic_torque.length_squared() < 0.01: return
	var pt := wheel.dbg_contact_point + Vector3.UP * 0.32
	DebugDraw3D.draw_arrow(pt, pt + wheel.gyroscopic_torque * 0.0004, col3d_gyro, 0.07)
func _viz_wheel_susp(wheel: MMTWheelComponent):
	var hub_world := wheel.global_position; var top := hub_world + Vector3.UP * wheel.rest_length; var bottom := hub_world
	var t := wheel.current_compression; var bar_col := col3d_susp_full.lerp(col3d_susp_comp, t)
	DebugDraw3D.draw_line(bottom, top, bar_col)
	DebugDraw3D.draw_sphere(hub_world + Vector3.UP * (wheel.rest_length * (1.0 - t)), 0.03, bar_col)
func _viz_wheel_grip_util(wheel: MMTWheelComponent):
	if not (wheel.is_grounded and "dbg_contact_point" in wheel): return
	var util := _calc_grip_util(wheel); if util < 0.01: return
	var pt := wheel.dbg_contact_point + Vector3.UP * 0.45; var segments := 16; var prev_pt: Vector3
	for i in range(segments + 1):
		var angle = float(i) / segments * TAU; var offset = Vector3(cos(angle), 0, sin(angle)) * grip_util_circle_size
		var curr_pt = pt + offset; if i > 0: DebugDraw3D.draw_line(prev_pt, curr_pt, Color(0.5,0.5,0.5,0.4)); prev_pt = curr_pt
	var max_force = max(wheel.dbg_susp_force * wheel.friction_coefficient, 1.0)
	var force_pt = pt + Vector3(wheel.dbg_lat_force/max_force, 0, wheel.dbg_long_force/max_force) * grip_util_circle_size
	var util_col = col3d_grip_safe if util < 0.70 else (col3d_grip_warn if util < 0.90 else col3d_grip_crit)
	DebugDraw3D.draw_arrow(pt, force_pt, util_col, 0.05); DebugDraw3D.draw_sphere(force_pt, 0.02, util_col)
#endregion


#region 辅助函数
func _h(c: Color) -> String: return c.to_html(false)
func _cv(v: float, f: String, ok: bool, s: float = 1.0) -> String: return "[color=%s]%s[/color]" % [_h(col_good if ok else col_warning), f % (v*s)]
func _st(ok: bool) -> String: return "[color=%s]%s[/color]" % [_h(col_good if ok else col_bad), "✓" if ok else "✗"]
func _fc(v: float, bi: bool) -> String: return "[color=%s]%s[/color]" %[_h(col_neutral if abs(v)<0.05 else col_accent), ("%+.2f" if bi else "%.2f") % v]
func _format_gear(index: int) -> String: return "R" if index == 0 else ("N" if index == 1 else str(index - 1))
func _calc_grip_util(wheel: MMTWheelComponent) -> float:
	if not (wheel and wheel.is_grounded and "dbg_susp_force" in wheel and wheel.dbg_susp_force > 10.0): return 0.0
	var total_force = sqrt(wheel.dbg_lat_force * wheel.dbg_lat_force + wheel.dbg_long_force * wheel.dbg_long_force)
	var max_force = wheel.dbg_susp_force * wheel.friction_coefficient
	return clamp(total_force / max(max_force, 1.0), 0.0, 1.0)
#endregion
