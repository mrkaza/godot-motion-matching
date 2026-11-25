# Drives an NPC (a Player with is_npc = true) by scripted input: walks between `points` at the walk
# gait, facing where it goes, and waits `pause` seconds at each end. It stands still while one of its
# components is busy (an interaction, a ragdoll, a get-up). patrol = false: it just stands.
# Added to the NPC with Player.add_component().
extends Node

@export var points: Array[Vector3] = []
@export var pause := 2.5
@export var patrol := true
@export var arrive_radius := 0.4

var player: Player
var _next := 0
var _wait := 0.0


func _ready() -> void:
	player = get_parent()
	player.character.wants_to_walk = true
	player.character.wants_to_strafe = false
	player.scripted_input = Vector2.ZERO


func _busy() -> bool:
	if player.matcher.action_clip != "" or not player.matcher_enabled:
		return true
	for c in player.components:
		if c.has_method("is_ragdoll") and c.is_ragdoll():
			return true
		if c != self and "role" in c and c.role != 0:
			return true
	return false


func _physics_process(dt: float) -> void:
	player.scripted_input = Vector2.ZERO
	if not patrol or points.size() < 2 or _busy():
		return
	if _wait > 0.0:
		_wait -= dt
		return
	var to := points[_next] - player.character.global_position
	to.y = 0.0
	if to.length() < arrive_radius:
		_next = (_next + 1) % points.size()
		_wait = pause
		return
	var dir := to.normalized()
	# The player's camera space with the default camera yaw (PI): forward +Z, right -X.
	var fwd := Vector2(sin(player.camera_yaw + PI), cos(player.camera_yaw + PI))
	var right := Vector2(-fwd.y, fwd.x)
	var d := Vector2(dir.x, dir.z)
	player.scripted_input = Vector2(d.dot(right), d.dot(fwd))
