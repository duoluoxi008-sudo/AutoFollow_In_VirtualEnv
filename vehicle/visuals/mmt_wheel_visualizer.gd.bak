# res://vehicle/visuals/mmt_wheel_visualizer.gd
extends Node3D
class_name MMTWheelVisualizer

@export_category("物理引用")
## 此可视化器将要读取数据的物理车轮组件。
@export var physics_wheel: MMTWheelComponent

@export_category("可视化节点")
## 悬挂的轮毂/转向节节点。它负责垂直行程（悬挂）和 Y 轴旋转（转向）。
@export var hub_node: Node3D
## 车轮网格节点。它负责绕其本地 X 轴旋转的滚动动画。
@export var wheel_mesh: Node3D
## [可选] 与轮毂一起移动的减震筒/阻尼器网格的下半部分。
@export var lower_strut_mesh: Node3D

@export_category("设置")
## 若车轮网格是镜像的（例如右侧），勾选此项以反转滚动方向。
@export var reverse_spin_direction: bool = false
## 悬挂安装点的纯视觉 Y 偏移，用于微调模型位置。
@export var visual_y_offset: float = 0.0

var _current_spin_angle: float = 0.0

func _ready() -> void:
	if not physics_wheel or not hub_node or not wheel_mesh:
		push_warning("MMTWheelVisualizer: Required node references are not set! - " + name)
		set_process(false)

# 可视化在 _process() 中更新，而非 _physics_process()。
# 这样可以独立于物理帧率进行平滑插值，防止视觉卡顿。
func _process(delta: float) -> void:
	if not physics_wheel.parent_body:
		return

	# 1. 悬挂行程
	# 'current_compression' 是一个比例，0.0 表示完全伸展，1.0 表示完全压缩。
	var travel_distance: float = physics_wheel.rest_length * (1.0 - physics_wheel.current_compression)

	# 悬挂压缩时，轮毂向上移动（本地 Y 为负）。
	hub_node.position.y = -travel_distance + visual_y_offset

	# 2. 转向
	hub_node.rotation.y = physics_wheel.steer_angle

	# 3. 车轮滚动
	var spin_speed: float = physics_wheel.spin_vel
	if reverse_spin_direction:
		spin_speed = -spin_speed

	_current_spin_angle += spin_speed * delta

	# 把角度包裹到 [0, TAU] 区间，防止随着时间推移产生浮点精度问题。
	_current_spin_angle = wrapf(_current_spin_angle, 0.0, TAU)

	# 假设车轮网格以本地 X 轴为旋转轴滚动。
	wheel_mesh.rotation.x = _current_spin_angle
