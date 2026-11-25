# Constants for the UEFN mannequin exported from the Game Animation Sample.
class_name Mannequin
extends RefCounted

## The UE5 Manny (SKM_Manny_Simple). The glTF of the UEFN mannequin lost skin weights (more than
## 8 influences per vertex) and deformed, so the body is Manny's FBX; the clips are the UEFN
## mannequin's, which shares Manny's bone names and axes.
const MESH := "res://extracted/mesh/SKM_Manny_Simple.fbx"
## Bones whose position tracks play (the rest only rotate, so Manny keeps his own proportions).
const POSITION_BONES := ["root", "pelvis", "ik_foot_root", "ik_foot_l", "ik_foot_r", "ik_hand_root", "ik_hand_gun", "ik_hand_l", "ik_hand_r"]
## Unreal's Z-up to Godot's Y-up turn, taken out of the clips' root keys at import
## (tools/import/clip_post_import.gd) and put on the skeleton's parent node. With it the
## character stands up and faces +Z.
const SKELETON_TURN := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))  # -90 deg about X
## A pose from the clips, used as the skeleton's rest (see instantiate()).
const REST_CLIP := "res://extracted/anims/Idle/M_Neutral_Stand_Idle_Loop.fbx"

static var _rest_cache := {}
## Off only to film the bug this fixes (tools/takes, "broken" takes).
static var use_clip_rest := true
## Characters that can be shown in Manny's place (CustomBody); B cycles Manny and the ones in the
## project. They are your own glTFs with UE5 bone names and are not in the repository.
## For example "res://assets/my_character/my_character.glb".
const BODY_MESHES: Array[String] = []
## The character shown in Manny's place at start (the first body found), or "" to show Manny.
static var body_mesh: String = _first_body()


## The paths of BODY_MESHES that are in the project.
static func available_bodies() -> Array:
	return BODY_MESHES.filter(func(p: String) -> bool: return ResourceLoader.exists(p))


static func _first_body() -> String:
	var found := available_bodies()
	return found[0] if not found.is_empty() else ""


## Instances the mannequin with the turn applied. Returns the root node; the Skeleton3D is
## find_skeleton(root). `custom_body` false always shows Manny (the NPC).
## The glTF's bone rests are up to 166 degrees away from the clips' bone rotations (the exporter
## re-oriented them). Godot's deterministic blending works relative to the rest, so blends between
## clips would take the long way round and pop; the rest is set to the idle clip's first frame
## instead. Skinning uses the skin's bind poses, so the mesh doesn't change.
static func instantiate(custom_body := true) -> Node3D:
	var body: Node3D = load(MESH).instantiate()
	var skeleton := find_skeleton(body)
	(skeleton.get_parent() as Node3D).basis = SKELETON_TURN
	if use_clip_rest:
		_apply_clip_rest(skeleton)
	if custom_body and body_mesh != "":
		CustomBody.attach(body, body_mesh)
	return body


static func find_skeleton(body: Node) -> Skeleton3D:
	return body.find_children("*", "Skeleton3D", true, false)[0]


static func _apply_clip_rest(skeleton: Skeleton3D) -> void:
	if _rest_cache.is_empty():
		var lib: AnimationLibrary = load(REST_CLIP)
		if lib == null:
			return
		var anim := lib.get_animation(lib.get_animation_list()[0])
		for t in anim.get_track_count():
			var bone_name := anim.track_get_path(t).get_concatenated_subnames()
			if bone_name == "root":
				continue  # the root's rest stays identity; its turn is on the parent node
			var entry: Dictionary = _rest_cache.get(bone_name, {})
			match anim.track_get_type(t):
				Animation.TYPE_POSITION_3D: entry["p"] = anim.position_track_interpolate(t, 0.0)
				Animation.TYPE_ROTATION_3D: entry["r"] = anim.rotation_track_interpolate(t, 0.0)
				Animation.TYPE_SCALE_3D: entry["s"] = anim.scale_track_interpolate(t, 0.0)
			_rest_cache[bone_name] = entry
	for bone_name: String in _rest_cache:
		var b := skeleton.find_bone(bone_name)
		if b < 0:
			continue
		var rest := skeleton.get_bone_rest(b)
		var e: Dictionary = _rest_cache[bone_name]
		var rot: Quaternion = e.get("r", rest.basis.get_rotation_quaternion())
		var scl: Vector3 = e.get("s", rest.basis.get_scale())
		# Rotation only: the positions stay Manny's.
		skeleton.set_bone_rest(b, Transform3D(Basis(rot) * Basis.from_scale(scl), rest.origin))
	skeleton.reset_bone_poses()


## Drops position tracks of limb bones from a clip played on Manny (see POSITION_BONES).
static func strip_limb_positions(anim: Animation) -> void:
	for t in range(anim.get_track_count() - 1, -1, -1):
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		if not anim.track_get_path(t).get_concatenated_subnames() in POSITION_BONES:
			anim.remove_track(t)


## The skeleton the clips were authored on (the sample's UEFN mannequin, 93 bones, with "attach" and
## the other bones Manny lacks), for math on clip data such as warp points. Not rendered.
const CLIP_SKELETON_MESH := "res://extracted/mesh/SKM_UEFN_Mannequin.glb"
static var _clip_skeleton: Skeleton3D


static func clip_skeleton() -> Skeleton3D:
	if _clip_skeleton == null:
		var body: Node3D = load(CLIP_SKELETON_MESH).instantiate()
		_clip_skeleton = find_skeleton(body)
		_clip_skeleton.get_parent().remove_child(_clip_skeleton)
		body.free()
		# The glTF exporter turned every bone's frame (Y up); the clips are in the FBX frames, so the rests
		# come from Unreal's reference pose (retarget.json) in those frames.
		var retarget = load("res://scripts/motion/retarget.gd")
		var ref: Dictionary = retarget.data()["source_ref"]
		for b in _clip_skeleton.get_bone_count():
			var bn := _clip_skeleton.get_bone_name(b)
			if ref.has(bn):
				_clip_skeleton.set_bone_rest(b, retarget.ue_xform(ref[bn]))
		_apply_clip_rest(_clip_skeleton)
	return _clip_skeleton
