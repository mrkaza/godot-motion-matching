# Post-import script for the clips exported from the Game Animation Sample (extracted/anims).
# - Unreal names every take "Unreal Take": rename it to the file name.
# - Loop mode comes from the sample's own bLoop flag (extracted/data/sequences.json), not the name.
# - The clip FBX bakes Unreal's Z-up to Y-up turn into the root bone's rest. Root motion extraction
#   would drop that turn with the rest of the root track, so it is taken out of the root keys here
#   and put on the skeleton's parent node instead (Mannequin.SKELETON_TURN). The root keys are then
#   Unreal's own root motion: Z up, character facing -Y.
@tool
extends EditorScenePostImport

const ROOT_BONE := "root"
const ANIMS_DIR := "res://extracted/anims/"
const SEQUENCES := "res://extracted/data/sequences.json"

static var _sequences: Dictionary


func _post_import(scene: Node) -> Object:
	var source := get_source_file()
	var key := source.trim_prefix(ANIMS_DIR).get_basename()
	var clip_name := source.get_file().get_basename()
	var info: Dictionary = _sequence_info(key)
	var skeleton: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
	var to_unreal := skeleton.get_bone_rest(skeleton.find_bone(ROOT_BONE)).basis.get_rotation_quaternion().inverse()
	for player: AnimationPlayer in scene.find_children("*", "AnimationPlayer", true, false):
		var library := player.get_animation_library("")
		for anim_name in library.get_animation_list():
			var anim := library.get_animation(anim_name)
			anim.loop_mode = Animation.LOOP_LINEAR if info.get("bLoop", false) else Animation.LOOP_NONE
			for track in anim.get_track_count():
				if anim.track_get_path(track).get_concatenated_subnames() != ROOT_BONE:
					continue
				for k in anim.track_get_key_count(track):
					match anim.track_get_type(track):
						Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D:
							anim.track_set_key_value(track, k, to_unreal * anim.track_get_key_value(track, k))
			library.rename_animation(anim_name, clip_name)
	return scene


static func _sequence_info(key: String) -> Dictionary:
	if _sequences.is_empty() and FileAccess.file_exists(SEQUENCES):
		_sequences = JSON.parse_string(FileAccess.get_file_as_string(SEQUENCES))
	return _sequences.get(key, {})
