extends Marker3D
class_name PassengerDestination

# ============================================================================
# PassengerDestination —— 乘客目的地（送达点）
#
# 作为"乘客要去哪"的标记节点：
#   - 自动注册进 "destinations" 组，供 PassengerManager 收集并派给乘客。
#   - active=false 时不会参与派送。
#   - delivery_radius：判定"已送达"的半径（供控制器读取）。
#   - assigned_count：当前正在派往此地的乘客数（供 PassengerManager 做负载均衡，
#     避免所有乘客都挤向同一个目的地）。
#   - delivered_count + delivered 信号：送达统计。
#   - 可选绘制可见标记。
# ============================================================================

signal delivered   ## 每次有乘客在此送达时发出

## 是否可用；false 时 PassengerManager 不会把它派给乘客
@export var active: bool = true
## 判定"送达"的半径（米）
@export_range(0.5, 20.0) var delivery_radius: float = 2.5
## 是否绘制一个可见标记
@export var show_marker: bool = true
## 标记颜色
@export var marker_color: Color = Color(0.2, 0.9, 0.4)

## 统计：总共在此送达了多少乘客
var delivered_count: int = 0
## 当前正在派往此目的地的乘客数（负载均衡）
var assigned_count: int = 0


func _ready() -> void:
	add_to_group("destinations")
	if show_marker:
		_ensure_marker()


func is_active() -> bool:
	return active


## 判断某世界坐标是否处于送达范围（平面距离）。
func within_delivery_range(world_pos: Vector3) -> bool:
	return Vector2(global_position.x, global_position.z) \
		.distance_to(Vector2(world_pos.x, world_pos.z)) <= delivery_radius


## 记录一个乘客被派往此地点（供负载均衡）。active=false 时返回 false。
func assign() -> bool:
	if not active:
		return false
	assigned_count += 1
	return true


## 有乘客送达（或不再前往此地）时回减占用。
func unassign() -> void:
	assigned_count = maxi(0, assigned_count - 1)


## 有乘客成功送达：统计 +1、释放占用、发出 delivered 信号。
func notify_delivered() -> void:
	delivered_count += 1
	unassign()
	delivered.emit()


func _ensure_marker() -> void:
	# 已有 MeshInstance3D 子节点则不重复添加
	for c in get_children():
		if c is MeshInstance3D:
			return
	var mi := MeshInstance3D.new()
	mi.name = "DestinationMarker"
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = marker_color
	mi.material_override = mat
	add_child(mi)
