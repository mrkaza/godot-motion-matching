# The sample's foley: AC_FoleyEvents and DefaultFoleyEventAudioBank playing
# the MetaSound presets, fired the way the sample fires them:
#  - BP_AnimNotify_FoleyEvent_* notifies on the clips the matcher plays (extracted/data/sequences.json),
#    with each notify's own event tag, side, volume and pitch. Motion matching's blend stack: only the
#    newest player is the active context (older ones are blending out and IsBlendingOut skips them), a
#    notify fires only when the player's weight reaches its TriggerWeightThreshold, and the stack's
#    notify filter (bShouldFilterNotifies) drops a notify name fired by any player in the last
#    NotifyRecencyTimeOut (0.2 s walk/run, 0.16 s sprint). Actions (traversal, get-up and interaction
#    montages) fire their clip's and montage's notifies like montages do: unfiltered, while their
#    weight passes the threshold.
#  - OnJumped / OnLanded of SandboxCharacter_CMC: Foley.Event.Jump (volume from ground speed) and
#    Foley.Event.Land (volume from the landing speed).
#  - OnRagdollHit of SandboxCharacter_Mover_Ragdoll: Foley.Event.Ragdoll when a ragdoll body hits
#    something other than itself at more than 50 cm/s with more than 100 kg cm/s of impulse, volume
#    from the body's speed, at most one every 0.3 s (the Gate + Delay).
# Each event plays its preset like MSS_FoleySound: a random wave (no repeat of the last 5), random gain
# between Volume.Min and Volume.Max dB, random pitch between Pitch.Min and Pitch.Max, times the
# preset's Gain and source Volume and the event's volume and pitch; SM_Foley at -10 dB with the reverb
# send. No distance falloff (the sample's DefaultAttenuation): the steps sound the same however far the
# camera is.
# Sounds play from the foot, hand or body the event belongs to.
extends Node

const DATA := "res://extracted/data/"
const BANK := "res://extracted/audio/foley_bank.json"
const AUDIO := "res://extracted/audio/"
const ANIMS := "res://extracted/anims/"
const CM := 0.01
const NOTIFY_CLASS := "BP_AnimNotify_FoleyEvent"
## Get_MMNotifyRecencyTimeOut (SandboxCharacter_CMC_ABP) by gait.
const RECENCY_TIMEOUT := {"Walk": 0.2, "Run": 0.2, "Sprint": 0.16}
const SIDES := {"NewEnumerator0": "L", "NewEnumerator2": "R", "NewEnumerator4": ""}
## OnJumped: MapRangeClamped(ground speed, 0..500 cm/s -> 0.5..1.0). OnLanded: (land Z, -500..-900 -> 0.5..1.5).
const JUMP_VOLUME := [0.0, 500.0, 0.5, 1.0]
const LAND_VOLUME := [-500.0, -900.0, 0.5, 1.5]
## OnRagdollHit: speed > 50 cm/s, |NormalImpulse| > 100 kg cm/s, volume MapRangeClamped(speed, 50..500 -> 0.3..1.0).
const RAGDOLL_MIN_SPEED := 50.0
const RAGDOLL_MIN_IMPULSE := 100.0
const RAGDOLL_VOLUME := [50.0, 500.0, 0.3, 1.0]
const RAGDOLL_GATE := 0.3
## SMFX_Reverb_Default WetLevel x Gain: the reverb return relative to the source (SM_Reverb has no gain).
const REVERB_RETURN := 0.11 * 0.4

## Every event played: {time, tag, preset, side, volume, pitch, source, clip, wave, frame}.
var events: Array[Dictionary] = []
## True: the sample's exact rule. Only the newest player is audible (older ones are blending out and
## IsBlendingOut skips them), yet their notifies still feed the recency filter. A footfall goes silent
## when the old clip crosses it after a new pick started but the new clip entered past it, or when the
## old clip's silent step bans the new clip's step for the same footfall.
## False (default): the player with the most weight is audible too, so the footfall sounds from the
## clip the feet still follow, and only notifies that play feed the filter. The filter still keeps it
## to one sound per footfall (same notify name within the gait's time-out).
var filter_inactive_players := false
## Turn off to keep the logic but play nothing (tests count events without voices).
var audible := true

var player: Player
var matcher: MotionMatcher
var character: GaspCharacter
var skeleton: Skeleton3D

static var _bank: Dictionary
static var _notifies: Dictionary      # sequence key -> [{t, name, tag, side, volume, pitch, threshold}]
static var _montage_notifies: Dictionary   # sequence key -> same, from the montage's own track (sequence time)
static var _streams: Dictionary       # file -> AudioStream
static var _no_repeat: Dictionary     # preset -> recent wave indices (Random Get's shared state)

var _clock := 0.0
var _frame := 0
var _anim_key := {}                   # animation name in the tree -> sequence key
var _known_clips := -1
var _prev: Array = []                 # [{name, time, id}] newest first
var _next_id := 0
var _action_ids := {}                 # player ids that are actions (montages)
var _fired: Array = []                # NotifiesFiredLastTick
var _banned := {}                     # NotifyRecencyMap: notify name -> game time it may fire again
var _was_on_ground := true
var _ground_speed := 0.0
var _ragdoll_open_at := 0.0
var _ragdoll_reporting := false
var _voices: Array = []               # [AudioStreamPlayer3D, dB]
# Slide loop (the Mover pawn's On_MovementModeChanged: PlayFoleyEvent Slide.Loop on entering
# Sliding, FadeOut 0.5 s linear on leaving). The looping MetaSound is approximated by playing
# another wave of its preset when one ends.
const SLIDE_FADE_OUT := 0.5
var _was_sliding := false
var _slide_voice: AudioStreamPlayer3D
var _slide_fading := []               # [voice entry, time left]
var _log: FileAccess
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	player = get_parent()
	matcher = player.matcher
	character = player.character
	skeleton = Mannequin.find_skeleton(player.visual)
	_rng.randomize()
	_load_data()
	_setup_buses()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("foley_log="):
			_log = FileAccess.open(a.trim_prefix("foley_log="), FileAccess.WRITE)
	_was_on_ground = character.movement_mode != GaspCharacter.MovementMode.IN_AIR  # sliding is on the ground


static func _load_data() -> void:
	if not _bank.is_empty():
		return
	if not FileAccess.file_exists(BANK):
		push_warning("foley: %s missing (run tools/extract_gasp.ps1)" % BANK)
		_bank = {"events": {}, "presets": {}}
		return
	_bank = JSON.parse_string(FileAccess.get_file_as_string(BANK))
	var seqs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "sequences.json"))
	for key: String in seqs:
		var list := _foley_notifies(seqs[key].get("notifies", []), 0.0, 0.0, 1.0)
		if not list.is_empty():
			_notifies[key] = list
	# Montage-track foley (interaction punches, hand plants) in the sequence's time, for montages that
	# are the only one playing their sequence.
	var montages: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "montages.json"))
	var users := {}
	for m: String in montages:
		for slot: Dictionary in montages[m]["slots"]:
			for seg: Dictionary in slot["segments"]:
				users[seg["asset"]] = users.get(seg["asset"], 0) + 1
	for m: String in montages:
		var segs: Array = montages[m]["slots"][0]["segments"]
		if segs.size() != 1 or users.get(segs[0]["asset"], 0) != 1:
			continue
		var seg: Dictionary = segs[0]
		var list := _foley_notifies(montages[m].get("notifies", []), float(seg["StartPos"]), float(seg["AnimStartTime"]), float(seg["AnimPlayRate"]))
		if not list.is_empty():
			_montage_notifies[seg["asset"]] = list


## Foley notifies of a notify list, times mapped montage -> sequence (start + (t - pos) * rate).
static func _foley_notifies(list: Array, seg_pos: float, seg_start: float, rate: float) -> Array:
	var out := []
	for n: Dictionary in list:
		if n.get("kind") != "notify" or not String(n.get("class", "")).begins_with(NOTIFY_CLASS):
			continue
		var p: Dictionary = n.get("object", {}).get("properties", {})
		var tag: String = (p.get("Event", {}) as Dictionary).get("TagName", "")
		if tag == "":
			continue
		out.append({
			"t": seg_start + (float(n["trigger_time"]) - seg_pos) * rate, "name": n["name"], "class": n["class"],
			"tag": tag, "side": SIDES.get(p.get("Side", "NewEnumerator4"), ""),
			"volume": float(p.get("VolumeMultiplier", 1.0)), "pitch": float(p.get("PitchMultiplier", 1.0)),
			"threshold": float(n.get("TriggerWeightThreshold", 1e-5)),
		})
	out.sort_custom(func(a, b): return a["t"] < b["t"])
	return out


## One bus per reverb send level: SM_Foley's -10 dB as the reverb's dry level, the send as its wet.
func _setup_buses() -> void:
	var reverb: Dictionary = _bank.get("reverb", {}).get("SMFX_Reverb_Default", {})
	var foley_db: float = _bank.get("submixes", {}).get("SM_Foley", {}).get("volume_db", -10.0)
	for preset: Dictionary in _bank["presets"].values():
		var name := _bus_name(preset)
		if AudioServer.get_bus_index(name) >= 0:
			continue
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, name)
		AudioServer.set_bus_send(i, "Master")
		var fx := AudioEffectReverb.new()
		fx.dry = db_to_linear(foley_db)
		fx.wet = float(preset["reverb_send"]) * REVERB_RETURN
		# Freeverb room size for the preset's 0.8 s decay; HF decay ratio as damping; reflections delay.
		var decay := float(reverb.get("DecayTime", 0.8))
		fx.room_size = clampf((pow(10.0, -0.09 / decay) - 0.7) / 0.28, 0.0, 1.0)
		fx.damping = clampf(1.0 - float(reverb.get("DecayHFRatio", 0.5)), 0.0, 1.0)
		fx.predelay_msec = clampf(float(reverb.get("ReflectionsDelay", 0.02)) * 1000.0, 20.0, 500.0)
		fx.spread = float(reverb.get("Diffusion", 1.0))
		fx.hipass = 0.0
		AudioServer.add_bus_effect(i, fx)


static func _bus_name(preset: Dictionary) -> String:
	return "Foley" if float(preset["reverb_send"]) >= 0.999 else "Foley send %.1f" % float(preset["reverb_send"])


# ------------------------------------------------------------------ per tick

func after_animation(dt: float) -> void:
	_clock += dt
	_frame += 1
	_update_filter()
	_update_notifies(dt)
	_update_movement_events()
	_update_slide_sound(dt)
	_update_ragdoll_hits()
	_update_voices()
	if _log != null:
		var fl := _bone_world("foot_l")
		var fr := _bone_world("foot_r")
		_log.store_line("F %d %d %.4f %.4f %.4f %.4f %.4f %.4f %.4f" % [_frame, Engine.get_frames_drawn(), _clock, fl.x, fl.y, fl.z, fr.x, fr.y, fr.z])


## The blend stack's notify filter: names fired last tick are banned for the gait's recency time-out.
var _last_fired_clock := -1e9


func _update_filter() -> void:
	var timeout: float = RECENCY_TIMEOUT.get(matcher.vars.get("Gait", "Run"), 0.2)
	for name in _fired:
		_banned[name] = _clock + timeout
	_fired.clear()
	for name in _banned.keys():
		if _clock >= _banned[name]:
			_banned.erase(name)


func _update_notifies(dt: float) -> void:
	if matcher.clip_names.size() != _known_clips:
		_known_clips = matcher.clip_names.size()
		_anim_key.clear()
		for clip: String in matcher.clip_names:
			_anim_key[matcher.clip_names[clip]] = clip.trim_prefix(ANIMS).get_basename()
	var cur: Array = matcher.blend.get_players()
	var ids := _match_players(cur, dt)
	# A new action on top is a montage; once motion matching carries on with it, it's a pose again.
	var action_anim: String = matcher.clip_names.get(matcher.action_clip, "")
	if not cur.is_empty():
		if action_anim != "" and cur[0][0] == action_anim and not _prev_has(ids[0]):
			_action_ids[ids[0]] = true
		elif action_anim == "" and _action_ids.has(ids[0]):
			_action_ids.erase(ids[0])
	# The motion matching player with the most weight (the clip the feet mostly follow).
	var dominant := -1
	var dominant_weight := -1.0
	for i in cur.size():
		if not _action_ids.has(ids[i]) and float(cur[i][2]) > dominant_weight:
			dominant_weight = float(cur[i][2])
			dominant = i
	var active_found := false
	var next := []
	for i in cur.size():
		var name: String = cur[i][0]
		var time: float = cur[i][1]
		var weight: float = cur[i][2]
		var id: int = ids[i]
		var is_action := _action_ids.has(id)
		# The motion matching stack's active context: its newest (non-montage) player.
		var active := false
		if not is_action and not active_found:
			active = true
			active_found = true
		var prev_time = _prev_time(id)
		next.append({"name": name, "time": time, "id": id})
		if prev_time == null:
			continue
		var key: String = _anim_key.get(name, "")
		for n: Dictionary in _crossed(key, name, prev_time, time, is_action):
			if weight < n["threshold"]:
				continue
			if is_action:
				_play_notify(n, key)
				continue
			# Audible: the active context (the sample), and here also the dominant player while the new
			# pick is still blending in (see filter_inactive_players).
			var audible := active or (not filter_inactive_players and i == dominant)
			if not audible and not filter_inactive_players:
				continue
			# FBlendStackAnimEventsFilterContext::ShouldFilterNotify: one sound per footfall.
			if _banned.has(n["name"]) or _fired.has(n["name"]):
				continue
			# The dominant player's notify only fills a gap: not within the recency time-out of any
			# other one (its notify can have another name than the active clip's for the same footfall).
			if not active and _clock - _last_fired_clock < RECENCY_TIMEOUT.get(matcher.vars.get("Gait", "Run"), 0.2):
				continue
			_fired.append(n["name"])
			if audible:
				_last_fired_clock = _clock
				_play_notify(n, key)
	for id in _action_ids.keys():
		if not ids.has(id):
			_action_ids.erase(id)
	_prev = next


## Ids for this tick's players: the previous tick's player that continues each one (same clip, time moved
## forward by about a tick), else a new id. Players are only added on top and pruned at the bottom.
func _match_players(cur: Array, dt: float) -> Array:
	var best_shift := 0
	var best_score := -1
	for shift in 3:
		var score := 0
		for i in _prev.size():
			var j: int = i + shift
			if j < cur.size() and _continues(_prev[i], cur[j], dt):
				score += 1
		if score > best_score:
			best_score = score
			best_shift = shift
	var ids := []
	for j in cur.size():
		var i := j - best_shift
		if i >= 0 and i < _prev.size() and _continues(_prev[i], cur[j], dt):
			ids.append(_prev[i]["id"])
		else:
			ids.append(_next_id)
			_next_id += 1
	return ids


func _continues(p: Dictionary, c: Array, dt: float) -> bool:
	if p["name"] != c[0]:
		return false
	var d: float = float(c[1]) - float(p["time"])
	if d < -1e-4:
		var anim: Animation = matcher.tree.get_animation(c[0])
		if anim == null or anim.loop_mode == Animation.LOOP_NONE:
			return false
		d += anim.length
	return d >= -1e-4 and d <= dt * 1.25 + 1e-3


func _prev_has(id: int) -> bool:
	for p in _prev:
		if p["id"] == id:
			return true
	return false


func _prev_time(id: int):
	for p in _prev:
		if p["id"] == id:
			return p["time"]
	return null


## Notifies passed from t0 to t1 (exclusive, inclusive], wrapping a looping clip.
func _crossed(key: String, anim_name: String, t0: float, t1: float, is_action: bool) -> Array:
	var list: Array = _notifies.get(key, [])
	if is_action:
		list = list + _montage_notifies.get(key, [])
	if list.is_empty() or is_equal_approx(t0, t1):
		return []
	var out := []
	if t1 > t0:
		for n in list:
			if n["t"] > t0 and n["t"] <= t1:
				out.append(n)
	else:
		var anim: Animation = matcher.tree.get_animation(anim_name)
		var length := anim.length if anim != null else t0
		for n in list:
			if (n["t"] > t0 and n["t"] <= length) or (n["t"] >= 0.0 and n["t"] <= t1):
				out.append(n)
	return out


func _play_notify(n: Dictionary, key: String) -> void:
	play_event(n["tag"], _event_position(n["tag"], n["side"]), n["volume"], n["pitch"], {"side": n["side"], "source": "notify", "clip": key, "notify": n["name"]})


## OnJumped and OnLanded (SandboxCharacter_CMC): the movement component's falling <-> walking, not the
## traversal's Flying, the ragdoll or its get-up (custom modes in the sample).
func _update_movement_events() -> void:
	var on_ground := character.movement_mode != GaspCharacter.MovementMode.IN_AIR  # sliding is on the ground
	var ragdoll := _ragdoll()
	var suppressed: bool = ragdoll != null and ragdoll.mode != 0   # Mode.OFF
	for c in player.components:
		if "doing_traversal" in c and c.doing_traversal:
			suppressed = true
	if not suppressed:
		if _was_on_ground and not on_ground and character.velocity_cm.y > 100.0:
			var v := _map_clamped(_ground_speed, JUMP_VOLUME)
			play_event("Foley.Event.Jump", _event_position("Foley.Event.Jump", ""), v, 1.0, {"source": "jump"})
		elif not _was_on_ground and on_ground and character.just_landed:
			var v := _map_clamped(character.land_velocity.y, LAND_VOLUME)
			play_event("Foley.Event.Land", _event_position("Foley.Event.Land", ""), v, 1.0, {"source": "land"})
	_was_on_ground = on_ground
	if on_ground:
		_ground_speed = character.speed_2d()


## OnRagdollHit (SandboxCharacter_Mover_Ragdoll), from the bodies' contacts while ragdolled.
func _update_ragdoll_hits() -> void:
	var ragdoll := _ragdoll()
	if ragdoll == null or not ragdoll.is_ragdoll() or ragdoll.body == null or not ragdoll.body.simulating:
		_ragdoll_reporting = false
		return
	var bodies: Array = ragdoll.body.bodies
	if not _ragdoll_reporting:
		# Contact reports only (bNotifyRigidBodyCollision); the simulation is unchanged.
		for b: PhysicalBone3D in bodies:
			if PhysicsServer3D.body_get_max_contacts_reported(b.get_rid()) < 4:
				PhysicsServer3D.body_set_max_contacts_reported(b.get_rid(), 4)
		_ragdoll_reporting = true
		return
	if _clock < _ragdoll_open_at:
		return
	var own := {}
	for b in bodies:
		own[b.get_instance_id()] = true
	own[character.get_instance_id()] = true
	var best_speed := 0.0
	var best_at := Vector3.ZERO
	var best_bone := ""
	for i in bodies.size():
		var st := PhysicsServer3D.body_get_direct_state(bodies[i].get_rid())
		if st == null:
			continue
		var speed := st.linear_velocity.length() / CM
		if speed <= RAGDOLL_MIN_SPEED:
			continue
		for c in st.get_contact_count():
			var other := st.get_contact_collider_object(c)
			if other != null and own.has(other.get_instance_id()):
				continue
			if st.get_contact_impulse(c).length() / CM <= RAGDOLL_MIN_IMPULSE:
				continue
			if speed > best_speed:
				best_speed = speed
				best_at = st.get_contact_local_position(c)
				best_bone = ragdoll.body.names[i]
	if best_speed > 0.0:
		_ragdoll_open_at = _clock + RAGDOLL_GATE
		play_event("Foley.Event.Ragdoll", best_at, _map_clamped(best_speed, RAGDOLL_VOLUME), 1.0, {"source": "ragdoll", "bone": best_bone, "speed": best_speed})


func _ragdoll() -> Node:
	for c in player.components:
		if c.has_method("is_ragdoll") and "body" in c:
			return c
	return null


# ------------------------------------------------------------------ playback (AC_FoleyEvents.PlayFoleyEvent)

## Plays a foley event tag at a world position with the event's volume and pitch multipliers.
func _update_slide_sound(dt: float) -> void:
	var sliding: bool = character.is_sliding()
	var alive := is_instance_valid(_slide_voice) and not _slide_voice.is_queued_for_deletion()
	var ended := _slide_voice != null and not alive  # a wave finished while sliding: play the next
	if sliding and (not _was_sliding or ended):
		_slide_voice = play_event("Foley.Event.Slide.Loop", character.global_position, 1.0, 1.0, {"source": "slide"})
	elif not sliding and _was_sliding and alive:
		for v in _voices:
			if v[0] == _slide_voice:
				_slide_fading.append([v, SLIDE_FADE_OUT, v[1]])
		_slide_voice = null
	if is_instance_valid(_slide_voice):
		_slide_voice.global_position = character.global_position
	var keep := []
	for f in _slide_fading:
		f[1] -= dt
		if not is_instance_valid(f[0][0]):
			continue
		if f[1] <= 0.0:
			(f[0][0] as Node).queue_free()
			continue
		f[0][1] = f[2] + linear_to_db(f[1] / SLIDE_FADE_OUT)
		keep.append(f)
	_slide_fading = keep
	_was_sliding = sliding


## Plays a foley event; returns the voice (null when nothing plays).
func play_event(tag: String, at: Vector3, volume := 1.0, pitch := 1.0, info := {}) -> AudioStreamPlayer3D:
	var preset_name: String = _bank["events"].get(tag, "")
	if preset_name == "":
		return null  # GetSoundFromFoleyEvent fails: IsValid stops PlayFoleyEvent
	var preset: Dictionary = _bank["presets"][preset_name]
	var waves: Array = preset["waves"]
	if waves.is_empty():
		return null
	var index := _pick(preset_name, waves.size(), int(preset.get("no_repeats", 0)))
	var vol_lin := _rng.randf_range(db_to_linear(float(preset["volume_db"][0])), db_to_linear(float(preset["volume_db"][1])))
	var pitch_rand := _rng.randf_range(float(preset["pitch"][0]), float(preset["pitch"][1]))
	var amplitude := float(preset["source_volume"]) * float(preset["gain"]) * vol_lin * volume
	var e := {"time": _clock, "frame": _frame, "drawn": Engine.get_frames_drawn(), "tag": tag, "preset": preset_name,
		"wave": String(waves[index]["file"]).get_file(), "volume": volume, "pitch": pitch * pitch_rand,
		"amplitude": amplitude, "position": at, "side": "", "source": "", "clip": ""}
	e.merge(info, true)
	events.append(e)
	if _log != null:
		_log.store_line("E %d %d %.4f %s %s %s %.3f %.3f %s %s" % [_frame, Engine.get_frames_drawn(), _clock, tag, e["side"] if e["side"] != "" else "-", e["source"], amplitude, e["pitch"], e["wave"], e["clip"] if e["clip"] != "" else "-"])
	if not audible or amplitude <= 0.0:
		return null
	var stream := _stream(String(waves[index]["file"]))
	if stream == null:
		return null
	var voice := AudioStreamPlayer3D.new()
	voice.stream = stream
	voice.bus = _bus_name(preset)
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED   # same volume at any distance
	voice.attenuation_filter_db = 0.0
	voice.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	voice.max_db = 24.0
	voice.pitch_scale = maxf(pitch * pitch_rand, 0.01)
	add_child(voice)
	voice.global_position = at
	var base_db := linear_to_db(amplitude)
	voice.volume_db = base_db
	voice.finished.connect(voice.queue_free)
	voice.play()
	_voices.append([voice, base_db])
	return voice


## Random Get with No Repeats and shared state: none of the last N picks of this preset (N < size).
func _pick(preset: String, size: int, no_repeats: int) -> int:
	var recent: Array = _no_repeat.get(preset, [])
	var n := mini(no_repeats, size - 1)
	var choices := []
	for i in size:
		if not recent.slice(maxi(recent.size() - n, 0)).has(i):
			choices.append(i)
	var pick: int = choices[_rng.randi() % choices.size()] if not choices.is_empty() else _rng.randi() % size
	recent.append(pick)
	if recent.size() > 8:
		recent.pop_front()
	_no_repeat[preset] = recent
	return pick


static func _stream(file: String) -> AudioStream:
	if not _streams.has(file):
		var path := AUDIO + file.trim_prefix("audio/")
		_streams[file] = load(path) if ResourceLoader.exists(path) else null
	return _streams[file]


func _update_voices() -> void:
	var keep := []
	for v in _voices:
		if not is_instance_valid(v[0]) or (v[0] as Node).is_queued_for_deletion():
			continue
		keep.append(v)
	_voices = keep


## Where an event sounds: feet for steps, hands for hand plants and punches, else the body.
func _event_position(tag: String, side: String) -> Vector3:
	var bone := "pelvis"
	if side != "":
		var limb := "hand" if tag.contains("Handplant") or tag.contains("Punch") else "foot"
		bone = "%s_%s" % [limb, side.to_lower()]
	return _bone_world(bone)


func _bone_world(bone: String) -> Vector3:
	var i := skeleton.find_bone(bone)
	if i < 0:
		return character.global_position
	return (skeleton.global_transform * skeleton.get_bone_global_pose(i)).origin


static func _map_clamped(v: float, r: Array) -> float:
	return lerpf(r[2], r[3], clampf((v - r[0]) / (r[1] - r[0]), 0.0, 1.0))
