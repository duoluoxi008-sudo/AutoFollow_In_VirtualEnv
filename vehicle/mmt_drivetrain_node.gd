# res://vehicle/mmt_drivetrain_node.gd
extends Node
class_name MMTDrivetrainNodeTEMP

# =============================================================================
# MMT 传动系节点接口
#
# 这是动力流中任一组件（如发动机、变速箱、差速器）的基类。
# 它定义了每个物理帧进行两遍仿真的协议。
#
# 每帧仿真分两遍进行：
# 1. get_feedback_rpm（自底向上）：每个节点根据其子节点状态计算等效转速，
#    并上报给父节点。
# 2. push_drive_torque（自顶向下）：发动机计算扭矩并沿链路向下传递。
#    每个节点消耗或把该扭矩传递给其子节点。
# =============================================================================

## 第 1 遍（自底向上）：计算并向上游节点返回等效转速。
## @param upstream_rpm - 上游节点（例如发动机）的当前转速。
## @param dt - 物理时间步长。
func get_feedback_rpm(upstream_rpm: float, dt: float) -> float:
	return 0.0

## 第 2 遍（自顶向下）：接收来自上游的扭矩和惯量，并向下游分配。
## @param in_torque - 来自上游节点的输入扭矩。
## @param in_inertia - 来自上游节点的等效旋转惯量。
## @param dt - 物理时间步长。
func push_drive_torque(in_torque: float, in_inertia: float, dt: float) -> void:
	pass
