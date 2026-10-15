# res://vehicle/mmt_force_component.gd
extends Marker3D
class_name MMTForceComponentTEMP

func apply_custom_forces(state: PhysicsDirectBodyState3D, dt: float) -> void:
	# 此方法作为虚拟占位符，必须由子类重写。
	push_warning("MMTForceComponent: apply_custom_forces() must be overridden!")

## 与传动系接口保持兼容（鸭子类型）。
## 这些方法被其他系统期望存在，在此处仅作为空实现（stub）。
func get_feedback_rpm(_upstream_rpm: float, _dt: float) -> float:
	return 0.0

func push_drive_torque(_in_torque: float, _in_inertia: float, _dt: float) -> void:
	pass
