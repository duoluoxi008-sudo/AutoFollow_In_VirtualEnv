# res://vehicle/mmt_wheel_component.gd
extends MMTForceComponentTEMP
class_name MMTWheelComponent

@export_category("刹车")
@export var max_brake_torque: float = 1200.0

@export_category("碰撞体（射线网格）")
@export var wheel_width:           float = 0.185
@export var wheel_radius:          float = 0.28
@export_range(1, 10)    var lat_ray_count:     int   = 3
@export_range(1, 15)    var long_ray_count:    int   = 5
@export_range(0.1, 1.0) var long_ray_coverage: float = 0.85

@export_category("悬挂")
@export var rest_length:      float = 0.45
@export var spring_stiffness: float = 22000.0
@export var damping:          float = 1900.0

@export_category("悬挂运动学")
@export_range(0.0, 1.0) var anti_dive_factor:       float = 0.2
@export var longitudinal_force_leverage:             float = 0.1

@export_category("轮胎摩擦（刷毛模型）")
@export var tire_lat_stiffness:   float = 120000.0
@export var tire_long_stiffness:  float = 120000.0
@export var relaxation_length:    float = 0.15
@export var friction_coefficient: float = 0.95
@export var is_driven:            bool  = false

@export_category("物理设置")
@export_flags_3d_physics var ground_collision_mask: int = 1
@export var wheel_inertia: float = 1.2

# --- 外部输入 ---
var arb_force:   float = 0.0
var steer_angle: float = 0.0
var brake_input: float = 0.0

# --- 运行时状态（只读） ---
var current_compression: float   = 0.0
var is_grounded:         bool    = false
var wheel_rpm:           float   = 0.0
var spin_vel:            float   = 0.0
var load_torque:         float   = 0.0
var wheel_long_vel:      float   = 0.0
var drive_torque:        float   = 0.0
var drivetrain_inertia:  float   = 0.0
var parent_body:         RigidBody3D
var gyroscopic_torque:   Vector3 = Vector3.ZERO

# --- 调试状态（每物理帧写入，由 MMTDebugDisplay2D 读取） ---
var dbg_ray_hits:      Array   = []
var dbg_ray_misses:    Array   = []
var dbg_contact_point:  Vector3 = Vector3.ZERO
var dbg_contact_normal: Vector3 = Vector3.UP
var dbg_lat_force:      float   = 0.0
var dbg_long_force:     float   = 0.0
var dbg_forward_dir:    Vector3 = Vector3.ZERO
var dbg_right_dir:      Vector3 = Vector3.ZERO
var dbg_susp_force:     float   = 0.0

# --- 内部物理状态 ---
var _tire_deflection:       Vector2    = Vector2.ZERO
var _local_transform_cache: Transform3D
var _cache_initialized:     bool       = false
var _is_wheel_locked:       bool       = false

# --- 常量 ---
const LOW_SPEED_DAMP_SPEED:         float = 1.5
const LOW_SPEED_LAT_DAMP:           float = 6000.0
const LOW_SPEED_LONG_DAMP:          float = 6000.0
const HIGH_SPEED_LAT_DAMP:          float = 0.0
const HIGH_SPEED_LONG_DAMP:         float = 0.0
const WHEEL_LOCK_SPIN_THRESHOLD:    float = 0.5
const ANTI_DIVE_SIGN_SMOOTH_SPEED:  float = 0.3
const BRISTLE_FREEZE_SPEED:         float = 0.01

# -----------------------------------------------------------
func _ready() -> void:
	parent_body = _get_parent_body(self)
	if parent_body:
		_local_transform_cache = parent_body.global_transform.affine_inverse() \
								 * global_transform
		_cache_initialized = true

# -----------------------------------------------------------
func apply_custom_forces(state: PhysicsDirectBodyState3D, dt: float) -> void:
	if not parent_body: return

	if not _cache_initialized:
		var body_global_xform  = state.transform
		var wheel_global_xform = global_transform
		_local_transform_cache = body_global_xform.affine_inverse() * wheel_global_xform
		_cache_initialized     = true

	var space_state          = state.get_space_state()
	var current_global_xform = state.transform * _local_transform_cache
	var ray_start_base       = current_global_xform.origin
	var down_dir             = -current_global_xform.basis.y
	var base_forward         = (-current_global_xform.basis.z).rotated(
								current_global_xform.basis.y, steer_angle)
	var base_right           = current_global_xform.basis.x.rotated(
								current_global_xform.basis.y, steer_angle)

	dbg_ray_hits.clear()
	dbg_ray_misses.clear()

	# --- 1. 多射线网格 ---
	var valid_hits: Array = []
	var max_comp:   float = 0.0

	for i in range(lat_ray_count):
		for j in range(long_ray_count):
			var u = 0.0 if lat_ray_count  <= 1 else float(i) / (lat_ray_count  - 1) - 0.5
			var v = 0.0 if long_ray_count <= 1 else float(j) / (long_ray_count - 1) - 0.5

			var x_offset    = u * wheel_width
			var z_offset    = v * wheel_radius * long_ray_coverage * 2.0
			var h           = sqrt(max(wheel_radius * wheel_radius - z_offset * z_offset, 0.0))
			var ray_origin  = ray_start_base + base_right * x_offset + base_forward * z_offset
			var ray_max_len = rest_length + h
			var ray_end     = ray_origin + down_dir * ray_max_len

			var query  = PhysicsRayQueryParameters3D.create(
							ray_origin, ray_end, ground_collision_mask, [parent_body.get_rid()])
			var result = space_state.intersect_ray(query)

			if not result.is_empty():
				var hit_p = result["position"]
				var hit_n = result["normal"]
				var dist  = ray_origin.distance_to(hit_p)
				var comp  = ray_max_len - dist
				if comp > 0.0:
					valid_hits.append({"point": hit_p, "normal": hit_n, "comp": comp})
					if comp > max_comp: max_comp = comp
					dbg_ray_hits.append([ray_origin, hit_p])
			else:
				dbg_ray_misses.append([ray_origin, ray_end])

	# --- 2. 压力中心 ---
	if valid_hits.size() > 0:
		is_grounded = true

		var total_w  = 0.0
		var avg_pt   = Vector3.ZERO
		var avg_norm = Vector3.ZERO

		for hit in valid_hits:
			total_w  += hit.comp
			avg_pt   += hit.point  * hit.comp
			avg_norm += hit.normal * hit.comp

		if total_w > 0.001:
			avg_pt   /= total_w
			avg_norm  = avg_norm.normalized()
		else:
			avg_pt   = valid_hits[0].point
			avg_norm = valid_hits[0].normal

		dbg_contact_point  = avg_pt
		dbg_contact_normal = avg_norm
		current_compression = clamp(max_comp / rest_length, 0.0, 1.0)

		# --- 3. 悬挂力 ---
		var offset           = avg_pt - state.transform.origin
		var contact_velocity = state.get_velocity_at_local_position(offset)
		var susp_velocity    = contact_velocity.dot(avg_norm)

		var base_spring_force  = max_comp * spring_stiffness
		var total_spring_force = base_spring_force + arb_force

		if current_compression > 0.90:
			total_spring_force += (current_compression - 0.90) * spring_stiffness * 5.0

		var total_susp_force = max(total_spring_force - susp_velocity * damping, 0.0)
		dbg_susp_force       = total_susp_force

		# --- 4. 摩擦方向 ---
		var forward_dir    = (base_forward - avg_norm * base_forward.dot(avg_norm)).normalized()
		var right_dir      = (base_right   - avg_norm * base_right.dot(avg_norm)).normalized()
		dbg_forward_dir    = forward_dir
		dbg_right_dir      = right_dir

		var long_velocity    = contact_velocity.dot(forward_dir)
		var lateral_velocity = contact_velocity.dot(right_dir)
		wheel_long_vel       = long_velocity

		if not is_driven:
			spin_vel    = long_velocity / wheel_radius
			load_torque = 0.0

		wheel_rpm = (spin_vel * 60.0) / (2.0 * PI)

		# --- 5. 刷毛轮胎模型 ---
		var max_brake_capacity = brake_input * max_brake_torque
		var total_inertia      = wheel_inertia + drivetrain_inertia

		var spin_if_free    = spin_vel + (drive_torque + load_torque) / total_inertia * dt
		var brake_authority = max_brake_capacity / total_inertia * dt

		if brake_input > 0.01 and abs(spin_if_free) <= brake_authority + WHEEL_LOCK_SPIN_THRESHOLD:
			_is_wheel_locked = true
			spin_vel         = 0.0
		else:
			_is_wheel_locked = false

		var tire_surface_vel   = spin_vel * wheel_radius
		var long_slip_velocity = long_velocity - tire_surface_vel
		var local_slip_vel     = Vector2(lateral_velocity, long_slip_velocity)

		var rolling_speed = abs(tire_surface_vel)
		var relax_rate    = rolling_speed / max(relaxation_length, 0.01)

		if rolling_speed < BRISTLE_FREEZE_SPEED:
			_tire_deflection = _tire_deflection.lerp(Vector2.ZERO, 0.3)
		elif relax_rate > 0.01:
			var steady_state = local_slip_vel / relax_rate
			var decay        = exp(-relax_rate * dt)
			_tire_deflection = steady_state + (_tire_deflection - steady_state) * decay
		else:
			_tire_deflection += local_slip_vel * dt

		var desired_lat_force  = -_tire_deflection.x * tire_lat_stiffness
		var desired_long_force = -_tire_deflection.y * tire_long_stiffness

		var speed_normalized = clamp(rolling_speed / LOW_SPEED_DAMP_SPEED, 0.0, 1.0)
		var low_speed_t      = 1.0 - speed_normalized * speed_normalized
		var damp_lat  = lerp(HIGH_SPEED_LAT_DAMP,  LOW_SPEED_LAT_DAMP,  low_speed_t)
		var damp_long = lerp(HIGH_SPEED_LONG_DAMP, LOW_SPEED_LONG_DAMP, low_speed_t)

		desired_lat_force  -= lateral_velocity   * damp_lat
		desired_long_force -= long_slip_velocity * damp_long

		# --- 6. 摩擦圆限制 ---
		var dynamic_load = total_susp_force
		var max_friction = max(dynamic_load * friction_coefficient, 0.0)
		var desired_vec  = Vector2(desired_lat_force, desired_long_force)

		if desired_vec.length_squared() > max_friction * max_friction:
			desired_vec = desired_vec.normalized() * max_friction
			if tire_lat_stiffness > 0.0:
				_tire_deflection.x = -desired_vec.x / tire_lat_stiffness
			if tire_long_stiffness > 0.0:
				_tire_deflection.y = -desired_vec.y / tire_long_stiffness

		load_torque    = -desired_vec.y * wheel_radius
		dbg_lat_force  = desired_vec.x
		dbg_long_force = desired_vec.y

		# --- 7. 陀螺扭矩 ---
		var wheel_spin_axis        = right_dir
		var wheel_angular_momentum = wheel_spin_axis * (spin_vel * wheel_inertia)
		gyroscopic_torque          = state.angular_velocity.cross(wheel_angular_momentum)

		# --- 8. 力的施加 ---
		var mechanical_trail: float = 0.04
		var pneumatic_trail:  float = 0.06

		var friction_utilization = clamp(desired_vec.length() / max(max_friction, 0.001), 0.0, 1.0)
		var current_p_trail      = pneumatic_trail * (1.0 - friction_utilization)
		var total_trail          = mechanical_trail + current_p_trail

		var lat_force_pt      = offset - forward_dir * total_trail
		var vertical_force_pt = offset
		var lat_force_3d      = right_dir   * desired_vec.x
		var long_force_3d     = forward_dir * desired_vec.y

		var smooth_sign        = tanh(long_velocity / ANTI_DIVE_SIGN_SMOOTH_SPEED)
		var kinematic_vertical = desired_vec.y * anti_dive_factor * smooth_sign
		var final_vertical     = max(total_susp_force + kinematic_vertical, 0.0)

		state.apply_force(avg_norm * final_vertical, vertical_force_pt)
		state.apply_force(lat_force_3d,              lat_force_pt)
		state.apply_force(long_force_3d,             offset)

		_integrate_wheel_spin(dt)
		return

	# --- 离地状态 ---
	is_grounded         = false
	current_compression = 0.0
	_tire_deflection    = Vector2.ZERO
	load_torque         = 0.0
	_is_wheel_locked    = false
	gyroscopic_torque   = Vector3.ZERO
	dbg_lat_force       = 0.0
	dbg_long_force      = 0.0
	dbg_susp_force      = 0.0

	_integrate_wheel_spin(dt)

# -----------------------------------------------------------
func _integrate_wheel_spin(dt: float) -> void:
	if _is_wheel_locked:
		spin_vel    = 0.0
		wheel_rpm   = 0.0
		load_torque = 0.0
		return

	var mechanical_drag = -spin_vel * 0.15 - sign(spin_vel) * 2.5
	var net_torque      = drive_torque + load_torque + mechanical_drag
	var total_inertia   = wheel_inertia + drivetrain_inertia

	if brake_input > 0.01:
		var actual_brake_cap = brake_input * max_brake_torque
		var torque_to_stop   = net_torque + (spin_vel * total_inertia / dt)
		var brake_torque     = -clamp(torque_to_stop, -actual_brake_cap, actual_brake_cap)
		net_torque          += brake_torque

	var angular_accel  = net_torque / total_inertia
	spin_vel          += angular_accel * dt

	if abs(spin_vel) < 0.005 and abs(net_torque) < 0.5:
		spin_vel = 0.0

	wheel_rpm = (spin_vel * 60.0) / (2.0 * PI)

# -----------------------------------------------------------
func _get_parent_body(node: Node) -> RigidBody3D:
	var p = node.get_parent()
	while p:
		if p is RigidBody3D: return p
		p = p.get_parent()
	return null

func get_debug_info() -> Dictionary:
	return {
		"wheel_rpm":    wheel_rpm,
		"is_grounded":  is_grounded,
		"compression":  current_compression,
		"travel":       rest_length * (1.0 - current_compression),
		"is_driven":    is_driven,
		"steer_angle":  rad_to_deg(steer_angle),
		"susp_force":   dbg_susp_force,
		"slip_x":       _tire_deflection.x,
		"slip_y":       _tire_deflection.y,
		"wheel_locked": _is_wheel_locked,
		"gyro_torque":  gyroscopic_torque.length(),
		"lat_force":    dbg_lat_force,
		"long_force":   dbg_long_force,
		"slip_x_deg":   rad_to_deg(atan(_tire_deflection.x * relaxation_length)), # 近似侧偏角
	}

# --- 传动系接口 ---
func get_feedback_rpm(_upstream_rpm: float, _dt: float) -> float:
	return wheel_rpm

func push_drive_torque(in_torque: float, in_inertia: float, _dt: float) -> void:
	drive_torque       = in_torque
	drivetrain_inertia = in_inertia
