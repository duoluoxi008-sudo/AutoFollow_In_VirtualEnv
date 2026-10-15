# res://vehicle/mmt_sedan.gd
extends RigidBody3D
class_name MMTVehicleBody

@export_category("车辆特性")
@export var auto_hold:   bool = true

@export_category("传动系连接")
@export var engine:      MMTEngineComponentTEMP
@export var gearbox:     MMTGearboxComponentTEMP

@export_category("驾驶辅助")
@export var input_filter: MMTInputFilterComponent
@export var tcs:          MMTTCSComponent
@export var steering:     MMTSteeringComponent

@export_category("车轮引用")
@export var wheel_fl:    MMTWheelComponent
@export var wheel_fr:    MMTWheelComponent
@export var wheel_rl:    MMTWheelComponent
@export var wheel_rr:    MMTWheelComponent

@export_category("车辆规格")
@export var wheelbase:          float = 2.6
@export var track_width:        float = 1.42
@export var brake_bias_front:   float = 0.7
@export_range(0.0, 1.0) var ackermann_factor: float = 0.5

@export_category("空气动力学")
@export var frontal_area:       float = 2.2
@export var drag_coefficient:   float = 0.35
@export var air_density:        float = 1.225

@export_category("稳定性辅助")
@export var yaw_damping_coefficient: float = 300.0
@export var yaw_damping_min_speed:   float = 3.0

# --- 内部状态 ---
var _force_components: Array[MMTForceComponentTEMP] = []

# 活动的输入状态，由控制器通过 set_controller_input() 注入。
# 默认使用一个新建的、全零的实例，以确保在没有控制器时车辆能安全地保持静止。
var _active_input: MMTVehicleInputState = MMTVehicleInputState.new()

# --- 发动机与初始化 ---
func _ready() -> void:
	linear_damp_mode  = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp       = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp      = 0.0

	if physics_material_override == null:
		physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = 0.0

	_register_components(self)

func _register_components(node: Node) -> void:
	for child in node.get_children():
		if child is MMTForceComponentTEMP:
			_force_components.append(child)
		_register_components(child)

# --- 面向控制器的公共接口 ---

# 由控制器（例如 MMTBaseController.possess）调用，用来注入共享的输入状态对象。
# 控制器向该对象写入数据，车辆则在每个物理帧从中读取，从而避免额外的信号或函数调用。
func set_controller_input(input_state: MMTVehicleInputState) -> void:
	_active_input = input_state

# 读取当前共享的输入状态对象。
# 供 VehicleStateResetter 之类的通用组件复位输入（AI 控制器与玩家控制器注入的是
# 同一个对象，所以组件不需要知道"现在是谁在开车"）。
func get_active_input() -> MMTVehicleInputState:
	return _active_input

# 暴露车辆的运行时状态，供 AI 控制器或 HUD 使用。
func get_vehicle_state() -> Dictionary:
	return {
		"forward_speed": -transform.basis.z.dot(linear_velocity),
		"speed_kmh":     linear_velocity.length() * 3.6,
		"engine_rpm":    engine.current_rpm if engine else 0.0,
		"gear_index":    gearbox.current_gear_index if gearbox else 0,
		"is_grounded":   _any_wheel_grounded(),
	}

func _any_wheel_grounded() -> bool:
	for w in [wheel_fl, wheel_fr, wheel_rl, wheel_rr]:
		if w and w.is_grounded:
			return true
	return false

# --- 物理主循环 ---
# 本函数只从 _active_input 读取数据，不调用任何 Input.* 方法。
#expose
func _physics_process(delta: float) -> void:
	var inp := _active_input

	# --- 1. 处理脉冲事件（换挡） ---
	if gearbox:
		if inp.shift_up_pulse:          gearbox.shift_up()
		if inp.shift_down_pulse:        gearbox.shift_down()
		if inp.toggle_auto_shift_pulse:
			gearbox.is_automatic = not gearbox.is_automatic
	# 脉冲必须被消费，以免在下帧被再次触发。
	inp.consume_pulses()

	var forward_speed = -transform.basis.z.dot(linear_velocity)

	# --- 2. 智能刹车/倒车逻辑 ---
	# 本段决定油门输入应当加速、刹车还是倒车。
	var raw_throttle_intent: float = 0.0
	var raw_brake_intent:    float = inp.brake

	if gearbox and gearbox.is_automatic and gearbox.auto_reverse:
		if inp.throttle_forward > 0:
			# 若车辆正在向后移动，“向前油门”输入此时作为刹车。
			if forward_speed < -0.2:
				raw_brake_intent = max(raw_brake_intent, inp.throttle_forward)
			else:
				raw_throttle_intent = inp.throttle_forward
		elif inp.throttle_back > 0:
			# 若车辆正在向前移动，“向后油门”输入此时作为刹车。
			if forward_speed > 0.05:
				raw_brake_intent = max(raw_brake_intent, inp.throttle_back)
			else:
				# 若车辆静止或正在向后移动，“向后油门”输入进入倒挡。
				raw_throttle_intent = -inp.throttle_back
		else:
			# 自动驻车：在极低车速时施加刹车以防止溜车。
			if auto_hold and abs(forward_speed) < 0.5:
				raw_brake_intent = 1.0
	else:
		# 手动挡或非倒车自动挡的逻辑。
		raw_throttle_intent = inp.throttle_forward
		raw_brake_intent    = max(inp.brake, inp.throttle_back)
		if auto_hold and inp.throttle_forward == 0 and inp.throttle_back == 0 \
				and abs(forward_speed) < 0.5:
			raw_brake_intent = 1.0

	# --- 3. 输入滤波与牵引力控制系统（TCS） ---
	if tcs:
		tcs.process_tcs(delta)

	var final_throttle: float
	var final_brake:    float

	if input_filter:
		input_filter.process_input(abs(raw_throttle_intent), raw_brake_intent, delta)
		final_throttle = input_filter.smoothed_throttle * sign(raw_throttle_intent)
		final_brake    = input_filter.smoothed_brake
	else:
		final_throttle = raw_throttle_intent
		final_brake    = raw_brake_intent

	# --- 4. 转向平滑 ---
	if steering:
		steering.process_steering(inp.steer_axis, forward_speed, delta)

	var final_steer_rad: float = steering.current_steer_rad \
		if steering else inp.steer_axis * deg_to_rad(35.0)

	# --- 5. Ackermann 转向计算 ---
	# 为内外侧车轮计算不同的转角，以在转弯时最小化轮胎刮擦。
	if abs(final_steer_rad) < 0.0001:
		if wheel_fl: wheel_fl.steer_angle = 0.0
		if wheel_fr: wheel_fr.steer_angle = 0.0
	else:
		var abs_rad    = abs(final_steer_rad)
		var steer_sign = sign(final_steer_rad)
		var turn_radius    = wheelbase / max(tan(abs_rad), 0.0001)
		var half_track_ack = (track_width / 2.0) * ackermann_factor
		var angle_inner    = atan(wheelbase / (turn_radius - half_track_ack))
		var angle_outer    = atan(wheelbase / (turn_radius + half_track_ack))

		if steer_sign > 0: # 右转
			if wheel_fl: wheel_fl.steer_angle =  angle_inner
			if wheel_fr: wheel_fr.steer_angle =  angle_outer
		else: # 左转
			if wheel_fl: wheel_fl.steer_angle = -angle_outer
			if wheel_fr: wheel_fr.steer_angle = -angle_inner

	# --- 6. 分配刹车扭矩 ---
	if wheel_fl: wheel_fl.brake_input = final_brake * brake_bias_front
	if wheel_fr: wheel_fr.brake_input = final_brake * brake_bias_front
	if wheel_rl: wheel_rl.brake_input = final_brake * (1.0 - brake_bias_front)
	if wheel_rr: wheel_rr.brake_input = final_brake * (1.0 - brake_bias_front)

	# --- 7. 传动系仿真 ---
	if engine:
		engine.throttle = abs(final_throttle)
	if gearbox:
		gearbox.update_shift_logic(engine.current_rpm, final_throttle, forward_speed, delta)
	if engine:
		engine.process_drivetrain(delta)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# 对所有已注册的 MMTForceComponentTEMP 节点施加力。
	for comp in _force_components:
		comp.apply_custom_forces(state, state.step)

	# 施加来自所有车轮的陀螺扭矩。
	var total_gyro_torque = Vector3.ZERO
	for wheel in [wheel_fl, wheel_fr, wheel_rl, wheel_rr]:
		if wheel:
			total_gyro_torque += wheel.gyroscopic_torque
	if total_gyro_torque.length_squared() > 0.001:
		state.apply_torque(total_gyro_torque)

	# 施加空气阻力。
	var velocity = state.linear_velocity
	var speed_sq = velocity.length_squared()
	if speed_sq > 0.5:
		var aero_coeff      = 0.5 * air_density * drag_coefficient * frontal_area
		var aero_drag_force = -velocity.normalized() * (aero_coeff * speed_sq)
		state.apply_central_force(aero_drag_force)

	# 施加横摆阻尼以保证高速稳定性。
	var forward_speed_abs = abs(-state.transform.basis.z.dot(velocity))
	if forward_speed_abs > yaw_damping_min_speed:
		var speed_factor  = clamp((forward_speed_abs - yaw_damping_min_speed) / 27.0, 0.0, 1.0)
		var yaw_axis      = state.transform.basis.y
		var yaw_rate      = state.angular_velocity.dot(yaw_axis)
		var yaw_damp_torq = -yaw_axis * yaw_rate * yaw_damping_coefficient * speed_factor
		state.apply_torque(yaw_damp_torq)
