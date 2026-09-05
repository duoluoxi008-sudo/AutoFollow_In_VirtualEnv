# res://vehicle/mmt_anti_roll_bar.gd
extends MMTForceComponentTEMP
class_name MMTAntiRollBarComponent

@export var left_wheel: MMTWheelComponent
@export var right_wheel: MMTWheelComponent
## 防倾杆的扭转刚度。数值越大代表防倾杆越硬。
@export var stiffness: float = 25000.0

func apply_custom_forces(_state: PhysicsDirectBodyState3D, _dt: float) -> void:
	if not (left_wheel and right_wheel):
		return

	# 防倾杆力即使车轮离地也会计算。
	# 车轮自身的 apply_custom_forces 函数会在其射线未触地时忽略该力，
	# 从而避免对车身产生任何“幻影”力。

	var comp_l: float = left_wheel.current_compression
	var comp_r: float = right_wheel.current_compression

	# 这个差值表示左轮比右轮多压缩了多少。
	var diff: float = comp_l - comp_r
	var anti_roll_force: float = diff * stiffness

	# 核心原理是载荷转移。一侧压缩更大，产生一个把该侧向上推、
	# 把另一侧向下压的力。
	left_wheel.arb_force = anti_roll_force
	right_wheel.arb_force = -anti_roll_force
