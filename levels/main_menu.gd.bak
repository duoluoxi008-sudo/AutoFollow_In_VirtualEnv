# MainMenu.gd
# 主界面：选择进入「训练场景」或「玩家车辆场景」
extends Control

@export var train_button :Button
@export var test_train_button :Button
@export var player_button :Button
@export var quit_button :Button


# 是否正在加载场景
var _loading := false
# 待加载的场景路径
var _pending_path := ""


func _ready() -> void:
	train_button.pressed.connect(_on_train_button_pressed)
	player_button.pressed.connect(_on_player_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	test_train_button.pressed.connect(_on_test_train_button_pressed)

func _on_test_train_button_pressed()->void:
	load_level("res://levels/TestTrainScene.tscn")

func _on_train_button_pressed() -> void:
	load_level("res://levels/ParaTrainScene.tscn")


func _on_player_button_pressed() -> void:
	load_level("res://levels/mmt_player_sedan.tscn")


func _on_quit_button_pressed() -> void:
	get_tree().quit()


## 发起场景加载。使用线程后台加载资源，本身不会阻塞主线程。
func load_level(path: String) -> void:
	if _loading:
		return
	_pending_path = path
	_loading = true
	_set_buttons_disabled(true)
	ResourceLoader.load_threaded_request(path)


## 在主线程每帧轮询加载状态：完成后才安全地切换场景。
func _process(_delta: float) -> void:
	if not _loading:
		return
	var status := ResourceLoader.load_threaded_get_status(_pending_path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var new_scene: PackedScene = ResourceLoader.load_threaded_get(_pending_path)
		_loading = false
		get_tree().change_scene_to_packed(new_scene)
	elif status == ResourceLoader.THREAD_LOAD_FAILED:
		print("Failed to load scene: ", _pending_path)
		_loading = false
		_set_buttons_disabled(false)


func _set_buttons_disabled(disabled: bool) -> void:
	for b in [train_button, player_button, quit_button]:
		if is_instance_valid(b):
			b.disabled = disabled
