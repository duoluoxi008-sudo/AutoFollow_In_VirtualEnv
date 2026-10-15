extends Camera3D
class_name FreeFlyCamera

# --- 自由飞行相机控制参数 ---
@export_group("Movement")
@export var move_speed: float = 10.0
@export var sprint_speed: float = 30.0
@export var accelerate: float = 12.0
@export_group("Look")
@export var vertical_sensitivity: float = 0.002
@export var horizontal_sensitivity: float = 0.002
@export var max_pitch_deg: float = 89.0
@export var min_pitch_deg: float = -89.0

@export_group("Input")
@export var move_forward_action: StringName = &"free_cam_forward"
@export var move_back_action: StringName = &"free_cam_back"
@export var move_left_action: StringName = &"free_cam_left"
@export var move_right_action: StringName = &"free_cam_right"
@export var fly_up_action: StringName = &"free_cam_up"
@export var fly_down_action: StringName = &"free_cam_down"
@export var sprint_action: StringName = &"free_cam_sprint"
@export var toggle_mouse_action: StringName = &"free_cam_toggle_mouse"

var _velocity: Vector3 = Vector3.ZERO

func _ready() -> void:
	# 让相机刚体作为顶层节点独立移动，不受父级变换影响。
	top_level = true
	# 启动时捕获鼠标光标以便飞行视角。
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	# 按下切换键（free_cam_toggle_mouse）时切换鼠标捕获模式。
	if event.is_action_pressed(toggle_mouse_action):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# 切换后阻止本帧继续处理输入。
		get_viewport().set_input_as_handled()
		return

	# 若光标未被捕获，则忽略鼠标视角输入。
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	if event is InputEventMouseMotion:
		rotation.y -= event.relative.x * horizontal_sensitivity
		rotation.x -= event.relative.y * vertical_sensitivity
		rotation.x = clamp(rotation.x, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))

func _physics_process(delta: float) -> void:
	# 从输入构造一个与相机朝向对齐的期望方向。
	var input_dir: Vector3 = Vector3.ZERO
	input_dir.x = Input.get_axis(move_left_action, move_right_action)
	input_dir.z = Input.get_axis(move_forward_action, move_back_action)
	input_dir.y = Input.get_axis(fly_down_action, fly_up_action)

	# 将本地输入方向变换到世界空间。Godot 4 的 Vector3.transform() 只接受
	# Transform3D，不接受 Basis，因此改用基方向量乘法（basis * vector）。
	var direction: Vector3 = basis * input_dir
	if direction.length_squared() > 0.0:
		direction = direction.normalized()

	# 依据是否按下冲刺键选择速度。
	var speed: float = sprint_speed if Input.is_action_pressed(sprint_action) else move_speed
	var target_velocity: Vector3 = direction * speed

	# 平滑插值到目标速度，实现加减速的过渡。
	_velocity = _velocity.lerp(target_velocity, 1.0 - exp(-accelerate * delta))
	global_position += _velocity * delta
