# res://vehicle/mmt_vehicle_input_state.gd
extends RefCounted
class_name MMTVehicleInputState

# ============================================================================
# MMT 车辆输入状态
#
# 设计模式：共享数据对象（Shared Data Object）
#
# 控制器（玩家/AI）每帧向此对象写入数据。
# MMTVehicleBody 每帧从该对象读取数据。
#
# 它们共享同一个引用，因此在物理运算中无需信号或轮询即可保证线程安全。
#
# 命名约定：
#   *_intent  -> 驾驶员意图（取值 0 到 1 的模拟量）。
#   *_pulse   -> 单帧事件，在车辆读取后由车辆清除。
# ============================================================================


# ----------------------------------------------------------------------------
# 模拟量输入（ANALOG INPUTS）
# ----------------------------------------------------------------------------

## 驾驶员向前行驶的意图 [0, 1]。
## 在带有自动变速箱的车辆上，控制器只需表达“向前行驶”的愿望。
## 车辆自身的 `auto_reverse` 逻辑负责判断是否需要先刹车。
#expose
var throttle_forward: float = 0.0

## 驾驶员向后行驶的意图 [0, 1]。
#expose
var throttle_back: float = 0.0

## 转向轴 [-1, 1]。正值表示向左转，
## 这与 Input.get_axis("right", "left") 的语义一致。
#expose
var steer_axis: float = 0.0

## 刹车意图 [0, 1]。它独立于油门，
## 用于停车或紧急制动等场景。
#expose
var brake: float = 0.0


# ----------------------------------------------------------------------------
# 脉冲事件（单帧）——PULSE EVENTS (SINGLE-FRAME)
# ----------------------------------------------------------------------------

## 请求升一挡。
var shift_up_pulse: bool = false

## 请求降一挡。
var shift_down_pulse: bool = false

## 请求在自动挡与手动挡之间切换。
var toggle_auto_shift_pulse: bool = false


# ----------------------------------------------------------------------------
# 工具方法——UTILITY METHODS
# ----------------------------------------------------------------------------

## 由车辆在 _physics_process 循环末尾调用。
## 清除所有单帧脉冲，防止它们被反复触发。
func consume_pulses() -> void:
	shift_up_pulse          = false
	shift_down_pulse        = false
	toggle_auto_shift_pulse = false

## 将所有输入重置为默认（零）状态。
## 适用于 AI 控制切换或车辆失效保护等场景。
func reset() -> void:
	throttle_forward        = 0.0
	throttle_back           = 0.0
	steer_axis              = 0.0
	brake                   = 0.0
	shift_up_pulse          = false
	shift_down_pulse        = false
	toggle_auto_shift_pulse = false
