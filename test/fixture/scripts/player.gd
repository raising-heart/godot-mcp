class_name Player
extends Node2D

@export var speed := 120.0

func _ready() -> void:
	print("Player ready, score=", GameState.score)

func _process(delta: float) -> void:
	position.x += speed * delta
