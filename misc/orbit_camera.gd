class_name CamRig
extends Node3D

# --- 相机控制参数 ---
@export var max_pitch_deg: float = 45
@export var min_pitch_deg: float = -45
@export var max_zoom: float = 20
@export var min_zoom: float = 4
@export var zoom_step: float = 2
@export var zoom_y_step: float = 0.15
@export var vertical_sensitivity: float = 0.002
@export var horizontal_sensitivity: float = 0.002
@export var cam_y_offset: float = 4.0
@export var cam_lerp_speed: float = 16.0
@export var cam_target: Node3D

@onready var _spring_arm: SpringArm3D = get_node("SpringArm3D")
@onready var _current_zoom: float = 8

var _current_y_offset: float = cam_y_offset

func _ready() -> void:
	# 把相机刚体的变换从父节点解耦，从而允许其独立移动。
	self.top_level = true
	# 启动时捕获鼠标光标。
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# 暂停菜单（GlobalUI）属于源演示项目的自动加载栈，并未复制到本项目。
	# 对查找做空值保护，以便相机刚体能正常加载。
	var pause_menu = get_tree().root.get_node_or_null("GlobalUI/PauseMenu")
	if pause_menu:
		pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)

func _input(event: InputEvent) -> void:
	# 按下 ESC 键时切换鼠标捕获模式。
	#if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		#if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			#Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		#else:
			#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		#return # 切换后阻止本帧继续处理输入。

	# 若光标未被捕获，则忽略鼠标输入。
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	if event is InputEventMouseMotion:
		# 根据鼠标移动旋转相机。
		rotation.y -= event.relative.x * horizontal_sensitivity
		rotation.y = wrapf(rotation.y, 0.0, TAU)

		rotation.x -= event.relative.y * vertical_sensitivity
		rotation.x = clamp(rotation.x, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))

	if event is InputEventMouseButton:
		# 使用鼠标滚轮调整缩放水平。
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_WHEEL_UP and _current_zoom > min_zoom:
				_current_zoom -= zoom_step
				cam_y_offset -= zoom_y_step
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and _current_zoom < max_zoom:
				_current_zoom += zoom_step
				cam_y_offset += zoom_y_step

func _physics_process(delta: float) -> void:
	# 平滑插值到目标缩放水平。
	_spring_arm.spring_length = lerp(_spring_arm.spring_length, _current_zoom, delta * cam_lerp_speed)

	# 带垂直偏移地平滑跟随目标位置。
	_current_y_offset = lerp(_current_y_offset, cam_y_offset, delta * cam_lerp_speed)
	self.global_position = cam_target.global_position + Vector3(0, _current_y_offset, 0)

	# 通过手柄摇杆处理相机旋转。
	var joy_stick_input: Vector2 = Input.get_vector("cam_rotate_down", "cam_rotate_up", "cam_rotate_left", "cam_rotate_right")
	self.rotation.y -= joy_stick_input.y * horizontal_sensitivity * 1000 * delta
	self.rotation.y = wrapf(self.rotation.y, 0.0, TAU)
	self.rotation.x -= joy_stick_input.x * vertical_sensitivity * 1000 * delta
	self.rotation.x = clamp(self.rotation.x, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))

func _on_pause_menu_visibility_changed():
	var pause_menu = get_tree().root.get_node_or_null("GlobalUI/PauseMenu")
	if pause_menu and pause_menu.visible:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
