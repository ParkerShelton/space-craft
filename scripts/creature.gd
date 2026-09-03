class_name Creature
extends CharacterBody3D

## A procedurally-assembled blocky (Minecraft-style) creature. Body shape, size,
## color, and behavior are all generated per-planet from its seed (see
## Planet._derive_fauna/_make_species) instead of hand-modeled -- so what
## wildlife you find is as procedural as the ores. Built entirely from boxes,
## the same low-poly vertex-color aesthetic as the rest of the game.

var species: Dictionary = {}
var planet: Planet
var world: WorldManager

# NPCs (kind=="npc") are leashed to their home settlement instead of roaming
# the whole planet like wildlife -- home_radius 0 means no leash (fauna).
var _home_center := Vector3.ZERO
var _home_radius := 0.0

const GRAVITY_ACCEL := 14.0
const WANDER_MIN := 2.0
const WANDER_MAX := 5.0
const ATTACK_RANGE := 1.8
const ATTACK_COOLDOWN := 1.2
const ALIGN_SPEED := 3.0

# --- "lunger" attack pattern (species.pattern == "lunger", see Planet._make_species) ---
# chase -> circle (brief hesitation/strafe) -> telegraph or feint -> [feint:
# abort back to chase] or [attack: closing step + hit] -> recover -> chase.
# Blocking can preempt chase/circle (never an already-committed telegraph/
# attack) if the player visibly winds up a heavy swing. Getting staggered
# force-jumps straight to recover + a brief knockback, from any state.
const LUNGE_DURATION := 0.9      # safety cap; the real exit is closing to attack_range (see _lunger_ai)
const LUNGE_SPEED_MULT := 1.6    # a committed step, not a blink -- was 3.0, which blew straight through the player
const RECOVER_TIME := 0.9        # a real cooldown window -- this is the player's actual punish opportunity, Souls-style
const KNOCKBACK_TIME := 0.25
const KNOCKBACK_MULT := 3.0
const CIRCLE_MIN := 0.4
const CIRCLE_MAX := 0.8
const FEINT_RESET_TIME := 0.5
const BLOCK_MAX_TIME := 1.5      # safety cap in case is_heavy_telegraphed() gets stuck true
const BLOCK_DAMAGE_MULT := 0.2
const SWORD_SWING_DURATION := 0.55  # a smooth sin(t*PI) arc, same technique as the fish tail / player's own swing
# Everything above was originally tuned much faster (telegraph ~0.35-0.55s,
# a 0.3s swing) -- readable in isolated testing, but the user's actual
# complaint was that the whole exchange felt "too quick and jerky," nothing
# like a deliberate Souls-style read-and-punish fight. Slowed down across
# the board: a real windup you have time to actually see, a swing with some
# weight to it, and a recovery window worth punishing.
const ACCEL_RATE := 7.0  # how fast horizontal velocity eases toward its target -- see _land_physics

var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _attack_cd := 0.0
var _landing := false     # flyer: currently descending to perch on the ground
var _perched := false     # flyer: sitting on the ground, wings folded, will take off again
var _phase := 0.0
var _legs: Array = []       # hip pivots (Node3D), animated for a walk cycle
var _knees: Array = []      # secondary leg joint (calf), forward-only bend layered on the hip swing
var _arms: Array = []       # shoulder pivots (bipeds only), light counter-swing
var _elbows: Array = []     # secondary arm joint (forearm), same idea as _knees
var _tail_pivot: Node3D     # tail or fish tail-fin pivot, animated as a wag
var _segments: Array = []   # serpent body segments, animated as a wiggle
var _wings: Array = []      # flyer wing pivots, animated as a flap
var _model: Node3D
var _health := 20.0

# "lunger" pattern state (unused/harmless for every other pattern)
var _state := "chase"       # "chase" / "circle" / "telegraph" / "attack" / "recover" / "block"
var _state_t := 0.0
var _stagger := 0.0
var _lunge_target := Vector3.ZERO
var _knockback_dir := Vector3.ZERO
var _knockback_t := 0.0
var _is_feint := false          # set when telegraph starts, read only when it ends
var _circle_dir := 1.0          # +-1, which way to strafe during "circle"
var _was_blockable := false     # edge-tracks player.is_heavy_telegraphed() so the block roll fires once per charge
var _sword: Node3D              # held-weapon visuals (pattern == "lunger" only)
var _shield: Node3D             # null on a dual-wielder -- always null-check before use
var _offhand: Node3D            # second sword instead of a shield, when _dual_wield
var _dual_wield := false        # rolled per creature in _build_body, not per species
var _shield_rest_x := 0.0       # non-block target for _shield.rotation.x -- 0 for the pivot body, ARM_REST_FIX's counter-angle for the skeleton body
var _telegraph_total := 0.45    # the actual (jittered) duration chosen for the current telegraph
var _swing_t := 999.0           # counts up from 0 during "attack" (real clip duration or the pivot-fallback swing)
var _attack_clip_len := 0.0     # real clip length once playing, else SWORD_SWING_DURATION (pivot fallback)
var _hit_applied := false       # guards against applying one swing's damage twice
var _engaged := false           # aggro hysteresis latch -- see _land_physics
var _hitbox: CollisionShape3D   # disabled while dying so a corpse isn't solid

# --- lunger skeleton rig: a real Skeleton3D (from the imported FBX) instead
# of the hand-built pivot chain, so real animation clips can drive it. Only
# used if the rig loads; otherwise falls back to the pivot-based body/anim
# (see _build_biped_skeleton, _animate). Bone indices are -1 if not found.
const SKELETON_SCALE := 1.0     # first guess -- Mixamo's ~1.8m rig is already close to this game's voxel-unit creature height

# --- animation library -------------------------------------------------------
# One folder per state under res://anims/, holding any number of interchangeable
# clips -- drop another .fbx into a folder and it joins the random rotation for
# that state automatically, no code change. Keys here are the STATE names used
# throughout this file; values are the folder names on disk.
const CLIP_DIRS := {
	"idle": "idle",
	"run": "run",
	"attack": "attack",
	"block": "block",
	"die": "die",
	"roll": "roll",
	"hit": "hit-hit",                  # flinch when a hit lands on an unguarded creature
	"hit_block": "hit-shield-block",   # hit absorbed on a raised shield -- shield users only
}
const ANIM_ROOT := "res://anims/"

# Every Mixamo export names its single clip "mixamo_com", so clips are keyed by
# "<state>_<index>" in the shared AnimationLibrary instead.
const MIXAMO_CLIP := "mixamo_com"

# Loaded ONCE for the whole game, not per creature: state -> Array[Animation].
# Animation resources are pure data and are safely shared between
# AnimationPlayers (they address bones by node path, and every creature rig has
# the same Skeleton3D layout), so this avoids instantiating a dozen FBX scenes
# for every single enemy that spawns.
static var _clip_cache: Dictionary = {}
static var _clip_cache_built := false
static var _base_rig_path := ""


## Scans the state folders once and caches every clip's Animation resource.
## NOTE: this uses DirAccess to LIST the folders, which works when running from
## source (what this project does today). An exported build ships the imported
## .scn files rather than the original .fbx, so a release export would need this
## list baked out at build time instead -- revisit before shipping.
static func _build_clip_cache() -> void:
	if _clip_cache_built:
		return
	_clip_cache_built = true
	for state in CLIP_DIRS:
		var dir_path: String = ANIM_ROOT + str(CLIP_DIRS[state])
		var da := DirAccess.open(dir_path)
		if da == null:
			push_warning("[creature] missing animation folder: %s" % dir_path)
			continue
		var anims: Array = []
		var files: PackedStringArray = da.get_files()
		files.sort()  # stable order so a clip's index means the same thing run to run
		for f in files:
			# The editor also lists the sidecar "X.fbx.import"; only take sources.
			if not f.to_lower().ends_with(".fbx"):
				continue
			var res_path: String = dir_path + "/" + f
			var scene: PackedScene = load(res_path) as PackedScene
			if scene == null:
				push_warning("[creature] could not load %s" % res_path)
				continue
			if _base_rig_path == "":
				_base_rig_path = res_path
			var inst: Node = scene.instantiate()
			var ap: AnimationPlayer = null
			for c in inst.get_children():
				if c is AnimationPlayer:
					ap = c
			if ap != null and ap.has_animation(MIXAMO_CLIP):
				var a: Animation = ap.get_animation(MIXAMO_CLIP)
				# Only locomotion loops; one-shots (attack, hit, die) must end.
				a.loop_mode = Animation.LOOP_LINEAR if state in ["idle", "run"] else Animation.LOOP_NONE
				anims.append(a)
			inst.queue_free()
		if not anims.is_empty():
			_clip_cache[state] = anims

# Measured the blade's own pointing direction (grip->tip) against the
# to-player vector across the WHOLE clip: it swings AWAY from the player for
# roughly the first 30-40% (a real backswing -- dot goes as low as -0.65),
# then swings sharply TOWARD the player from ~40-80% (dot > 0.7, peaking at
# 0.997 around 70%), then a brief away-swinging follow-through/reset at the
# very end. Playing the WHOLE clip during "attack" meant the player watched
# the away-swinging backswing as part of the attack itself -- which is what
# actually read as "it swings away from me," no matter when damage applied.
# Fix: split the clip at the direction crossover instead. The away-swinging
# first portion becomes the TELEGRAPH windup itself (scrubbed through by hand
# as the telegraph timer counts down -- see _animate) instead of a separate
# hand-posed pose; "attack" only plays the clip forward from that crossover,
# so what the player sees during "attack" is just the toward-player swing.
const WINDUP_END_FRACTION := 0.4   # telegraph shows clip[0 .. this] -- the real backswing
const ATTACK_END_FRACTION := 0.85  # attack shows clip[WINDUP_END_FRACTION .. this], then cuts to recover -- skips the away-swinging tail follow-through entirely
const ATTACK_HIT_FRACTION := 0.65  # absolute fraction of the FULL clip (not the attack sub-range) -- falls well inside the toward-player window above
var _skeleton: Skeleton3D
var _anim_player: AnimationPlayer
var _clip_keys: Dictionary = {}   # state -> Array[String] of keys in this rig's library
var _cur_clip := ""               # library key currently playing, "" if none
var _oneshot_state := ""          # state whose one-shot clip is playing (hit/die/etc), "" if none
var _bi_r_arm := -1
var _bi_r_forearm := -1
var _bi_l_arm := -1
var _bi_l_forearm := -1
var _bi_r_thigh := -1
var _bi_r_shin := -1
var _bi_l_thigh := -1
var _bi_l_shin := -1
# The rig's bind pose holds the arms out to the sides (T/A-pose), not hanging
# down the way the old pivot-based body assumed -- confirmed by measuring the
# actual bone positions (the hand ended up ~0.6 units straight out to the
# side, not below the shoulder). This first-guess correction rotates the
# UPPER arm bone from that bind pose into a natural hanging pose before any
# of my own animation deltas are added on top (see _set_arm_pose); the
# forearm needs no separate fix since its OWN rest is a straight continuation
# of wherever the (now-corrected) upper arm points.
const ARM_REST_FIX := Quaternion(Vector3.RIGHT, 1.4)


func configure(sp: Dictionary, p: Planet, w: WorldManager, home_center := Vector3.ZERO, home_radius := 0.0) -> void:
	species = sp
	planet = p
	world = w
	_home_center = home_center
	_home_radius = home_radius
	_health = float(sp.get("health", 20.0))
	_stagger = float(sp.get("stagger_max", 3.0))
	_build_body()
	rotate_y(randf() * TAU)
	_build_collision()


func _build_collision() -> void:
	var scale_f: float = species.get("scale", 1.0)
	var cap := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.42 * scale_f
	shape.height = 1.5 * scale_f
	cap.shape = shape
	cap.position = Vector3(0, 0.75 * scale_f, 0)
	add_child(cap)
	_hitbox = cap  # kept so a dying creature can stop blocking the player mid-death-clip


# --- body assembly (boxes only, per body plan) ---------------------------------

## Fraction of lungers that fight with two swords instead of sword+shield.
## Rolled PER CREATURE (not per species) so a single planet's enemies are a
## visible mix rather than all-or-nothing -- there's typically only one enemy
## species per planet, so rolling it in Planet._make_species would make every
## enemy you meet there identical.
const DUAL_WIELD_CHANCE := 0.35

func _build_body() -> void:
	_model = Node3D.new()
	add_child(_model)
	# Note: a plain randf() means the roll is re-made if this creature is ever
	# rebuilt (e.g. respawned after a reload) -- fine while fauna are transient,
	# but derive it from a stable per-creature id if enemies ever persist.
	_dual_wield = species.get("pattern", "") == "lunger" and randf() < DUAL_WIELD_CHANCE
	var s: float = species.get("scale", 1.0)
	var color: Color = species.get("color", Color.WHITE)
	var accent: Color = species.get("accent", color)
	match species.get("body", "quad"):
		"quad": _build_quad(s, color, accent)
		"biped": _build_biped(s, color, accent)
		"serpent": _build_serpent(s, color, accent)
		"fish": _build_fish(s, color, accent)
		"flyer": _build_flyer(s, color, accent)
		_: _build_quad(s, color, accent)


func _mk_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _mk_pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _build_quad(s: float, color: Color, accent: Color) -> void:
	var leg_len := 0.5 * s
	var torso := Vector3(0.85, 0.6, 1.5) * s
	var torso_y := leg_len + torso.y * 0.5
	_mk_box(_model, torso, Vector3(0, torso_y, 0), color)
	_mk_box(_model, Vector3(0.55, 0.5, 0.55) * s,
		Vector3(0, torso_y + torso.y * 0.15, -torso.z * 0.5 - 0.22 * s), accent)
	var hx := torso.x * 0.5 - 0.08 * s
	var hz := torso.z * 0.5 - 0.25 * s
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var pivot := _mk_pivot(_model, Vector3(sx * hx, leg_len, sz * hz))
			_mk_box(pivot, Vector3(0.22, leg_len, 0.22) * s, Vector3(0, -leg_len * 0.5, 0), accent)
			_legs.append(pivot)
	_tail_pivot = _mk_pivot(_model, Vector3(0, torso_y + torso.y * 0.1, torso.z * 0.5))
	_tail_pivot.rotation.x = -0.5
	_mk_box(_tail_pivot, Vector3(0.16, 0.16, 0.6) * s, Vector3(0, 0, 0.3 * s), color)


func _build_biped(s: float, color: Color, accent: Color) -> void:
	if species.get("pattern", "") == "lunger" and _build_biped_skeleton(s, color, accent):
		return
	var leg_len := 0.6 * s
	var torso := Vector3(0.55, 0.85, 0.5) * s
	var torso_y := leg_len + torso.y * 0.5
	_mk_box(_model, torso, Vector3(0, torso_y, 0), color)
	_mk_box(_model, Vector3(0.45, 0.45, 0.45) * s, Vector3(0, torso_y + torso.y * 0.65, 0), accent)
	# Legs -- thigh + shin as two cubes joined at a knee pivot that gets its own
	# small forward-only bend layered on top of the hip swing in _animate, for
	# a less stiff, more "alive" walk than one rigid box per leg.
	var thigh_len := leg_len * 0.55
	var shin_len := leg_len * 0.5
	for sx in [-1, 1]:
		var hip := _mk_pivot(_model, Vector3(sx * 0.18 * s, leg_len, 0))
		_mk_box(hip, Vector3(0.2, thigh_len, 0.22) * s, Vector3(0, -thigh_len * 0.5, 0), accent)
		var knee := _mk_pivot(hip, Vector3(0, -thigh_len, 0))
		_mk_box(knee, Vector3(0.17, shin_len, 0.19) * s, Vector3(0, -shin_len * 0.5, 0), accent)
		_legs.append(hip)
		_knees.append(knee)
	# Arms -- same two-segment idea (upper arm + forearm via an elbow pivot).
	# Makes a biped actually read as humanoid instead of a legged torso.
	# arm_count is data-driven (species dict) for future extra-limb variety,
	# but only 2 is used today.
	var upper_len := 0.3 * s
	var fore_len := 0.28 * s
	var arm_count: int = int(species.get("arm_count", 2))
	var shoulder_y := torso_y + torso.y * 0.32
	var is_lunger_body: bool = species.get("pattern", "") == "lunger"
	for i in arm_count:
		var sx := -1.0 if i % 2 == 0 else 1.0
		var shoulder := _mk_pivot(_model, Vector3(sx * (torso.x * 0.5 + 0.1 * s), shoulder_y, 0))
		# A "lunger"'s arms angle out from the body a bit at rest -- otherwise
		# a held sword/shield hangs flush against the torso/leg silhouette
		# and all but disappears into it from most viewing angles.
		if is_lunger_body:
			# +sx (not -sx) swings a hanging arm OUTWARD, away from center --
			# the sign I originally picked here was backwards, which actually
			# pulled the arm INWARD into the torso, making the clipping/
			# occlusion problem worse instead of better.
			shoulder.rotation.z = sx * 0.4
		_mk_box(shoulder, Vector3(0.16, upper_len, 0.16) * s, Vector3(0, -upper_len * 0.5, 0), color)
		var elbow := _mk_pivot(shoulder, Vector3(0, -upper_len, 0))
		_mk_box(elbow, Vector3(0.14, fore_len, 0.14) * s, Vector3(0, -fore_len * 0.5, 0), color)
		_arms.append(shoulder)
		_elbows.append(elbow)
	# A "lunger" gets a visible sword (right hand) + shield (left hand) -- the
	# whole point of the user's ask ("actually feel like a real player"), and
	# reuses the same box-mesh view-model style as the player's held weapon
	# (see player.gd:_build_held_weapon). Held at the forearm's end (the
	# hand), so they follow the arm/elbow swing animation naturally.
	if species.get("pattern", "") == "lunger" and _elbows.size() >= 2:
		_sword = _build_sword(_elbows[1], s, fore_len)
		if _dual_wield:
			_offhand = _build_sword(_elbows[0], s, fore_len)
		else:
			_shield = _build_shield(_elbows[0], s, fore_len)


## Applies an animation delta ON TOP of ARM_REST_FIX rather than replacing it
## -- set_bone_pose_rotation overwrites the whole pose each call, so every
## upper-arm pose write needs to go through here, not straight to the
## skeleton, or it'll snap back to the T/A-pose bind orientation.
func _set_arm_pose(bone_idx: int, delta_angle: float) -> void:
	_skeleton.set_bone_pose_rotation(bone_idx, ARM_REST_FIX * Quaternion(Vector3.RIGHT, delta_angle))


## AnimationPlayer.stop() halts playback but does NOT revert the bone poses it
## was driving back to rest -- they stay exactly where the clip's last-played
## frame left them. Every non-attack state only hand-poses the arms/forearms/
## thighs/shins every frame (overwriting whatever the clip left there), but
## NOTHING ever touches Hips/Spine/Spine1/Spine2/Neck/Head -- so after a real
## clip plays, those bones stay frozen at the swing's final (often twisted/
## crouched) pose forever, even while just walking around afterward. Call
## this right after every _anim_player.stop() to put the whole skeleton back
## to a clean rest before any hand-posing resumes.
func _reset_skeleton_pose() -> void:
	for i in _skeleton.get_bone_count():
		_skeleton.reset_bone_pose(i)


## Where bone `child_bi`'s REST origin falls in bone `parent_bi`'s OWN local
## rest frame -- i.e. exactly the value _mk_box's `pos` needs to place a box
## reaching from `parent_bi` to `child_bi`, since an unposed BoneAttachment3D's
## local frame IS the bone's own rest frame. Measured directly off the loaded
## rig rather than guessed/copied, so box geometry actually matches whatever
## skeleton got imported instead of numbers tuned for the old hand-built pivot
## chain's own (unrelated) convention.
func _bone_child_offset(parent_bi: int, child_bi: int) -> Vector3:
	if parent_bi < 0 or child_bi < 0:
		return Vector3.ZERO
	var parent_rest := _skeleton.get_bone_global_rest(parent_bi)
	return parent_rest.affine_inverse() * _skeleton.get_bone_global_rest(child_bi).origin


func _mk_bone_attachment(bone_idx: int) -> BoneAttachment3D:
	var att := BoneAttachment3D.new()
	_skeleton.add_child(att)
	att.bone_idx = bone_idx
	return att


func _has_clips(state: String) -> bool:
	return _clip_keys.has(state) and not (_clip_keys[state] as Array).is_empty()


## Picks a random clip for `state` and plays it. Re-picking on every call would
## restart the clip every frame, so a looping state already playing one of its
## own clips is left alone -- pass force=true for one-shots (a new hit should
## restart the flinch even if a flinch is already playing).
func _play_state(state: String, force := false, speed := 1.0) -> bool:
	if _anim_player == null or not _has_clips(state):
		return false
	var keys: Array = _clip_keys[state]
	if not force and _cur_clip in keys and _anim_player.is_playing():
		_anim_player.speed_scale = speed
		return true
	var key: String = keys[randi() % keys.size()]
	_cur_clip = key
	_anim_player.play(key)
	_anim_player.speed_scale = speed
	return true


## Length of whatever clip is currently playing (0 if none).
func _cur_clip_len() -> float:
	if _anim_player == null or _cur_clip == "" or not _anim_player.has_animation(_cur_clip):
		return 0.0
	return _anim_player.get_animation(_cur_clip).length


## Plays a one-shot reaction (hit / shield-block / death). Returns the clip's
## length so callers can time a state around it, or 0.0 if the state has no
## clips -- in which case the caller must not wait for an animation that will
## never play.
func _play_oneshot(state: String) -> float:
	if not _play_state(state, true):
		return 0.0
	_oneshot_state = state
	return _cur_clip_len()


## Builds a lunger's body on a real Skeleton3D (the imported FBX rig) instead
## of the hand-built pivot chain every other biped uses, so real animation
## clips (currently one sword swing, more planned per the user) can drive the
## whole body during "attack" -- non-attack states still use the exact poses
## already tuned this session, just applied as bone-pose deltas instead of
## Node3D rotations (see _animate). Box sizes/colors/offsets are the same
## numbers already screenshot-verified for the pivot body -- reparented onto
## bones, not redesigned. Returns false (caller falls back to the normal
## pivot body) if the rig failed to load for any reason, so a bad/missing
## asset can't leave the creature with no body at all.
func _build_biped_skeleton(s: float, color: Color, accent: Color) -> bool:
	_build_clip_cache()
	if _base_rig_path == "":
		return false  # no clips found at all -- fall back to the pivot body
	var base_scene: PackedScene = load(_base_rig_path) as PackedScene
	if base_scene == null:
		return false
	var rig: Node3D = base_scene.instantiate() as Node3D
	if rig == null:
		return false
	_model.add_child(rig)
	rig.scale = Vector3.ONE * SKELETON_SCALE
	# This rig's visual FRONT is its local +Z, but look_at (used everywhere in
	# this file to aim a creature) points a node's -Z at the target -- so the
	# character renders exactly 180 degrees backwards, both running and
	# attacking, until corrected here.
	#
	# Established from the animation's own data, not from a bone-axis guess:
	# in an IN-PLACE run cycle the planted foot must slide BACKWARD relative to
	# the hips (the treadmill effect), so the stance foot's travel direction is
	# unambiguously character-rearward. Measured across the clip, BOTH feet
	# slide toward -Z during stance (mean -0.014 right / -0.016 left), putting
	# forward at +Z. Independently corroborated by the run clip's original
	# baked root motion, which translated the Hips from Z=0.02 to Z=+2.31 --
	# i.e. a character running forward travels toward +Z.
	#
	# Do NOT "verify" this by dotting a Mixamo bone's local -Z against velocity:
	# that assumes -Z is the visual front, which is precisely the assumption
	# this rig violates. Such a test reads +1.0 while the character is visibly
	# running backwards, and it is what made several earlier rounds of this fix
	# measure clean while the actual game looked wrong.
	rig.rotation.y = PI
	for c in rig.get_children():
		if c is Skeleton3D:
			_skeleton = c
		elif c is AnimationPlayer:
			_anim_player = c
	if _skeleton == null:
		rig.queue_free()
		_anim_player = null
		return false

	var bi_hips := _skeleton.find_bone("mixamorig_Hips")
	var bi_spine := _skeleton.find_bone("mixamorig_Spine2")
	var bi_neck := _skeleton.find_bone("mixamorig_Neck")
	var bi_head := _skeleton.find_bone("mixamorig_Head")
	var bi_head_top := _skeleton.find_bone("mixamorig_HeadTop_End")
	var bi_r_hand := _skeleton.find_bone("mixamorig_RightHand")
	var bi_l_hand := _skeleton.find_bone("mixamorig_LeftHand")
	_bi_r_arm = _skeleton.find_bone("mixamorig_RightArm")
	_bi_r_forearm = _skeleton.find_bone("mixamorig_RightForeArm")
	_bi_l_arm = _skeleton.find_bone("mixamorig_LeftArm")
	_bi_l_forearm = _skeleton.find_bone("mixamorig_LeftForeArm")
	_bi_r_thigh = _skeleton.find_bone("mixamorig_RightUpLeg")
	_bi_r_shin = _skeleton.find_bone("mixamorig_RightLeg")
	_bi_l_thigh = _skeleton.find_bone("mixamorig_LeftUpLeg")
	_bi_l_shin = _skeleton.find_bone("mixamorig_LeftLeg")
	if bi_spine < 0 or _bi_r_arm < 0 or _bi_l_arm < 0 or _bi_r_thigh < 0 or _bi_l_thigh < 0:
		rig.queue_free()  # rig doesn't match the expected Mixamo bone names -- bail out cleanly
		_skeleton = null
		_anim_player = null
		return false

	# Every box below is sized/centered from the REAL rig's own rest-pose bone
	# positions (_bone_child_offset), not guessed constants -- the previous
	# version copied numbers straight from the old hand-built pivot chain,
	# which used its OWN unrelated convention (children hang along a pivot's
	# local -Y). This rig's actual bones put a child at local +Y from its
	# parent, and the old numbers didn't account for that at all: the torso
	# was sized for a completely different (much taller) span and centered
	# with the wrong-sign offset, which is why it swallowed the head whole.
	if bi_hips >= 0 and bi_neck >= 0:
		var hips_off := _bone_child_offset(bi_spine, bi_hips)
		var neck_off := _bone_child_offset(bi_spine, bi_neck)
		var torso := Vector3(0.34, (neck_off - hips_off).length(), 0.26) * s
		_mk_box(_mk_bone_attachment(bi_spine), torso, (hips_off + neck_off) * 0.5 * s, color)
	if bi_head >= 0:
		if bi_head_top >= 0:
			var head_off := _bone_child_offset(bi_head, bi_head_top)
			# A cube's flat faces undershoot a rounded head's actual silhouette
			# at the same corner-to-corner span -- pad it out a little, but not
			# enough to end up wider than the torso (1.5x did that).
			var head_size := head_off.length() * 1.2
			_mk_box(_mk_bone_attachment(bi_head), Vector3.ONE * head_size * s, head_off * 0.5 * s, accent)
		else:
			_mk_box(_mk_bone_attachment(bi_head), Vector3(0.35, 0.35, 0.35) * s, Vector3(0, 0.12 * s, 0), accent)
	var upper_off := _bone_child_offset(_bi_r_arm, _bi_r_forearm)
	var fore_off := _bone_child_offset(_bi_r_forearm, bi_r_hand) if bi_r_hand >= 0 else Vector3(0, 0.28, 0)
	_mk_box(_mk_bone_attachment(_bi_r_arm), Vector3(0.16, upper_off.length(), 0.16) * s, upper_off * 0.5 * s, color)
	_mk_box(_mk_bone_attachment(_bi_r_forearm), Vector3(0.14, fore_off.length(), 0.14) * s, fore_off * 0.5 * s, color)
	_mk_box(_mk_bone_attachment(_bi_l_arm), Vector3(0.16, upper_off.length(), 0.16) * s, upper_off * 0.5 * s, color)
	_mk_box(_mk_bone_attachment(_bi_l_forearm), Vector3(0.14, fore_off.length(), 0.14) * s, fore_off * 0.5 * s, color)
	var thigh_off := _bone_child_offset(_bi_r_thigh, _bi_r_shin)
	var bi_r_foot := _skeleton.find_bone("mixamorig_RightFoot")
	var shin_off := _bone_child_offset(_bi_r_shin, bi_r_foot) if bi_r_foot >= 0 else Vector3(0, 0.44, 0)
	_mk_box(_mk_bone_attachment(_bi_r_thigh), Vector3(0.2, thigh_off.length(), 0.22) * s, thigh_off * 0.5 * s, accent)
	_mk_box(_mk_bone_attachment(_bi_r_shin), Vector3(0.17, shin_off.length(), 0.19) * s, shin_off * 0.5 * s, accent)
	_mk_box(_mk_bone_attachment(_bi_l_thigh), Vector3(0.2, thigh_off.length(), 0.22) * s, thigh_off * 0.5 * s, accent)
	_mk_box(_mk_bone_attachment(_bi_l_shin), Vector3(0.17, shin_off.length(), 0.19) * s, shin_off * 0.5 * s, accent)

	# Sword/shield hang from the hand bones directly (their origin IS the
	# wrist), so no "-reach" offset is needed the way the pivot-fallback body
	# needed to reach past the whole forearm length -- pass reach=0.
	var r_hand_att := _mk_bone_attachment(bi_r_hand) if bi_r_hand >= 0 else _mk_bone_attachment(_bi_r_forearm)
	var l_hand_att := _mk_bone_attachment(bi_l_hand) if bi_l_hand >= 0 else _mk_bone_attachment(_bi_l_forearm)
	_sword = _build_sword(r_hand_att, s, 0.0)
	# The hand bones inherit ARM_REST_FIX's rotation through the parent chain
	# (nothing else in the forearm/hand rest orientation adds further net
	# rotation), which the sword/shield geometry -- designed assuming an
	# unrotated hand, matching the pivot-fallback body -- doesn't account for.
	# Counter-rotate by the same amount to bring them back level.
	_sword.rotation.x = -1.4
	if _dual_wield:
		# Offhand sword takes the SAME -1.4 as the main hand. Not assumed --
		# solved for: took the right sword's achieved blade direction in the
		# creature's local frame, mirrored it across the sagittal plane, and
		# computed the rotation carrying the blade axis (local -Y) onto that
		# target in the left hand's own frame. The answer came back as
		# (-1.4, ~0, ~0), i.e. both arms' bone bases share an orientation
		# convention here rather than being mirrored. (A single-axis sweep is
		# NOT a valid way to check this -- one run appeared to show a 46 degree
		# residual purely because the creature kept animating between samples,
		# so each sample used a different reference frame.)
		_offhand = _build_sword(l_hand_att, s, 0.0)
		_offhand.rotation.x = -1.4
	else:
		_shield = _build_shield(l_hand_att, s, 0.0)
		# The hand bone attachment's rest basis isn't a simple hang-down frame like
		# the old pivot system's -- measured its actual world-space axes directly
		# (global_transform.basis) rather than guessing signs: the shield's own
		# "normal" axis (local X) already points forward correctly, but its
		# "height" axis (local Y, the board's long 0.9-unit dimension) was pointing
		# ~70 degrees off vertical, into the horizontal plane, which is what read
		# as a tilted diamond instead of a flat upright board. Solved for the
		# exact roll needed to bring that axis to true up: 1.4 (the old guess) +
		# 1.2266 rad of additional roll around the shared axis.
		_shield.rotation.x = 2.6266
		_shield_rest_x = 2.6266  # _animate's shield-raise lerp must target this, not 0.0, or it erases the correction every frame

	# Register every cached clip into THIS rig's animation library. The clips
	# all come from Mixamo exports that share the literal name "mixamo_com", so
	# each is keyed "<state>/<index>" instead; _clip_keys records which keys
	# belong to which state so _play_state can pick among them at random.
	var lib_names := _anim_player.get_animation_library_list()
	if lib_names.is_empty():
		return true
	var lib := _anim_player.get_animation_library(lib_names[0])
	for state in _clip_cache:
		var keys: Array = []
		var arr: Array = _clip_cache[state]
		for i in arr.size():
			# "/" is reserved -- AnimationPlayer parses "library/clip" -- so the
			# per-state key uses "_". (":" and "," are rejected too.)
			var key := "%s_%d" % [state, i]
			if not lib.has_animation(key):
				lib.add_animation(key, arr[i])
			keys.append(key)
		_clip_keys[state] = keys
	return true


# An emissive variant of _mk_box -- glows regardless of scene lighting/ambient
# tint, unlike a plain albedo color which a near-white blade turned out to
# pick up a strong blue cast from the space-ambient light in practice.
func _mk_glow_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, energy: float) -> void:
	var mi := _mk_box(parent, size, pos, color)
	var mat := mi.material_override as StandardMaterial3D
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy


const BLADE_GLOW := Color(1.0, 0.45, 0.15)  # a hot energy-blade orange, distinct from the pistol's cyan

func _build_sword(hand: Node3D, s: float, reach: float) -> Node3D:
	var _sword := Node3D.new()
	hand.add_child(_sword)
	_sword.position = Vector3(0, -reach, 0.03 * s)
	# Grip, crossguard, then blade -- each stacked further NEGATIVE-Y from the
	# hand (i.e. continuing past the fist, away from the elbow). Getting this
	# sign backwards was the original bug: a +Y blade offset put it back UP
	# the forearm, overlapping the arm itself instead of extending past the
	# hand -- which is why it barely read as a sword at all. Sized boldly (not
	# realistically) and made a glowing energy blade -- a thin "realistic"
	# steel-colored blade turned out to be nearly invisible at normal
	# gameplay camera distance, especially once ambient lighting tinted it.
	_mk_box(_sword, Vector3(0.1, 0.22, 0.1) * s, Vector3(0, -0.1 * s, 0), Color(0.25, 0.2, 0.15))          # grip
	_mk_box(_sword, Vector3(0.36, 0.06, 0.06) * s, Vector3(0, -0.21 * s, 0), Color(0.5, 0.42, 0.3))        # crossguard -- wider than the blade, so it actually registers as a hilt
	_mk_glow_box(_sword, Vector3(0.13, 0.8, 0.05) * s, Vector3(0, -0.61 * s, 0), BLADE_GLOW, 1.8)          # blade
	return _sword


func _build_shield(hand: Node3D, s: float, reach: float) -> Node3D:
	var _shield := Node3D.new()
	hand.add_child(_shield)
	# Offset outward from the arm (not straight down) so the body doesn't hide it.
	_shield.position = Vector3(0.2 * s, -reach * 0.5, 0.07 * s)
	# Board size cut from 0.9x0.65 -- at the original size, attached rigidly
	# to the hand, it dominated/overlapped every busy pose (attack windup,
	# the clip's own crouched start frame) badly enough to read as "the model
	# is broken" rather than "a shield is swinging with the arm."
	_mk_box(_shield, Vector3(0.09, 0.7, 0.5) * s, Vector3(0, 0, 0), Color(0.58, 0.6, 0.64))                # board -- cool steel-gray, deliberately distinct from the warm torso/accent colors so it doesn't just blend into the body's silhouette
	_mk_glow_box(_shield, Vector3(0.11, 0.18, 0.18) * s, Vector3(0.07 * s, 0, 0), BLADE_GLOW, 1.2)         # boss -- same glow color as the blade, reads as "this enemy's kit"
	return _shield


func _build_serpent(s: float, color: Color, accent: Color) -> void:
	var n := 5
	var seg_len := 0.5 * s
	# Segment 0 (i=0, the largest -- the head) sits at the root's own origin,
	# with the rest of the body trailing BEHIND it (+Z, matching every other
	# creature's own head-at-front/tail-at-back convention). The previous
	# sign put the head at the origin but stacked the REST of the body ahead
	# of it in -Z (the actual forward/direction-of-travel axis, per look_at's
	# convention elsewhere in this file) -- the tail end was consistently the
	# leading edge, so the whole creature visibly slithered tail-first.
	for i in n:
		var c := color if i % 2 == 0 else accent
		var sz := lerpf(0.55, 0.28, float(i) / float(n - 1)) * s
		var pos := Vector3(0, sz * 0.5, float(i) * seg_len)
		_segments.append(_mk_box(_model, Vector3(sz, sz, seg_len * 1.05), pos, c))


func _build_flyer(s: float, color: Color, accent: Color) -> void:
	var body := Vector3(0.4, 0.32, 0.75) * s
	_mk_box(_model, body, Vector3.ZERO, color)
	_mk_box(_model, Vector3(0.32, 0.3, 0.32) * s, Vector3(0, body.y * 0.1, -body.z * 0.5 - 0.15 * s), accent)
	for sx in [-1, 1]:
		var pivot := _mk_pivot(_model, Vector3(sx * body.x * 0.45, body.y * 0.2, 0))
		_mk_box(pivot, Vector3(0.75, 0.06, 0.32) * s, Vector3(sx * 0.4 * s, 0, 0), accent)
		_wings.append(pivot)
	_tail_pivot = _mk_pivot(_model, Vector3(0, 0, body.z * 0.5))
	_mk_box(_tail_pivot, Vector3(0.05, 0.3, 0.3) * s, Vector3(0, 0, 0.15 * s), accent)


func _build_fish(s: float, color: Color, accent: Color) -> void:
	var body := Vector3(0.34, 0.34, 1.0) * s
	_mk_box(_model, body, Vector3.ZERO, color)
	_tail_pivot = _mk_pivot(_model, Vector3(0, 0, body.z * 0.5))
	_mk_box(_tail_pivot, Vector3(0.06, 0.32, 0.35) * s, Vector3(0, 0, 0.17 * s), accent)
	for sx in [-1, 1]:
		_mk_box(_model, Vector3(0.05, 0.05, 0.28) * s, Vector3(sx * body.x * 0.6, -0.02 * s, 0.05 * s), accent)
	_mk_box(_model, Vector3(0.05, 0.22, 0.22) * s, Vector3(0, body.y * 0.6, -0.05 * s), accent)


# --- movement / AI --------------------------------------------------------------

func _snap_up(v: Vector3) -> Vector3:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


func _align_up(up: Vector3, delta: float) -> void:
	var body_up := global_transform.basis.y
	var dot := clampf(body_up.dot(up), -1.0, 1.0)
	if dot < -0.9999:
		global_transform.basis = Basis(global_transform.basis.x, PI) * global_transform.basis
	elif dot < 0.9999:
		var full := Quaternion(body_up, up)
		var step := Quaternion.IDENTITY.slerp(full, clampf(delta * ALIGN_SPEED, 0.0, 1.0))
		global_transform.basis = Basis(step) * global_transform.basis
	global_transform.basis = global_transform.basis.orthonormalized()


func _physics_process(delta: float) -> void:
	# Dying runs no AI and no _animate: the death clip owns the whole skeleton
	# for its duration, and anything else posing bones would fight it. Gravity
	# still applies so a creature killed mid-air falls rather than hanging.
	if _state == "dying":
		_state_t -= delta
		var gd := world.gravity_at(global_position) if world != null else Vector3.DOWN * 9.8
		var upd := -_snap_up(gd) if gd.length() > 0.01 else Vector3.UP
		var vu := velocity.dot(upd) - GRAVITY_ACCEL * delta
		if is_on_floor():
			vu = maxf(vu, 0.0)
		velocity = upd * vu
		up_direction = upd
		move_and_slide()
		if _state_t <= 0.0:
			queue_free()
		return
	match species.get("kind", "land"):
		"fish": _swim_physics(delta)
		"air": _fly_physics(delta)
		_: _land_physics(delta)  # "land" and "cave" both walk the same way
	_animate(delta)
	if _attack_cd > 0.0:
		_attack_cd -= delta


func _player_pos():
	if world != null and world.player != null and is_instance_valid(world.player):
		return world.player.global_position
	return null


func _land_physics(delta: float) -> void:
	var g := world.gravity_at(global_position) if world != null else Vector3.DOWN * 9.8
	var up := -_snap_up(g) if g.length() > 0.01 else Vector3.UP
	_align_up(up, delta)

	var speed: float = species.get("speed", 3.0)
	var temperament: String = species.get("temperament", "neutral")
	var wish := Vector3.ZERO
	var moving_speed := speed
	var ppos = _player_pos()
	var handled := false
	# _lunger_ai aims the body itself (it must keep facing the player even while
	# strafing sideways or standing still), so the generic movement-direction
	# look_at at the bottom of this function must NOT also run for it. Two
	# look_at calls per frame pulling toward DIFFERENT targets -- the player vs.
	# the "circle" state's sideways strafe wish, a full 90 degrees apart -- is a
	# per-frame tug-of-war, and it read in-game as the body jittering/vibrating
	# rather than turning cleanly.
	var facing_owned := false

	if ppos != null:
		var to_player: Vector3 = ppos - global_position
		var dist := to_player.length()
		# Hysteresis on the aggro range: engage at aggro_range, but don't
		# DISengage until well outside it. With a single hard threshold, a
		# creature sitting near the boundary flipped between "chase the player"
		# and "wander randomly" every few frames -- and since those two branches
		# aim the body at completely different targets (the player vs. a random
		# wander heading), the body whipped back and forth. Measured at the
		# boundary: 4.2 deg/frame of facing swing with spikes past 20, versus
		# ~0.5-0.8 deg/frame in every committed state. Chasing also drags the
		# creature back inside the range, so the flip-flop sustains itself
		# instead of settling.
		var aggro: float = float(species.get("aggro_range", 12.0))
		if _engaged:
			if dist > aggro * 1.35:
				_engaged = false
		elif dist < aggro:
			_engaged = true
		if temperament == "hostile" and _engaged:
			handled = true
			if species.get("pattern", "") == "lunger":
				var r := _lunger_ai(delta, up, ppos, dist, to_player)
				wish = r["wish"]
				moving_speed = speed * float(r["speed_mult"])
				facing_owned = true
			else:
				wish = to_player - up * to_player.dot(up)
				if dist < ATTACK_RANGE and _attack_cd <= 0.0:
					if world.player.has_method("take_damage"):
						world.player.take_damage(float(species.get("damage", 5.0)))
					_attack_cd = ATTACK_COOLDOWN
		elif temperament == "passive" and dist < float(species.get("flee_range", 10.0)):
			wish = global_position - ppos
			wish = wish - up * wish.dot(up)
			moving_speed = speed * 1.3
			handled = true

	if not handled:
		_wander_timer -= delta
		if _wander_timer <= 0.0 or _wander_dir == Vector3.ZERO:
			_wander_timer = randf_range(WANDER_MIN, WANDER_MAX)
			var ang := randf() * TAU
			var right := Vector3.RIGHT
			if absf(up.dot(right)) > 0.9:
				right = Vector3.FORWARD
			var fwd0 := up.cross(right).normalized()
			var right0 := fwd0.cross(up).normalized()
			_wander_dir = (fwd0 * cos(ang) + right0 * sin(ang))
			if randf() < 0.25:
				_wander_dir = Vector3.ZERO  # idle pause sometimes
		wish = _wander_dir

	# NPCs are leashed to their home settlement -- once outside it (however they
	# got there: wandering, fleeing, chasing, or even an idle pause), head
	# straight back before anything else, so a town's population doesn't slowly
	# drain away across the planet. Deliberately OUTSIDE the `wish.length()`
	# gate below: an idle pause sets wish to exactly zero, which must not be
	# able to suppress the leash while stranded outside the radius.
	if _home_radius > 0.0:
		var from_home := global_position - _home_center
		var flat_from_home := from_home - up * from_home.dot(up)
		if flat_from_home.length() > _home_radius:
			wish = -flat_from_home

	if wish.length() > 0.001:
		wish = (wish - up * wish.dot(up)).normalized()
		# land/cave creatures never enter water, even fleeing or chasing -- if the
		# path ahead is water, try turning along the shore instead of stopping dead
		if _blocked_by_water(wish):
			wish = _avoid_water_dir(wish, up)
		if wish.length() > 0.001 and not facing_owned:
			var fwd := -global_transform.basis.z
			# Turn toward the new heading at a fixed rate even when it's directly
			# behind: the old code SNAPPED instantly (`else wish`) once the two
			# were more than ~168 degrees apart, which is exactly the case a
			# direction reversal passes through, so every reversal popped.
			# slerp is undefined for perfectly opposed vectors, so nudge off the
			# degenerate axis instead of snapping.
			var target := wish
			if fwd.dot(target) < -0.999:
				target = (target + global_transform.basis.x * 0.01).normalized()
			var new_fwd := fwd.slerp(target, clampf(delta * 6.0, 0.0, 1.0))
			look_at(global_position + new_fwd, up)

	var v_up := velocity.dot(up)
	v_up += -GRAVITY_ACCEL * delta
	if is_on_floor():
		v_up = maxf(v_up, 0.0)
	if wish.length() > 0.001 and _step_up_needed(wish, up):
		v_up = STEP_UP_SPEED
	# Ease horizontal velocity toward its target instead of snapping straight
	# to it -- real weight/momentum, and the biggest single fix for movement
	# reading as "jerky": every state change (chase -> circle -> telegraph ->
	# attack -> recover) used to instantly SET velocity to a brand new value
	# every single frame with zero transition. Vertical (gravity/step-up)
	# stays instant on purpose -- falling and hopping a ledge shouldn't ease.
	var cur_h := velocity - up * velocity.dot(up)
	var target_h := wish * moving_speed
	var new_h := cur_h.lerp(target_h, clampf(delta * ACCEL_RATE, 0.0, 1.0))
	velocity = new_h + up * v_up
	up_direction = up
	move_and_slide()


const STEP_PROBE_DIST := 0.6
const STEP_UP_SPEED := 6.0

## Is there a low (1-voxel) ledge directly ahead that a hop would clear --
## solid at foot height, clear one voxel above that? Without this, land/cave
## creatures walked straight into every curb-height step in the terrain and
## just stood there pushing against it forever (everything except flyers,
## which never touch the ground, got stuck this way). Checked continuously
## (not one-shot) so a staircase-like slope gets climbed one hop at a time.
func _step_up_needed(dir: Vector3, up: Vector3) -> bool:
	if planet == null or dir.length() < 0.01 or not is_on_floor():
		return false
	var base := global_position + dir.normalized() * STEP_PROBE_DIST
	var low_blocked := planet.is_solid(planet.world_to_voxel(base + up * 0.2))
	var high_clear := not planet.is_solid(planet.world_to_voxel(base + up * 1.2))
	return low_blocked and high_clear


## chase -> circle (brief hesitation/strafe) -> telegraph-or-feint -> [feint:
## short reset back to chase] or [attack: closing step + hit] -> recover ->
## chase, for species.pattern == "lunger". Blocking can preempt an unengaged
## creature (chase/circle only -- never an already-committed telegraph/feint/
## attack) when the player visibly winds up a heavy swing. Returns
## {"wish": Vector3, "speed_mult": float} for the caller to apply -- kept as a
## plain return rather than mutating velocity directly so this stays a pure
## decision function, easy to extend with more patterns later.
##
## The telegraph is a real, beatable dodge window: the creature stands still
## and visibly winds up (see _animate's _state handling) for telegraph_time
## seconds. A feint plays the IDENTICAL wind-up -- no early tell, that's the
## point -- but aborts instead of committing, punishing a dodge thrown on the
## first visual cue instead of the actual commit. A real attack closes toward
## the player's CURRENT position every frame (not a single captured point)
## and resolves as soon as it's genuinely within range, so it can't blow
## straight through a player who ended up closer than expected.
func _lunger_ai(delta: float, up: Vector3, ppos: Vector3, dist: float, to_player: Vector3) -> Dictionary:
	var attack_range: float = float(species.get("attack_range", 2.4))
	var skill: float = float(species.get("skill", 0.5))
	_state_t -= delta

	# Always face the player while engaged, independent of movement -- a real
	# fighter keeps eye contact with their opponent through circling, winding
	# up, and swinging, not just while chasing. Without this, "circle" (which
	# strafes SIDEWAYS) left the body facing the strafe direction rather than
	# the player -- since _land_physics's shared look_at is gated on nonzero
	# wish, telegraph/attack (wish often zero) never got a chance to correct
	# it, so the whole windup+swing played out sideways-on and read as barely
	# anything happening at all.
	# During "attack" specifically, still track the player, but MUCH more
	# slowly than everywhere else. A hard freeze here (tried first) protects
	# the swing's own motion from being distorted frame-to-frame, but a real
	# player keeps moving/circling for the WHOLE ~1s+ the clip plays -- with a
	# full freeze, a fully-committed attack cycle measurably drifted from
	# hips_dot=0.99 (facing the player) at the start down to hips_dot=-0.85
	# (facing almost exactly AWAY) by the end, just from the player circling
	# at an ordinary strafe speed the entire time. That's the real source of
	# "the whole body faces backward when it attacks" -- not a mirrored rig,
	# not a wrong axis, just a frozen heading going stale against a target
	# that never stood still. A slow crawl (rate 8 elsewhere, ~1.5 here) keeps
	# the swing's own frame-to-frame motion essentially undistorted while
	# still closing most of the gap over the clip's real duration.
	var look_rate := 8.0 if _state != "attack" else 1.5
	var flat_to_player := to_player - up * to_player.dot(up)
	if flat_to_player.length() > 0.01:
		var fwd := -global_transform.basis.z
		var new_fwd := fwd.slerp(flat_to_player.normalized(), clampf(delta * look_rate, 0.0, 1.0))
		look_at(global_position + new_fwd, up)

	if _state == "chase" or _state == "circle":
		var blockable: bool = dist < attack_range * 2.0 and world.player.is_heavy_telegraphed()
		if blockable and not _was_blockable and randf() < lerpf(0.15, 0.7, skill):
			_state = "block"
			_state_t = BLOCK_MAX_TIME
		_was_blockable = blockable

	match _state:
		"block":
			if not world.player.is_heavy_telegraphed() or _state_t <= 0.0:
				_state = "chase"
			return {"wish": Vector3.ZERO, "speed_mult": 1.0}
		"recover":
			if _knockback_t > 0.0:
				_knockback_t -= delta
				return {"wish": _knockback_dir, "speed_mult": KNOCKBACK_MULT}
			if _state_t <= 0.0:
				_state = "chase"
			return {"wish": Vector3.ZERO, "speed_mult": 1.0}
		"circle":
			if _state_t <= 0.0:
				_state = "telegraph"
				# Feints disabled for now (see below, they need reworking to fit
				# the new scrub-the-real-clip windup instead of a hand-posed one).
				_is_feint = false
				var tt: float = maxf(float(species.get("telegraph_time", 0.45)), 0.05)
				_state_t = randf_range(tt * 0.7, tt * 1.3)  # per-attempt jitter, not a fixed metronome
				_telegraph_total = _state_t
				# Start the real clip NOW, frozen at frame 0 -- the windup is
				# the clip's own first WINDUP_END_FRACTION, scrubbed through by
				# hand in _animate() as the telegraph timer counts down, not a
				# separate hand-posed pose. speed_scale=0 hands full control to
				# that manual scrub; "attack" below just sets it back to 1 and
				# lets the SAME clip keep playing forward from wherever it is.
				_attack_clip_len = SWORD_SWING_DURATION
				# Pick a fresh attack at random each attempt, so a fight cycles
				# through the whole attack folder instead of one repeated swing.
				# The windup/hit/end fractions below are proportions of whatever
				# clip got picked, so they scale to each clip's own length --
				# though per-clip hit timing may still want tuning by eye, since
				# a kick and an overhead slash don't connect at the same moment.
				if _play_state("attack", true, 0.0):
					_attack_clip_len = maxf(_cur_clip_len(), 0.05)
					_anim_player.seek(0.0, true)
					_oneshot_state = ""  # the attack is driven by state, not the one-shot path
				return {"wish": Vector3.ZERO, "speed_mult": 1.0}
			var flat_to_p := to_player - up * to_player.dot(up)
			if flat_to_p.length() < 0.01:
				return {"wish": Vector3.ZERO, "speed_mult": 1.0}
			return {"wish": flat_to_p.cross(up).normalized() * _circle_dir, "speed_mult": 0.6}
		"telegraph":
			if _state_t <= 0.0:
				if _is_feint:
					_state = "recover"
					_state_t = FEINT_RESET_TIME
					if _anim_player != null:
						_anim_player.stop()
						_reset_skeleton_pose()
				else:
					_state = "attack"
					_swing_t = 0.0  # only the pivot-fallback body's own swing math reads this, but reset unconditionally
					_hit_applied = false
					_lunge_target = ppos  # captured NOW, not re-tracked -- see doc comment above
					if _anim_player != null:
						_anim_player.speed_scale = 1.0  # resume forward from wherever the windup scrub left off
						# Safety-cap timeout: the REMAINING portion of the clip
						# still to play, plus a small margin -- the real exit
						# condition below is the clip's own playback position,
						# this only guards against that somehow never being hit.
						_state_t = (ATTACK_END_FRACTION - WINDUP_END_FRACTION) * _attack_clip_len + 0.2
					else:
						_state_t = _attack_clip_len  # pivot-fallback body: matches its own exit condition below
			return {"wish": Vector3.ZERO, "speed_mult": 1.0}
		"attack":
			_swing_t += delta  # only the pivot-fallback body's own separate swing math uses this
			var clip_pos: float = _anim_player.current_animation_position if _anim_player != null else _swing_t
			var hit_point_reached: bool = clip_pos >= ATTACK_HIT_FRACTION * _attack_clip_len if _anim_player != null else _swing_t >= _attack_clip_len * ATTACK_HIT_FRACTION
			var clip_done: bool = clip_pos >= ATTACK_END_FRACTION * _attack_clip_len if _anim_player != null else _swing_t >= _attack_clip_len
			# Damage lands partway through the swing (measured against the real
			# clip's own playback position now, not a separately-tracked timer)
			# instead of only at the very end or the instant we're in range --
			# and only once per swing.
			if not _hit_applied and hit_point_reached:
				_hit_applied = true
				if dist < attack_range * 1.4 and world.player.has_method("take_damage"):
					world.player.take_damage(float(species.get("damage", 5.0)))
			var to_target := _lunge_target - global_position
			var flat_target := to_target - up * to_target.dot(up)
			if clip_done or _state_t <= 0.0:
				if _anim_player != null:
					_anim_player.stop()
					_anim_player.speed_scale = 1.0
					_reset_skeleton_pose()
				_state = "recover"
				_state_t = RECOVER_TIME
				return {"wish": Vector3.ZERO, "speed_mult": 1.0}
			# Keep closing only up to the hit (and only if not already in
			# range) -- this is what actually fixed the old "blows straight
			# through the player" bug; once the hit has landed or we're
			# already close, just hold in place through the rest of the swing.
			if not _hit_applied and dist > attack_range:
				return {"wish": flat_target, "speed_mult": LUNGE_SPEED_MULT}
			return {"wish": Vector3.ZERO, "speed_mult": 1.0}
		_:  # "chase"
			if dist < attack_range:
				_state = "circle"
				_state_t = randf_range(CIRCLE_MIN, CIRCLE_MAX)
				_circle_dir = 1.0 if randf() < 0.5 else -1.0
				return {"wish": Vector3.ZERO, "speed_mult": 1.0}
			return {"wish": to_player - up * to_player.dot(up), "speed_mult": 1.0}


# Is the cell a short step ahead in `dir` (from here) water? Land/cave creatures
# use this to refuse to walk into water under any circumstance.
func _blocked_by_water(dir: Vector3) -> bool:
	if planet == null or dir.length() < 0.01:
		return false
	var probe := global_position + dir.normalized() * 1.6
	return planet.get_id(planet.world_to_voxel(probe)) == Blocks.WATER


# Try turning along the shoreline instead of into the water: rotate the wished
# direction around `up` by increasing angles until one isn't blocked. Returns
# Vector3.ZERO (stay put) if fully hemmed in by water.
func _avoid_water_dir(dir: Vector3, up: Vector3) -> Vector3:
	if dir.length() < 0.001:
		return Vector3.ZERO
	var d := dir.normalized()
	for deg in [30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180]:
		var cand := d.rotated(up, deg_to_rad(deg))
		if not _blocked_by_water(cand):
			return cand
	return Vector3.ZERO


# Is the cell a short step ahead in `dir` actually water? Fish check this BEFORE
# committing to a direction, so they never even brush the shore, let alone leave.
# The probe reaches further at higher speed -- a fast-swimming fish needs more
# braking distance than a slow one to actually turn before reaching the shore.
func _ahead_is_water(dir: Vector3) -> bool:
	if planet == null or dir.length() < 0.01:
		return true
	var probe_dist := maxf(2.5, velocity.length() * 0.8)
	var probe := global_position + dir.normalized() * probe_dist
	return planet.get_id(planet.world_to_voxel(probe)) == Blocks.WATER


var _last_water_pos := Vector3.ZERO
var _has_water_pos := false

# "Deeper into the planet" for a CUBE-shaped planet is along the nearest face's
# axis, not a straight line to the geometric center -- water depth follows the
# same Chebyshev metric as terrain height (see Planet._norm), so a raw Euclidean
# direction toward planet.global_position can point the "wrong way" once you're
# off a face's center, exactly like Planet._surf/_axis_of everywhere else.
# (This IS the right notion of "inward" for radial motion, e.g. a bird's climb/
# descend -- but NOT for getting a fish back into water, see _find_water_dir.)
func _inward_dir(pos: Vector3) -> Vector3:
	if planet == null:
		return Vector3.ZERO
	var out_dir := (pos - planet.global_position).normalized()
	if out_dir.length() < 0.001:
		return Vector3.ZERO
	var axis: Vector3 = planet._axis_of(out_dir) if planet.shape_cube else out_dir
	return -axis


# The face-normal axis at a point, used only as a ROTATION axis below -- not
# as a direction to move along (that would be _inward_dir, which is wrong for
# water: a lake sits on top of the terrain, so a few units straight down from
# its shore is solid seafloor, not more water).
func _water_up_axis(pos: Vector3) -> Vector3:
	if planet == null:
		return Vector3.UP
	var out_dir := (pos - planet.global_position).normalized()
	if out_dir.length() < 0.001:
		return Vector3.UP
	return planet._axis_of(out_dir) if planet.shape_cube else out_dir


# Water bodies are a surface feature, not a depth gradient -- retreating from a
# shoreline back into deep water means moving HORIZONTALLY (along the shore or
# back the way we came), never radially toward the planet's center. Search by
# rotating a seed direction around the local up axis, mirroring the land
# creature's _avoid_water_dir but with the water/land test inverted.
func _find_water_dir(from: Vector3, seed_dir: Vector3) -> Vector3:
	var up := _water_up_axis(from)
	var base := seed_dir - up * seed_dir.dot(up)
	if base.length() < 0.01:
		base = Vector3.RIGHT - up * Vector3.RIGHT.dot(up)
	if base.length() < 0.01:
		base = Vector3.FORWARD - up * Vector3.FORWARD.dot(up)
	base = base.normalized()
	for deg in [0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180]:
		var cand := base.rotated(up, deg_to_rad(deg))
		if planet.get_id(planet.world_to_voxel(from + cand * 2.0)) == Blocks.WATER:
			return cand
	return -base


# Snap a stranded fish back to a confirmed water voxel near `from`, searching
# outward along `_find_water_dir` at increasing distances. Returns `from`
# unchanged if nothing within range tests as water (shouldn't happen since
# `from` is itself the last confirmed-water position).
func _retreat_into_water(from: Vector3, seed_dir: Vector3) -> Vector3:
	if planet == null:
		return from
	var dir := _find_water_dir(from, seed_dir)
	for margin in [1.0, 2.0, 4.0, 8.0, 16.0]:
		var cand: Vector3 = from + dir * float(margin)
		if planet.get_id(planet.world_to_voxel(cand)) == Blocks.WATER:
			return cand
	return from


func _swim_physics(delta: float) -> void:
	var speed: float = species.get("speed", 2.5)
	if planet != null:
		# Hard safety net: predictive steering (below) handles the normal case, but
		# voxel discretization + velocity smoothing can't guarantee zero overshoot
		# in every case -- so if a fish is ever confirmed outside water, snap it
		# straight back to its last known-good spot instead of merely re-steering.
		# This bounds any excursion to a single tick, which is invisible in play.
		if planet.get_id(planet.world_to_voxel(global_position)) == Blocks.WATER:
			_last_water_pos = global_position
			_has_water_pos = true
		elif _has_water_pos:
			# _last_water_pos is, by definition, the last position confirmed as
			# water -- i.e. right at the boundary. Resetting exactly there isn't
			# enough: the very next tick's velocity (freshly re-lerped from zero)
			# is a deterministic step that can be just large enough to re-cross the
			# same edge, forever, as a stable 1-tick oscillation. Retreat further
			# inward for real breathing room -- and since some shorelines are
			# irregular enough (thin peninsulas, complex terrain) that a single
			# fixed push can itself land on another dry spot, retry at increasing
			# distances until a confirmed water voxel is found.
			var seed_dir := global_position - _last_water_pos
			if seed_dir.length() < 0.01:
				seed_dir = -velocity
			var landed := _retreat_into_water(_last_water_pos, -seed_dir)
			global_position = landed
			velocity = Vector3.ZERO
			_wander_dir = _find_water_dir(_last_water_pos, -seed_dir)
	_wander_timer -= delta
	if _wander_timer <= 0.0 or _wander_dir == Vector3.ZERO:
		_wander_timer = randf_range(WANDER_MIN, WANDER_MAX)
		_wander_dir = Vector3(randf() * 2 - 1, randf() * 2 - 1, randf() * 2 - 1).normalized()
	if planet != null:
		# never let the chosen direction lead out of the water -- look ahead first;
		# if it would leave, head back toward the planet's center (deeper water)
		if not _ahead_is_water(_wander_dir):
			var back_dir := _find_water_dir(global_position, _wander_dir)
			_wander_dir = back_dir
			# a smoothed velocity lerp isn't enough to stop momentum before it
			# carries the fish across the boundary -- directly kill any velocity
			# component still pointing toward shore (away from the water)
			var away := -back_dir
			var d := velocity.dot(away)
			if d > 0.0:
				velocity -= away * d
	velocity = velocity.lerp(_wander_dir * speed, clampf(delta * 1.5, 0.0, 1.0))
	if velocity.length() > 0.05:
		look_at(global_position + velocity.normalized(), Vector3.UP)
	move_and_slide()


const FLY_MIN_ALT := 8.0
const FLY_MAX_ALT := 45.0

const PERCH_CHANCE := 0.3        # odds a wander cycle chooses to land instead of fly
const PERCH_MIN := 3.0
const PERCH_MAX := 7.0
const LAND_ALT := 1.5            # altitude at which a descending bird counts as landed

func _fly_physics(delta: float) -> void:
	var speed: float = species.get("speed", 4.0)
	var temperament: String = species.get("temperament", "neutral")
	var wish := Vector3.ZERO
	var moving_speed := speed
	var ppos = _player_pos()
	var handled := false

	if ppos != null:
		var to_player: Vector3 = ppos - global_position
		var dist := to_player.length()
		if temperament == "hostile" and dist < float(species.get("aggro_range", 12.0)):
			wish = to_player.normalized()
			handled = true
			_landing = false
			_perched = false
			if dist < ATTACK_RANGE and _attack_cd <= 0.0:
				if world != null and world.player != null and world.player.has_method("take_damage"):
					world.player.take_damage(float(species.get("damage", 5.0)))
				_attack_cd = ATTACK_COOLDOWN
		elif temperament == "passive" and dist < float(species.get("flee_range", 10.0)):
			wish = -to_player.normalized()
			moving_speed = speed * 1.3
			handled = true
			_landing = false
			_perched = false  # startled off the ground

	if not handled:
		if _perched:
			# sitting on the ground; wait out the perch, then take back off
			_wander_timer -= delta
			if _wander_timer <= 0.0:
				_perched = false
				_wander_dir = Vector3.ZERO  # force a fresh sky wander target
		elif _landing and planet != null:
			# descending toward a perch -- head straight down until grounded
			wish = _inward_dir(global_position)  # already points inward/down
			if planet.altitude(global_position) < LAND_ALT:
				_landing = false
				_perched = true
				_wander_timer = randf_range(PERCH_MIN, PERCH_MAX)
				velocity = Vector3.ZERO
				wish = Vector3.ZERO
		else:
			_wander_timer -= delta
			if _wander_timer <= 0.0 or _wander_dir == Vector3.ZERO:
				if planet != null and randf() < PERCH_CHANCE:
					_landing = true
				else:
					_wander_timer = randf_range(WANDER_MIN, WANDER_MAX)
					_wander_dir = Vector3(randf() * 2 - 1, randf() * 0.4 - 0.2, randf() * 2 - 1).normalized()
			wish = _wander_dir

	# stay within an altitude band above the terrain (skip while intentionally
	# landing or already perched)
	if planet != null and not _landing and not _perched:
		var alt := planet.altitude(global_position)
		var inward := _inward_dir(global_position)
		if alt < FLY_MIN_ALT:
			wish -= inward * 0.8  # climb (outward)
		elif alt > FLY_MAX_ALT:
			wish += inward * 0.8  # descend (inward)

	if wish.length() > 0.01:
		wish = wish.normalized()
	velocity = velocity.lerp(wish * moving_speed, clampf(delta * 2.0, 0.0, 1.0))
	if velocity.length() > 0.1:
		# World UP goes colinear with the flight direction whenever a creature
		# climbs/dives near a pole (this planet's local "up" isn't world Y) --
		# that spammed a "Target and up vectors are colinear" warning (with a
		# full backtrace) every physics tick for any such creature, which is
		# expensive enough on its own to noticeably slow the whole game down.
		# Use the planet-relative up instead, with a perpendicular fallback for
		# the rare case flight direction and even that are still colinear.
		var fwd := velocity.normalized()
		var up_dir := -_inward_dir(global_position)
		if up_dir == Vector3.ZERO:
			up_dir = Vector3.UP
		if absf(fwd.dot(up_dir)) > 0.999:
			up_dir = Vector3.RIGHT if absf(fwd.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
		look_at(global_position + fwd, up_dir)
	move_and_slide()


func _animate(delta: float) -> void:
	var top_speed: float = maxf(float(species.get("speed", 3.0)), 0.1)
	var moving: float = clampf(velocity.length() / top_speed, 0.0, 1.0)
	_phase += delta * (4.0 + moving * 6.0)
	for i in _legs.size():
		var sgn := 1.0 if i % 2 == 0 else -1.0
		_legs[i].rotation.x = sin(_phase * sgn + (PI if i >= 2 else 0.0)) * 0.5 * moving
	for i in _knees.size():
		var ksgn := 1.0 if i % 2 == 0 else -1.0
		# forward-only (a knee doesn't bend backward), phase-lagged behind the
		# hip so it reads as the shin catching up rather than moving in lockstep
		_knees[i].rotation.x = maxf(0.0, sin(_phase * ksgn - 0.6)) * 0.7 * moving
	for i in _arms.size():
		var asgn := -1.0 if i % 2 == 0 else 1.0  # opposite leg on the same side
		_arms[i].rotation.x = sin(_phase * asgn) * 0.35 * moving
	for i in _elbows.size():
		var esgn := -1.0 if i % 2 == 0 else 1.0
		# a slight permanent bend at rest (0.5 rad) -- a straight-hanging arm
		# reads as a stiff mannequin, and holds a sword/shield flat against
		# the leg where it's hard to make out
		_elbows[i].rotation.x = 0.5 + maxf(0.0, sin(_phase * esgn - 0.6)) * 0.4 * moving
	# "lunger" wind-up/dash visual: lean back during telegraph. Only for the
	# pivot-fallback body -- the real clip (see below) already has its own
	# authored lean/crouch baked in, and adding this on top doubled it up.
	if _model != null and _skeleton == null:
		var scale_f: float = species.get("scale", 1.0)
		if _state == "telegraph":
			var t := clampf(1.0 - _state_t / maxf(_telegraph_total, 0.05), 0.0, 1.0)
			_model.position.z = 0.3 * scale_f * t
		elif _state == "attack":
			_model.position.z = lerpf(_model.position.z, -0.15 * scale_f, clampf(delta * 14.0, 0.0, 1.0))
		else:
			_model.position.z = lerpf(_model.position.z, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# Sword-arm swing + shield-raise, for lungers only. Two paths:
	if _skeleton != null:
		# Real Skeleton3D rig (see _build_biped_skeleton). "telegraph" AND
		# "attack" both hand the WHOLE skeleton to the imported AnimationPlayer
		# clip now -- the windup is literally the clip's own first portion,
		# scrubbed through by hand as the telegraph timer counts down, and
		# "attack" is that same clip simply allowed to keep playing forward.
		# One continuous animation, not a hand-posed windup handed off to a
		# separately-started clip -- no more pop at the handoff, and the
		# "wind-up" visually IS the real swing's own backswing, not a fake.
		# Don't touch any bone pose by hand while either is playing, or we'd
		# fight the clip every frame. Every OTHER state still drives bone
		# poses by hand with the exact formulas the pivot-based body used.
		# A one-shot reaction (hit flinch, shield-block) owns the skeleton until
		# it finishes -- checked FIRST so nothing below restarts a locomotion
		# clip over the top of a flinch that is still playing.
		if _oneshot_state != "":
			if _anim_player != null and _anim_player.is_playing():
				pass
			else:
				_oneshot_state = ""
				_cur_clip = ""
		elif _state == "telegraph" and _anim_player != null:
			# Scrub through the clip's own first WINDUP_END_FRACTION by hand,
			# proportional to how far through the (jittered-length) telegraph
			# window we are -- this IS the windup, not a separate pose.
			var wt := clampf(1.0 - _state_t / maxf(_telegraph_total, 0.05), 0.0, 1.0)
			_anim_player.seek(wt * WINDUP_END_FRACTION * _attack_clip_len, true)
		elif _state == "attack":
			pass  # the attack clip started in _lunger_ai just keeps playing
		elif _state == "block":
			_play_state("block")
		elif _state == "chase" or _state == "circle":
			# Scale the run cycle to how fast the creature is actually moving so
			# the feet don't skate: at the species' own top speed this is 1.0.
			var ref_speed: float = maxf(float(species.get("speed", 4.0)), 0.1)
			var flat_v := velocity - global_transform.basis.y * velocity.dot(global_transform.basis.y)
			_play_state("run", false, clampf(flat_v.length() / ref_speed, 0.4, 1.6))
		else:
			# recover / anything else: stand in the authored idle.
			_play_state("idle")
	elif species.get("pattern", "") == "lunger" and _arms.size() >= 2 and _elbows.size() >= 2:
		# Fallback: the original hand-built pivot body/animation, only reached
		# if the skeleton rig failed to load for some reason. Same smooth
		# sin(t*PI) technique as the fish tail / player's own swing
		# (_update_swing in player.gd) -- eases in and back out rather than
		# snapping between poses.
		match _state:
			"telegraph":
				var wt := clampf(1.0 - _state_t / maxf(_telegraph_total, 0.05), 0.0, 1.0)
				_arms[1].rotation.x = lerpf(_arms[1].rotation.x, -2.1 * wt, clampf(delta * 9.0, 0.0, 1.0))
				_elbows[1].rotation.x = lerpf(_elbows[1].rotation.x, 1.4 * wt, clampf(delta * 9.0, 0.0, 1.0))
			"attack":
				var st := clampf(_swing_t / SWORD_SWING_DURATION, 0.0, 1.0)
				var swing := sin(st * PI)  # smooth 0->1->0, same as the fish tail
				_arms[1].rotation.x = -2.1 + swing * 3.2
				_elbows[1].rotation.x = 1.4 - swing * 1.2
			_:
				pass
		if _state == "block":
			_arms[0].rotation.x = lerpf(_arms[0].rotation.x, -1.4, clampf(delta * 10.0, 0.0, 1.0))
			_elbows[0].rotation.x = lerpf(_elbows[0].rotation.x, 0.8, clampf(delta * 10.0, 0.0, 1.0))
	# Shield raises while actively blocking -- the visual payoff for the
	# player's heavy-swing tell actually meaning something to the enemy. The
	# lift itself comes from the arm-raise pose above (_set_arm_pose on the
	# skeleton path, the old pivot lerp on the fallback path); the shield's
	# OWN rotation always targets _shield_rest_x (not a separate "block"
	# value) since that's the one roll angle, measured directly off the rig's
	# actual bone basis, that keeps the board reading as a flat upright
	# shield rather than a tilted diamond -- any other value (including the
	# old pivot system's -1.1, tuned for a completely different parent frame)
	# just rolls it back toward diamond territory. This lerp target must stay
	# _shield_rest_x either way, or it'll fight/erase the build-time
	# correction every frame.
	# EXCEPT while the real skeleton is mid-attack: the imported clip is
	# driving the whole left arm through a completely different range of
	# motion then, and this lerp fighting it every frame is exactly what made
	# the shield look broken/detached during the swing.
	if _shield != null and not (_skeleton != null and _state == "attack"):
		_shield.rotation.x = lerpf(_shield.rotation.x, _shield_rest_x, clampf(delta * 10.0, 0.0, 1.0))
	if _tail_pivot != null:
		var amp := 0.5 if species.get("kind") == "fish" else 0.25
		_tail_pivot.rotation.y = sin(_phase * 0.6) * amp * maxf(moving, 0.3)
	for i in _segments.size():
		var seg: MeshInstance3D = _segments[i]
		seg.position.x = sin(_phase - float(i) * 0.9) * 0.15 * float(species.get("scale", 1.0)) * maxf(moving, 0.2)
	for i in _wings.size():
		var sgn := 1.0 if i == 0 else -1.0
		var wing_amp := 0.0 if _perched else maxf(moving, 0.4)  # wings fold while perched
		_wings[i].rotation.z = sin(_phase * 1.6) * 0.6 * sgn * wing_amp + 0.15 * sgn


## Damage from the player's weapon (melee or a projectile hit). A raised
## shield (species.pattern == "lunger", currently _state == "block") cuts the
## damage way down and resists the stagger entirely -- a physical shield
## blocks whatever hits it, light or heavy; the enemy just won't choose to
## raise it in reaction to a light swing since there's no time to react to
## one. Otherwise `stagger` depletes the creature's stagger meter; hitting 0
## force-interrupts whatever it was doing (mid-telegraph or mid-dash) into a
## brief knockback + recovery, refilling the meter. Returns true if the
## creature died from this hit.
func take_hit(dmg: float, stagger: float = 0.0) -> bool:
	if _state == "dying":
		return true  # already going down; ignore further hits
	var is_lunger: bool = species.get("pattern", "") == "lunger"
	var guarded: bool = is_lunger and _state == "block"
	if guarded:
		_health -= dmg * BLOCK_DAMAGE_MULT
	else:
		_health -= dmg
		if stagger > 0.0 and is_lunger:
			_stagger -= stagger
			if _stagger <= 0.0:
				_apply_stagger_interrupt()
	if _health <= 0.0:
		# Play the death clip through before disappearing, instead of the old
		# instant queue_free(). Collision and AI are switched off immediately so
		# a corpse can't keep fighting or block the player mid-animation.
		var die_len := _play_oneshot("die")
		if die_len <= 0.0:
			queue_free()
			return true
		_state = "dying"
		_state_t = die_len
		velocity = Vector3.ZERO
		if _hitbox != null:
			_hitbox.set_deferred("disabled", true)
		return true
	# A flinch reads very differently depending on whether it was absorbed on a
	# shield or landed clean, so pick the matching reaction. Dual-wielders have
	# no shield, so they always take the clean-hit flinch even while "blocking".
	if guarded and _shield != null:
		_play_oneshot("hit_block")
	elif not guarded:
		_play_oneshot("hit")
	return false


func _apply_stagger_interrupt() -> void:
	_stagger = float(species.get("stagger_max", 3.0))
	if _anim_player != null and _anim_player.is_playing():
		_anim_player.stop()  # a stagger mid-swing shouldn't leave the attack clip playing over a flinch
		_anim_player.speed_scale = 1.0
		_reset_skeleton_pose()
	_state = "recover"
	_state_t = RECOVER_TIME
	_knockback_t = KNOCKBACK_TIME
	var ppos = _player_pos()
	if ppos == null:
		_knockback_dir = Vector3.ZERO
		return
	var up := Vector3.UP
	if world != null:
		var g := world.gravity_at(global_position)
		if g.length() > 0.01:
			up = -g.normalized()
	var away: Vector3 = global_position - ppos
	away = away - up * away.dot(up)
	_knockback_dir = away.normalized() if away.length() > 0.01 else Vector3.ZERO
