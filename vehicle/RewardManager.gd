extends Node
class_name RewardManager

var reward_funcs:Array[RewardFunction3D] = []

func _ready() -> void:
	for child:RewardFunction3D in get_children():
		reward_funcs.append(child)
		

func get_reward()->float:
	var reward:float =0.0
	for rw in reward_funcs:
		reward += rw.get_reward()
	return reward
