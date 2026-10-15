# res://vehicle/engine_spec.gd
extends Resource
class_name EngineSpec

## =====================================================================
## 发动机规格（EngineSpec）—— 发动机特性的唯一真相来源
##
## 为什么需要它：
##   引擎组件要用 max_rpm 归一化扭矩曲线、判定爆转、算内部阻力；
##   变速箱组件要用同一套怠速/红线转速做红线保护与离合匹配。
##   以前两边各抄一份参数（还各配一句"必须保持一致"的注释），结果就是漂移：
##   本项目里引擎实际是 6000/800，变速箱却写着 6200/4500。
##   现在两者引用同一份资源，参数只有一处，改一次两边同时生效。
##
## 三层分工（重要，别混）：
##   1. EngineSpec（本文件）：这台发动机"是什么"。静态、可共享、可替换。
##      换发动机 / 改装 = 复制一份 .tres 改名后调参，再挂到 Engine.spec。
##   2. Engine.torque_scale（运行时修正）：当前"环境/状态"。
##      天气、高原、进气温度、过热、损伤由系统每帧写它，
##      不要把这些写进本资源（那是共享的）。
##   3. RL 域随机化：务必先 duplicate_spec() 再随机化，
##      否则会污染所有共用这份 .tres 的车。
## =====================================================================

@export_category("转速区间")
## 怠速转速（rpm）。引擎转速下限，也是离合分离时自由转速目标的起点。
@export var idle_rpm: float = 800.0
## 扭矩曲线的定义域上限（rpm）：曲线横轴 = rpm / max_rpm。
## 同时是"爆转额外阻力惩罚"的起点。
@export var max_rpm: float = 6000.0
## 断油保护转速（rpm）。超过它 fuel_cut = 0，输出扭矩归零。
@export var rev_limiter_rpm: float = 6400.0

@export_category("扭矩")
## 峰值扭矩（N·m）。实际输出还要乘扭矩曲线倍率。
@export var max_torque: float = 200.0
## 归一化扭矩曲线：横轴 0..1 对应 0..max_rpm，纵轴 0..1 为扭矩倍率。
## 为空时退化为正弦曲线（回退方案）。
@export var torque_curve: Curve

@export_category("动力学")
## 内部机械阻力常数项（N·m），始终存在。发动机制动的来源之一。
@export var engine_drag_base: float = 12.0
## 内部机械阻力随转速增长的系数（N·m/rpm）。
@export var engine_drag_multiplier: float = 0.008
## 曲轴 + 飞轮转动惯量（kg·m²）。经传动比平方放大后直接影响加速能力。
@export var engine_inertia: float = 0.15


## 取扭矩曲线在某转速下的倍率（0..1）。
func get_torque_factor(rpm: float) -> float:
	var x := clampf(rpm / maxf(max_rpm, 1.0), 0.0, 1.0)
	if torque_curve:
		return torque_curve.sample_baked(x)
	return sin(x * PI)


## 复制一份规格，供改装 / RL 随机化使用。
## deep = false 时 Curve 子资源保持共享（省内存）；要改曲线本身就用 true。
func duplicate_spec(deep: bool = false) -> EngineSpec:
	return duplicate(deep) as EngineSpec
