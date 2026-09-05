@tool
extends RayCastSensor3D
class_name ModifyRayCastSensor3D

@export var debug_line_color:Color

func _update():
	if Engine.is_editor_hint():
		if is_node_ready():
			_spawn_nodes()


func _ready() -> void:
	if Engine.is_editor_hint():
		if get_child_count() == 0:
			_spawn_nodes()
	else:
		_spawn_nodes()


func _spawn_nodes():
	print("spawning nodes")
	for ray in get_children():
		ray.queue_free()
	if geo:
		geo.clear()
	#$Lines.remove_points()
	rays = []

	var horizontal_step = cone_width / (n_rays_width)
	var vertical_step = cone_height / (n_rays_height)

	var horizontal_start = horizontal_step / 2 - cone_width / 2
	var vertical_start = vertical_step / 2 - cone_height / 2

	var points = []

	for i in n_rays_width:
		for j in n_rays_height:
			var angle_w = horizontal_start + i * horizontal_step
			var angle_h = vertical_start + j * vertical_step
			#angle_h = 0.0
			var ray = RayCast3D.new()
			var cast_to = to_spherical_coords(ray_length, angle_w, angle_h)
			ray.set_target_position(cast_to)

			points.append(cast_to)

			if debug_draw:
				ray.enabled = true
			else:
				ray.enabled = false
			ray.collide_with_bodies = collide_with_bodies
			ray.collide_with_areas = collide_with_areas
			ray.collision_mask = collision_mask
			add_child(ray)
			ray.set_owner(get_tree().edited_scene_root)
			ray.set_name("node_" + str(i) + " " + str(j))
			rays.append(ray)
			ray.force_raycast_update()


		if Engine.editor_hint:
				_create_debug_lines(points)


func _create_debug_lines(points):
	if not geo:
		geo = ImmediateMesh.new()
		add_child(geo)

	geo.clear()
	geo.begin(Mesh.PRIMITIVE_LINES)
	for point in points:
		geo.set_color(debug_line_color)
		geo.add_vertex(Vector3.ZERO)
		geo.add_vertex(point)
	geo.end()


func display():
	if geo:
		geo.display()


func to_spherical_coords(r, inc, azimuth) -> Vector3:
	return Vector3(
		r * sin(deg_to_rad(inc)) * cos(deg_to_rad(azimuth)),
		r * sin(deg_to_rad(azimuth)),
		r * cos(deg_to_rad(inc)) * cos(deg_to_rad(azimuth))
	)


func get_observation() -> Array:
	return self.calculate_raycasts()


func calculate_raycasts() -> Array:
	var result = []
	for ray in rays:
		if not debug_draw:
			ray.set_enabled(true)
		ray.force_raycast_update()
		var distance = _get_raycast_distance(ray)

		result.append(distance)
		if class_sensor:
			var hit_class: float = 0
			if ray.get_collider():
				var hit_collision_layer = ray.get_collider().collision_layer
				hit_collision_layer = hit_collision_layer & collision_mask
				hit_class = (hit_collision_layer & boolean_class_mask) > 0
			result.append(float(hit_class))
		if not debug_draw:
			ray.set_enabled(false)
	return result


func _get_raycast_distance(ray: RayCast3D) -> float:
	if !ray.is_colliding():
		return 0.0

	var distance = (global_transform.origin - ray.get_collision_point()).length()
	distance = clamp(distance, 0.0, ray_length)
	return (ray_length - distance) / ray_length
