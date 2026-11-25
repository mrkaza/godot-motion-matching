# The showcase: the level (scenes/level.tscn), the player (traversal, ragdoll, interactions, the
# debug view), an NPC to shove, tackle and take down (ragdoll, interactions and a
# slow patrol) and a second one standing past the foot of the slope, facing the slide.
extends Node3D

const DEBUG_VIEW := preload("res://scripts/debug/debug_view.gd")

## Components added to the player; missing ones are skipped.
const COMPONENTS: Array[String] = [
	"res://scripts/traversal/traversal_component.gd",
	"res://scripts/ragdoll/ragdoll_component.gd",
	"res://scripts/interactions/interaction_component.gd",
	"res://scripts/audio/foley_component.gd",
	"res://scripts/game/body_switcher.gd",
]
## Components added to the NPC.
const NPC_COMPONENTS: Array[String] = [
	"res://scripts/ragdoll/ragdoll_component.gd",
	"res://scripts/interactions/interaction_component.gd",
]
const NPC_PATROL := preload("res://scripts/game/npc_patrol.gd")
## The NPC walks between these points (to the right of the spawn, off the lanes the takes and tests use).
const NPC_PATH: Array[Vector3] = [Vector3(6, 0, -3), Vector3(6, 0, 3)]
## The NPC at the end of the course: 14 m past the slope's foot (z 129.92, 8.97 m below the spawn),
## on the course's line.
const TARGET_AT := Vector3(0, -8.97, 143.92)

var player: Player
var npc: Player
var target: Player


func _ready() -> void:
	if not DirAccess.dir_exists_absolute("res://databases/MotionMatchingData"):
		var msg := "The animations aren't set up yet. Run tools/extract_gasp.ps1 first (see README.md)."
		push_error(msg)
		var label := Label.new()
		label.text = msg
		add_child(label)
		return
	var preview := find_child("SpawnPreview", true, false)
	if preview:
		preview.queue_free()
	player = Player.new()
	add_child(player)
	for path: String in COMPONENTS:
		if ResourceLoader.exists(path):
			var component: Node = load(path).new()
			player.add_component(component)
			if path.contains("traversal"):
				player.matcher.traversal = component
	player.add_component(DEBUG_VIEW.new())
	npc = spawn_npc("NPC", NPC_PATH[0], true)
	target = spawn_npc("Target", TARGET_AT, false, PI)


## Spawns an NPC: another character on the same systems, driven by npc_patrol.gd, facing yaw.
func spawn_npc(npc_name: String, at: Vector3, patrol: bool, yaw := 0.0) -> Player:
	var p := Player.new()
	p.name = npc_name
	p.is_npc = true
	p.position = at
	add_child(p)
	p.character.yaw = yaw
	p.character.control_yaw = yaw
	p.matcher.visual_yaw = yaw
	for path: String in NPC_COMPONENTS:
		if ResourceLoader.exists(path):
			p.add_component(load(path).new())
	var brain := NPC_PATROL.new()
	brain.points = NPC_PATH
	brain.patrol = patrol
	p.add_component(brain)
	return p
