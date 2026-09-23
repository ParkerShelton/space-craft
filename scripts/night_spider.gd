class_name NightSpider
extends Creature
## Something that comes out after dark -- and never quite the same thing twice.
## What one looks like is a property of the WORLD, not of this file: every planet
## rolls its own kind from its seed (see make_species), so the stalkers of one
## world all share a build -- so many legs, that long, that colour, spitting that
## -- and the next world's are their own. What is fixed is the skeleton of the
## idea: a body slung low between legs that arch high at the knee, something
## with a face on the front of it, and a will to come at you after dark.
##
## Nothing about how it moves is animated by hand. Each leg has a spot on the
## ground it would like its foot to be -- found by casting a ray down from where
## the leg rests, relative to the body -- and the foot stays planted where it
## last landed until the body has carried that spot too far away. Then it steps:
## lifted in a short arc to the new spot, while its neighbours hold still. Legs
## go in two alternating sets of four, as a spider's do, so it always has four
## feet down. Each leg is two segments bent by two-bone inverse kinematics from the
## hip to wherever the foot is, with the knee pushed up and out.
##
## The body rides at a fixed height over its feet and tilts to the plane they
## make, so it climbs a step by reaching a foot up onto it first, and sits level
## on a slope. It is a Creature, so swords, bullets and loot treat it like any
## other animal; everything it does in the world is its own.

# What stays the same whatever kind it is.
const STEP_TIME := 0.17
const LEAD := 0.22           # feet land ahead of a moving body by this many seconds
const RUSH := 1.45           # how much faster it comes once it is close
const AGGRO := 32.0
const POUNCE_MIN := 3.5
const BITE_TIME := 0.8       # a slash: wind-up, strike, follow-through
const SPIT_TIME := 1.0       # rear back, spit, recover
const SPIT_MIN := 6.0
const SPIT_CD := 4.5
const SPIT_SPEED := 17.0
const GRAV := 22.0

# What this kind of stalker is: filled in by setup_spider from the planet's own
# species (see make_species). The defaults are only there so a bare one built by
# hand still stands up.
var sp: Dictionary = {}
var sp_scale := 1.45         # everything about its size in one number
var sp_legs := 8
var sp_per_side := 4
var sp_upper := 2.75         # hip to knee: long, so the knee stands high
var sp_lower := 3.3          # knee to foot
var sp_ride := 1.2           # body height over the ground
var sp_step_dist := 1.4      # how far the ground spot drifts before a foot moves
var sp_step_lift := 0.7
var sp_ray_up := 2.9
var sp_ray_down := 4.0
var sp_climb := 3.4          # a ledge higher than this turns it back
var sp_speed := 4.6
var sp_pounce_range := 10.0
var sp_bite_range := 3.0     # the claws reach
var sp_hit_reach := 2.8      # how close a pounce has to bring it to land
var sp_bite_dmg := 8.0
var sp_pounce_dmg := 12.0
var sp_spit_max := 20.0
var sp_health := 60.0
var sp_spit := "web"         # what it spits: web / fire / stone / none
var sp_c_body := Color(0.035, 0.03, 0.035)
var sp_c_leg := Color(0.05, 0.045, 0.05)
var sp_c_skin := Color(0.16, 0.14, 0.15)
var sp_c_bone := Color(0.72, 0.68, 0.62)
var sp_c_eye := Color(1.0, 0.06, 0.04)
var sp_c_vein := Color(0.75, 0.04, 0.06)


## Roll one world's kind of stalker. Everything a body is made of is decided
## here and nowhere else, so a planet only has to keep the dictionary.
static func make_species(rng: RandomNumberGenerator) -> Dictionary:
	var legs: int = [4, 6, 6, 8, 8][rng.randi() % 5]
	var scale := rng.randf_range(0.95, 1.9)
	# Long legs on a small body, or a heavy body close to the ground.
	var lanky := rng.randf_range(0.0, 1.0)
	var spit: String = ["web", "web", "fire", "stone", "none"][rng.randi() % 5]
	# Colour: a dark body in some hue, pale plates, and eyes that go with what
	# it spits -- so what is coming at you can be read from a distance.
	var hue := rng.randf()
	var body_c := Color.from_hsv(hue, rng.randf_range(0.15, 0.6), rng.randf_range(0.03, 0.14))
	var bone_hue := fposmod(hue + rng.randf_range(-0.12, 0.12), 1.0)
	var bone_c := Color.from_hsv(bone_hue, rng.randf_range(0.05, 0.35), rng.randf_range(0.45, 0.85))
	var eye_c: Color
	match spit:
		"fire": eye_c = Color(1.0, rng.randf_range(0.3, 0.55), 0.05)
		"stone": eye_c = Color(0.95, 0.85, rng.randf_range(0.3, 0.6))
		"web": eye_c = Color.from_hsv(rng.randf(), rng.randf_range(0.7, 1.0), 1.0)
		_: eye_c = Color.from_hsv(rng.randf(), rng.randf_range(0.6, 1.0), 1.0)
	return {
		"name": _roll_name(rng),
		"legs": legs,
		"scale": scale,
		# How the body itself is put together.
		"segments": rng.randi_range(2, 5),
		"body_w": rng.randf_range(0.7, 1.25),
		"body_h": rng.randf_range(0.55, 1.0),     # how tall a segment is for its width
		"belly": rng.randf_range(0.0, 1.0),       # how much the back end swells
		# Which of the three builds it has above the shoulders.
		"upper": ["tall", "tall", "hunched", "none"][rng.randi() % 4],
		"arms": rng.randi_range(1, 2),            # pairs, when it has an upper body
		"eyes": rng.randi_range(2, 10),
		"crown": [0, 0, 5, 7, 9, 11][rng.randi() % 6],
		"veins": rng.randf() < 0.6,
		"plates": rng.randf() < 0.7,
		# Legs.
		"upper_len": lerpf(1.3, 2.3, lanky),
		"lower_len": lerpf(1.6, 2.8, lanky),
		"leg_thick": rng.randf_range(0.07, 0.17),
		"ride": lerpf(0.55, 1.0, lanky) * rng.randf_range(0.85, 1.15),
		# How far out the feet plant, as a fraction of how long the leg is -- so a
		# short-legged kind never ends up splayed flat with nothing left to bend.
		"spread_frac": rng.randf_range(0.38, 0.6),
		"knee_knob": rng.randf() < 0.75,
		# What it does.
		"spit": spit,
		"health": rng.randf_range(38.0, 95.0),
		"bite": rng.randf_range(6.0, 12.0),
		"pounce": rng.randf_range(8.0, 16.0),
		"speed": rng.randf_range(3.6, 5.6),
		"c_body": body_c,
		"c_bone": bone_c,
		"c_eye": eye_c,
	}


const _NAME_A := ["vor", "grim", "cath", "morr", "skel", "ithe", "ur", "zan", "hal", "drev", "nyx", "oss"]
const _NAME_B := ["ak", "eth", "ul", "ira", "oth", "ess", "ang", "ix", "orn", "ael"]
const _NAME_C := ["Stalker", "Crawler", "Weaver", "Lurker", "Skitter", "Widow", "Reaper", "Creeper"]


static func _roll_name(rng: RandomNumberGenerator) -> String:
	return "%s%s %s" % [(_NAME_A[rng.randi() % _NAME_A.size()] as String).capitalize(),
		_NAME_B[rng.randi() % _NAME_B.size()], _NAME_C[rng.randi() % _NAME_C.size()]]


var _hips: Array = []        # body-local
var _rest: Array = []        # body-local resting foot spot
var _foot: Array = []        # world: where each foot is now
var _from: Array = []
var _to: Array = []
var _step: Array = []        # -1 planted, else 0..1 through a step
var _femur: Array = []
var _tibia: Array = []
var _look: Node3D            # the visible body, which lunges and crouches
var _up := Vector3.UP
var _heading := Vector3.FORWARD
var _hvel := Vector3.ZERO
var _air := false
var _vy := 0.0
var _ai := "wander"
var _ai_t := 0.0
var _cd := 0.0
var _hit_done := false
var _crouch := 0.0
var _lunge := 0.0
var _flash := 0.0
var _day_t := 0.0
var _die_t := 0.0
var _blocked_t := 0.0
var _mats: Array = []
var _planted := false
var _jaw: Node3D             # the skull's lower jaw
var _torso: Node3D           # the upper body, which leans and rears
var _head: Node3D
var _arms_p: Array = []      # [shoulder, elbow] per arm, left then right
var _spikes: Array = []      # a pale knob at each knee
var _eye_mat: StandardMaterial3D
var _twitch := 0.0
var _twitch_t := 0.0
var _clock := 0.0
var _spit_cd := 2.0
var _spits := 0
var _spr := {}               # spring states: key -> [value, velocity]
var _air_t := 0.0
## Set on one summoned by hand, so it can be watched in daylight.
var daylight_ok := false


func setup_spider(p: Planet, w: WorldManager, kind: Dictionary = {}) -> void:
	planet = p
	world = w
	sp = kind if not kind.is_empty() else make_species(RandomNumberGenerator.new())
	_apply_species()
	species = {"name": str(sp.get("name", "Night Stalker")), "kind": "land",
		"temperament": "hostile", "health": sp_health,
		"drops": [{"id": Blocks.FIBRE, "min": 3, "max": 6}, {"id": Blocks.BONE, "min": 1, "max": 3}]}
	_health = sp_health
	_build_spider()
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.6 * sp_scale
	col.shape = sh
	add_child(col)
	_hitbox = col
	# The body behind and whatever stands up in front are things to hit as well.
	for spot in [[Vector3(0, 0.2, 0.95) * sp_scale, 0.6 * sp_scale],
			[Vector3(0, 1.4, -0.8) * sp_scale, 0.45 * sp_scale]]:
		var c2 := CollisionShape3D.new()
		var s2 := SphereShape3D.new()
		s2.radius = spot[1]
		c2.shape = s2
		c2.position = spot[0]
		add_child(c2)
	_heading = Vector3(randf() - 0.5, 0, randf() - 0.5).normalized()


## Take the numbers out of the species and into the ones the body and the AI
## actually read, sized up by how big this kind is.
func _apply_species() -> void:
	sp_scale = float(sp.get("scale", 1.45))
	sp_legs = int(sp.get("legs", 8))
	sp_per_side = sp_legs / 2
	sp_upper = float(sp.get("upper_len", 1.9)) * sp_scale
	sp_lower = float(sp.get("lower_len", 2.3)) * sp_scale
	sp_ride = float(sp.get("ride", 0.85)) * sp_scale
	sp_step_dist = 0.95 * sp_scale
	sp_step_lift = 0.5 * sp_scale
	sp_ray_up = 2.0 * sp_scale
	sp_ray_down = 2.8 * sp_scale
	sp_climb = 2.4 * sp_scale
	sp_speed = float(sp.get("speed", 4.6))
	sp_health = float(sp.get("health", 60.0))
	sp_bite_dmg = float(sp.get("bite", 8.0))
	sp_pounce_dmg = float(sp.get("pounce", 12.0))
	sp_bite_range = 2.0 * sp_scale
	sp_hit_reach = 1.9 * sp_scale
	sp_pounce_range = 7.0 * sp_scale
	sp_spit = str(sp.get("spit", "web"))
	sp_c_body = sp.get("c_body", sp_c_body)
	sp_c_bone = sp.get("c_bone", sp_c_bone)
	sp_c_eye = sp.get("c_eye", sp_c_eye)
	sp_c_leg = (sp_c_body as Color).lightened(0.06)
	sp_c_skin = (sp_c_body as Color).lightened(0.22)
	sp_c_vein = (sp_c_eye as Color).darkened(0.25)


# --- the body -------------------------------------------------------------------

func _mat(c: Color, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	else:
		# Emission is kept on so a hit can flash it red.
		m.emission_enabled = true
		m.emission = Color(0, 0, 0)
		_mats.append(m)
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_spider() -> void:
	_look = Node3D.new()
	add_child(_look)
	var S := sp_scale
	var body := _mat(sp_c_body)
	var skin := _mat(sp_c_skin)
	var bone := _mat(sp_c_bone)
	_eye_mat = _mat(sp_c_eye, 5.0)
	var vein := _mat(sp_c_vein, 1.6)
	var plated: bool = bool(sp.get("plates", true))
	var veined: bool = bool(sp.get("veins", true))

	# The body: a run of segments back from the shoulders, swelling toward the
	# rear by however much of a belly this kind has.
	var n: int = maxi(int(sp.get("segments", 4)), 2)
	var bw := float(sp.get("body_w", 1.1))
	var bh := float(sp.get("body_h", 0.75))
	var belly := float(sp.get("belly", 0.7))
	var z := -0.55 * bw
	var body_back := z
	for i in n:
		var t := float(i) / float(maxi(n - 1, 1))
		var bulge := sin(clampf(t * 0.8 + 0.2, 0.0, 1.0) * PI) * belly
		var w := bw * (0.7 + 0.7 * bulge)
		var ln := bw * (0.75 + 0.6 * bulge)
		var hgt := w * bh
		var at := Vector3(0, 0.1 * bulge, z + ln * 0.5) * S
		_box(_look, Vector3(w, hgt, ln) * S, at, body)
		if plated:
			_box(_look, Vector3(w * 0.8, 0.06, ln * 0.8) * S,
				at + Vector3(0, hgt * 0.5 * S, 0), bone)
		if veined and i > 0:
			_box(_look, Vector3(0.05, hgt * 0.8, ln * 0.8) * S,
				at + Vector3(0, hgt * 0.25 * S, 0), vein)
		z += ln * 0.9
		body_back = z
	var front := -0.55 * bw * S

	# What it has above the shoulders. Some kinds rear up on a thin torso; some
	# carry the head low on the body like an animal.
	var style := str(sp.get("upper", "tall"))
	_torso = Node3D.new()
	_look.add_child(_torso)
	var head_up := 1.2
	if style == "none":
		_torso.position = Vector3(0, 0.05, front * 0.6)
		head_up = 0.1
	else:
		_torso.position = Vector3(0, 0.2 * S, front * 0.7)
		_torso.scale = Vector3.ONE * (1.4 if style == "tall" else 0.95)
		var t_h := 1.0 if style == "tall" else 0.7
		_box(_torso, Vector3(0.36, 0.5 * t_h, 0.26) * S, Vector3(0, 0.25 * t_h, 0) * S, skin)
		_box(_torso, Vector3(0.5, 0.55 * t_h, 0.3) * S, Vector3(0, 0.72 * t_h, 0) * S, skin)
		if plated:
			for r in 4:
				_box(_torso, Vector3(0.52, 0.035, 0.32) * S,
					Vector3(0, (0.55 + r * 0.1) * t_h, 0) * S, bone)
		if veined:
			_box(_torso, Vector3(0.04, 0.8 * t_h, 0.04) * S, Vector3(0, 0.5 * t_h, -0.16) * S, vein)
		_box(_torso, Vector3(0.12, 0.2 * t_h, 0.12) * S, Vector3(0, 1.08 * t_h, 0) * S, skin)
		head_up = 1.2 * t_h

	# The head: a skull, a crooked cluster of eyes, a jaw, and on some kinds a
	# crown of spines behind it.
	_head = Node3D.new()
	_head.position = Vector3(0, head_up, 0) * S
	_torso.add_child(_head)
	_box(_head, Vector3(0.36, 0.34, 0.36) * S, Vector3(0, 0.12, 0) * S, bone)
	_box(_head, Vector3(0.3, 0.12, 0.05) * S, Vector3(0, 0.02, -0.19) * S, body)
	var eyes: int = maxi(int(sp.get("eyes", 8)), 1)
	var erng := RandomNumberGenerator.new()
	erng.seed = hash(str(sp.get("name", "")))
	for e in eyes:
		var ex := erng.randf_range(-0.14, 0.14)
		var ey := erng.randf_range(0.0, 0.26)
		var es := erng.randf_range(0.03, 0.09)
		_box(_head, Vector3(es, es, 0.03) * S, Vector3(ex, ey, -0.19) * S, _eye_mat)
	_jaw = Node3D.new()
	_jaw.position = Vector3(0, -0.04, 0.02) * S
	_head.add_child(_jaw)
	_box(_jaw, Vector3(0.3, 0.07, 0.3) * S, Vector3(0, -0.03, -0.05) * S, bone)
	for sx in [-1.0, 1.0]:
		_box(_jaw, Vector3(0.03, 0.12, 0.03) * S, Vector3(sx * 0.1, 0.03, -0.19) * S, bone)
	var crown: int = int(sp.get("crown", 9))
	for c in crown:
		var ang := lerpf(-1.25, 1.25, float(c) / float(maxi(crown - 1, 1)))
		var spn := Node3D.new()
		spn.position = Vector3(0, 0.14, 0.12) * S
		spn.rotation = Vector3(0.35, 0, ang)
		_head.add_child(spn)
		var ln2 := (0.55 if c % 2 == 0 else 0.38) * S
		_box(spn, Vector3(0.035 * S, ln2, 0.035 * S), Vector3(0, ln2 * 0.5 + 0.12 * S, 0),
			bone if c % 2 == 0 else body)

	# Arms, on the kinds that have something to hang them from.
	if style != "none":
		var pairs: int = maxi(int(sp.get("arms", 1)), 1)
		for pair in pairs:
			for sx in [-1.0, 1.0]:
				var sh := Node3D.new()
				sh.position = Vector3(sx * (0.3 + pair * 0.06), 0.92 - pair * 0.3, 0) * S
				_torso.add_child(sh)
				_box(sh, Vector3(0.08, 0.62, 0.08) * S, Vector3(0, -0.31, 0) * S, skin)
				var el := Node3D.new()
				el.position = Vector3(0, -0.62, 0) * S
				sh.add_child(el)
				_box(el, Vector3(0.065, 0.58, 0.065) * S, Vector3(0, -0.29, 0) * S, skin)
				for f in 3:
					var cl := Node3D.new()
					cl.position = Vector3((f - 1) * 0.035, -0.58, 0) * S
					cl.rotation = Vector3(0.25, 0, (f - 1) * 0.22)
					el.add_child(cl)
					_box(cl, Vector3(0.025, 0.42, 0.025) * S, Vector3(0, -0.21, 0) * S, bone)
				_arms_p.append([sh, el])

	# The glow of its eyes on the ground in front of it.
	var glow := OmniLight3D.new()
	glow.light_color = sp_c_eye
	glow.light_energy = 1.3
	glow.omni_range = 4.5 * S
	glow.shadow_enabled = false
	glow.position = Vector3(0, head_up * 0.8, front * 1.4) * S
	_look.add_child(glow)

	# Legs: hips down the length of the body, feet spread wide, front ones
	# reaching ahead and back ones behind.
	var leg := _mat(sp_c_leg)
	var thick := float(sp.get("leg_thick", 0.11))
	var leg_len := (sp_upper + sp_lower) / S
	var spread := leg_len * float(sp.get("spread_frac", 0.5))
	var reach := leg_len * 0.45
	for i in sp_legs:
		var side := -1.0 if i < sp_per_side else 1.0
		var k := i % sp_per_side
		var t := float(k) / float(maxi(sp_per_side - 1, 1))
		var hz := lerpf(front * 0.9, body_back * 0.45 * S, t)
		_hips.append(Vector3(side * 0.4 * S, 0.1 * S, hz))
		var rz := lerpf(-reach, reach * 0.9, t) * S
		var rx := side * spread * (0.85 + 0.25 * sin(t * PI)) * S
		_rest.append(Vector3(rx, -sp_ride, rz))
		_foot.append(Vector3.ZERO)
		_from.append(Vector3.ZERO)
		_to.append(Vector3.ZERO)
		_step.append(-1.0)
		for arr in [_femur, _tibia, _spikes]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			if arr == _femur:
				bm.size = Vector3(thick * S, thick * S, 1.0)
			elif arr == _tibia:
				bm.size = Vector3(thick * 0.6 * S, thick * 0.6 * S, 1.0)
			else:
				bm.size = Vector3(thick * 1.3 * S, thick * 1.3 * S, 1.0)
			mi.mesh = bm
			mi.material_override = bone if arr == _spikes else leg
			# Placed in world space every frame by the IK, not carried by the body.
			mi.top_level = true
			mi.visible = arr != _spikes or bool(sp.get("knee_knob", true))
			add_child(mi)
			arr.append(mi)


# --- where things are -------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return get_world_3d().direct_space_state


## The ground under a point, along the local down. null if there is none in reach.
func _ground(p: Vector3, up_len := sp_ray_up, down_len := sp_ray_down):
	var q := PhysicsRayQueryParameters3D.create(p + _up * up_len, p - _up * down_len, 1)
	var ex: Array[RID] = [get_rid()]
	if world != null and world.player != null and is_instance_valid(world.player):
		ex.append((world.player as CollisionObject3D).get_rid())
	q.exclude = ex
	var hit := _space().intersect_ray(q)
	if hit.is_empty():
		return null
	return hit["position"]


func _foot_target(i: int) -> Vector3:
	var lead := _hvel * LEAD
	var want: Vector3 = global_transform * (_rest[i] as Vector3) + lead
	# Threat pose: the front pair lifted and reaching while it squares up or bites.
	if i % sp_per_side == 0 and (_ai == "crouch" or _ai == "bite" or _ai == "spit"):
		return global_transform * ((_rest[i] as Vector3) * Vector3(0.7, 0, 0.8) + Vector3(0, 0.55, -0.1))
	var g = _ground(want)
	return g if g != null else want


# --- the frame ----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if world == null or planet == null:
		return
	var gv := world.gravity_at(global_position)
	_up = -_snap_up(gv) if gv.length() > 0.01 else Vector3.UP
	if not _planted:
		_planted = true
		for i in sp_legs:
			_foot[i] = _foot_target(i)
	if _ai == "dead":
		_die(delta)
		return
	_think(delta)
	_move(delta)
	_orient(delta)
	_step_legs(delta)
	_pose(delta)


func _player():
	if world != null and world.player != null and is_instance_valid(world.player):
		return world.player
	return null


func _flat(v: Vector3) -> Vector3:
	return v - _up * v.dot(_up)


## What it wants to do, and which way.
func _think(delta: float) -> void:
	_cd = maxf(_cd - delta, 0.0)
	_spit_cd = maxf(_spit_cd - delta, 0.0)
	_ai_t -= delta
	var pl = _player()
	var to_p := Vector3.ZERO
	var dist := INF
	if pl != null:
		to_p = _flat((pl as Node3D).global_position - global_position)
		dist = ((pl as Node3D).global_position - global_position).length()
	# Daylight drives it off: it backs away from you and is gone within seconds.
	if planet.night_factor() < 0.25 and _ai != "pounce" and not daylight_ok:
		_ai = "leave"
	match _ai:
		"wander":
			if _ai_t <= 0.0:
				_ai_t = randf_range(2.5, 5.0)
				var ang := randf_range(-1.6, 1.6)
				_heading = _heading.rotated(_up, ang).normalized()
			_wish(_heading, sp_speed * 0.35, delta)
			if dist < AGGRO:
				_ai = "stalk"
		"stalk":
			if dist > AGGRO * 1.5:
				_ai = "wander"
			elif dist < sp_bite_range and _cd <= 0.0:
				_ai = "bite"
				_ai_t = BITE_TIME
				_hit_done = false
			elif sp_spit != "none" and dist > SPIT_MIN and dist < sp_spit_max and _spit_cd <= 0.0 and randf() < delta * 0.9 \
					and _can_see(pl):
				_ai = "spit"
				_ai_t = SPIT_TIME
				_spits = 0
			# Stuck in its webbing, you are what it has been waiting for.
			elif dist < sp_pounce_range and dist > POUNCE_MIN and _cd <= 0.0 					and (randf() < delta * 1.5 or _player_stuck(pl)):
				_ai = "crouch"
				_ai_t = 0.5
			# Closing in, with a little weave so it does not come in a straight line.
			var weave := sin(Time.get_ticks_msec() * 0.0021 + get_instance_id()) * 0.45
			var d := to_p.normalized().rotated(_up, weave) if to_p.length() > 0.01 else _heading
			# Slow and watchful at a distance, then a sudden rush once close.
			_wish(d, sp_speed * (RUSH if dist < 14.0 else 0.8), delta)
		"crouch":
			_face(to_p, delta * 10.0)
			_wish(Vector3.ZERO, 0.0, delta)
			if _ai_t <= 0.0:
				_pounce(pl)
		"pounce":
			if not _hit_done and pl != null and dist < sp_hit_reach:
				_hit_done = true
				_hurt_player(pl, sp_pounce_dmg)
				_hvel *= 0.2
			if not _air:
				_ai = "retreat"
				_ai_t = 0.9
				_cd = 1.8
		"bite":
			_face(to_p, delta * 12.0)
			_wish(Vector3.ZERO, 0.0, delta)
			# Lands as the first claw comes down through you.
			if not _hit_done and _ai_t < BITE_TIME * 0.5:
				_hit_done = true
				if pl != null and dist < sp_bite_range + 0.5:
					_hurt_player(pl, sp_bite_dmg)
			if _ai_t <= 0.0:
				_ai = "retreat"
				_ai_t = 0.6
				_cd = 1.3
		"spit":
			_face(to_p, delta * 8.0)
			_wish(Vector3.ZERO, 0.0, delta)
			# A volley of three, close together, so a volley that lands leaves
			# you badly slowed and two leave you stuck.
			var due: Array = [0.42] if sp_spit == "stone" else [0.42, 0.3, 0.18]
			if _spits < due.size() and _ai_t < SPIT_TIME * float(due[_spits]):
				_spits += 1
				_spit_cd = SPIT_CD * randf_range(0.8, 1.4)
				_spit(pl)
				_kick("head_x", 9.0)
				_kick("jaw", 12.0)
			if _ai_t <= 0.0:
				_ai = "stalk"
		"retreat":
			_wish(-to_p.normalized() if to_p.length() > 0.01 else -_heading, sp_speed * 0.7, delta)
			if to_p.length() > 0.01:
				_face(to_p, delta * 4.0)
			if _ai_t <= 0.0:
				_ai = "stalk"
		"leave":
			_day_t += delta
			_wish(-to_p.normalized() if to_p.length() > 0.01 else _heading, sp_speed * 0.8, delta)
			if _day_t > 6.0 or dist > 60.0:
				_ai = "dead"
				_die_t = 0.0
				_dropped = true   # left, not killed: nothing to take


func _wish(dir: Vector3, speed: float, delta: float) -> void:
	var d := _flat(dir)
	var want := d.normalized() * speed if d.length() > 0.001 else Vector3.ZERO
	_hvel = _hvel.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	if want.length() > 0.1 and _ai != "retreat":
		_face(want, delta * 5.0)


func _face(dir: Vector3, t: float) -> void:
	var d := _flat(dir)
	if d.length() < 0.001:
		return
	_heading = _flat(_heading).normalized().slerp(d.normalized(), clampf(t, 0.0, 1.0)).normalized()


func _pounce(pl) -> void:
	_ai = "pounce"
	_hit_done = false
	_air = true
	var to_p := Vector3.ZERO
	var rise := 0.0
	if pl != null:
		var rel: Vector3 = (pl as Node3D).global_position - global_position
		to_p = _flat(rel)
		rise = rel.dot(_up)
	var flat_d := to_p.length()
	# Timed so it arrives: a flight a little under a second, faster over more ground.
	var t := clampf(flat_d / 9.0, 0.35, 0.8)
	_hvel = to_p / t if flat_d > 0.01 else _heading * 6.0
	_vy = (rise + 0.5 * GRAV * t * t) / t
	_vy = clampf(_vy, 4.0, 11.0)


func _player_stuck(pl) -> bool:
	return pl != null and "_stuck_t" in pl and float(pl._stuck_t) > 0.0


## Whether it has a clear line from its head to you.
func _can_see(pl) -> bool:
	if pl == null or _head == null:
		return false
	var q := PhysicsRayQueryParameters3D.create(_head.global_position, (pl as Node3D).global_position, 1)
	q.exclude = [get_rid()]
	var hit := _space().intersect_ray(q)
	return hit.is_empty() or hit["collider"] == pl


## A glob of webbing from the mouth, led to where you are going.
func _spit(pl) -> void:
	if pl == null or _head == null:
		return
	var from: Vector3 = _head.global_transform * (Vector3(0, 0.05, -0.3) * sp_scale)
	var target: Vector3 = (pl as Node3D).global_position
	var tv: Vector3 = pl.velocity if "velocity" in pl else Vector3.ZERO
	var g := world.gravity_at(from)
	var glob := SpitGlob.new()
	glob.kind = sp_spit
	get_parent().add_child(glob)
	# Each of a volley a little off the last, so it cannot all be dodged the same way.
	var v := SpitGlob.aim(from, target, tv, SPIT_SPEED, g)
	var side := v.cross(_up).normalized()
	v += side * randf_range(-1.2, 1.2) * float(_spits - 1)
	glob.launch(from, v, world, self)


## A damped spring: every joint of the upper body is one, chasing its target
## pose rather than being set to it. A soft one eases; a stiff, lightly damped
## one overshoots and settles, which is what makes a strike whip rather than
## tick into place.
func _spring(key: String, target: float, k: float, zeta: float, delta: float) -> float:
	var st: Array = _spr.get(key, [target, 0.0])
	var c := 2.0 * zeta * sqrt(k)
	var h := delta * 0.5
	for i in 2:
		st[1] = float(st[1]) + (k * (target - float(st[0])) - c * float(st[1])) * h
		st[0] = float(st[0]) + float(st[1]) * h
	_spr[key] = st
	return float(st[0])


## A shove to one spring, for flinches and twitches.
func _kick(key: String, impulse: float) -> void:
	if _spr.has(key):
		_spr[key][1] = float(_spr[key][1]) + impulse


## One arm's slash, `t` 0..1 through it: [shoulder x, shoulder spread, elbow,
## stiffness, damping]. Raised overhead and cocked back, then brought down and
## across hard enough to overshoot, then let swing back up into the reach.
func _slash_pose(t: float) -> Array:
	if t < 0.0:
		return [1.0, 0.3, 0.8, 90.0, 0.7]
	if t < 0.36:
		return [2.9, 0.6, 1.55, 150.0, 0.75]
	if t < 0.62:
		return [-0.4, -0.2, 0.05, 750.0, 0.3]
	return [0.9, 0.3, 0.7, 110.0, 0.55]


func _hurt_player(pl, dmg: float) -> void:
	if pl.has_method("take_damage"):
		pl.take_damage(dmg)
	# A shove away, so a hit is felt rather than just read off the health bar.
	var away := _flat((pl as Node3D).global_position - global_position)
	if away.length() > 0.01 and "velocity" in pl:
		pl.velocity += away.normalized() * 6.0 + _up * 3.0


## Across the ground, and up and down over it.
func _move(delta: float) -> void:
	var v := _hvel
	if _air:
		_vy -= GRAV * delta
		v += _up * _vy
	velocity = v
	up_direction = _up
	move_and_slide()
	if _air:
		_air_t += delta
		var g = _ground(global_position, 0.2, sp_ride + 0.05)
		# Down on the ground -- or on anything else, you included: landing on top
		# of you used to leave it "in the air" for good, since its ground ray
		# looks straight through you.
		var landed := _vy < 0.0 and (g != null or is_on_floor())
		if landed or _air_t > 3.0:
			_air = false
			_air_t = 0.0
			_vy = 0.0
			if g != null:
				global_position = (g as Vector3) + _up * sp_ride
			for i in sp_legs:
				_step[i] = -1.0
				_foot[i] = _foot_target(i)
		return
	# The height to ride at: over the ground beneath it, over the feet, and over
	# whatever is just ahead -- the last is what lifts it up a step before it
	# walks into the face of it.
	var h := global_position.dot(_up)
	var target := -INF
	var under = _ground(global_position)
	if under != null:
		target = (under as Vector3).dot(_up)
	var ahead_dir := _flat(_hvel).normalized() if _hvel.length() > 0.2 else Vector3.ZERO
	if ahead_dir != Vector3.ZERO:
		var ahead = _ground(global_position + ahead_dir * 0.95 * sp_scale, sp_climb, sp_ray_down)
		if ahead != null:
			var ah := (ahead as Vector3).dot(_up)
			if ah - h < sp_climb - sp_ride:
				target = maxf(target, ah)
	var fsum := 0.0
	for i in sp_legs:
		fsum += (_foot[i] as Vector3).dot(_up)
	target = maxf(target, fsum / sp_legs) if target > -INF else fsum / sp_legs
	if under == null and h - target > 1.2:
		_air = true    # walked off an edge
		_vy = 0.0
		return
	var goal := target + sp_ride
	global_position += _up * (lerpf(h, goal, clampf(delta * 9.0, 0.0, 1.0)) - h)
	# Pushing into a wall it cannot climb: turn and go round.
	if is_on_wall() and _hvel.length() > 0.5:
		_blocked_t += delta
		if _blocked_t > 0.6:
			_blocked_t = 0.0
			_heading = _heading.rotated(_up, (1.0 if randf() < 0.5 else -1.0) * randf_range(1.2, 2.2))
			if _ai == "wander":
				_ai_t = 2.0
	else:
		_blocked_t = 0.0


## Face the heading, tilted to the plane its feet make.
func _orient(delta: float) -> void:
	var n := _up
	if not _air:
		var front := Vector3.ZERO
		var back := Vector3.ZERO
		var left := Vector3.ZERO
		var right := Vector3.ZERO
		for i in sp_legs:
			var f: Vector3 = _foot[i]
			if i % sp_per_side < sp_per_side / 2: front += f
			else: back += f
			if i < sp_per_side: left += f
			else: right += f
		var fwd := front - back
		var side := right - left
		var fit := side.cross(fwd)
		if fit.length() > 0.01:
			fit = fit.normalized()
			if fit.dot(_up) < 0.0:
				fit = -fit
			# Leaning INTO the slope, but never far: a leg that cannot reach its
			# spot leaves a foot hanging, and a body that trusted that tipped
			# right over.
			n = _up.lerp(fit, 0.5).normalized()
			var tilt := acos(clampf(n.dot(_up), -1.0, 1.0))
			if tilt > 0.33:
				n = _up.slerp(n, 0.33 / tilt).normalized()
	var cur_up := global_transform.basis.y
	var y := cur_up.slerp(n, clampf(delta * 8.0, 0.0, 1.0)).normalized()
	var z := -(_heading - y * _heading.dot(y))
	if z.length() < 0.01:
		z = global_transform.basis.z
	z = z.normalized()
	var x := y.cross(z).normalized()
	global_transform.basis = Basis(x, y, x.cross(y).normalized())


## Plant, step, and bend every leg.
func _step_legs(delta: float) -> void:
	var stepping := [false, false]
	for i in sp_legs:
		if float(_step[i]) >= 0.0:
			stepping[_group(i)] = true
	var still := _hvel.length() < 0.3
	for i in sp_legs:
		if _air:
			# Legs drawn in and reaching forward while it flies.
			var r: Vector3 = _rest[i]
			_foot[i] = global_transform * (r * Vector3(0.75, 0.35, 0.8) + Vector3(0, 0.1, -0.35))
			continue
		var tgt := _foot_target(i)
		var s := float(_step[i])
		if s >= 0.0:
			s += delta / STEP_TIME
			_to[i] = tgt      # keep aiming at the spot as the body moves on
			if s >= 1.0:
				_step[i] = -1.0
				_foot[i] = _to[i]
			else:
				_step[i] = s
				var a: Vector3 = _from[i]
				var b: Vector3 = _to[i]
				_foot[i] = a.lerp(b, s) + _up * sin(s * PI) * sp_step_lift
			continue
		var drift := (_foot[i] as Vector3).distance_to(tgt)
		var need := drift > sp_step_dist or (still and drift > 0.3 * sp_scale) or drift > sp_step_dist * 2.2
		# A leg lifts only while the other set is all down, so four feet always are.
		if need and not stepping[1 - _group(i)]:
			_step[i] = 0.0
			_from[i] = _foot[i]
			_to[i] = tgt
			stepping[_group(i)] = true


## The two alternating sets: front-left, second-right, third-left, back-right --
## and the other four.
func _group(i: int) -> int:
	return ((i % sp_per_side) + (1 if i >= sp_per_side else 0)) % 2


## Two-bone IK: hip to foot, knee up and out.
func _pose(delta: float) -> void:
	_crouch = move_toward(_crouch, 1.0 if _ai == "crouch" else 0.0, delta * 4.0)
	var lunge_want := 0.0
	if _ai == "bite":
		var bt := clampf(1.0 - _ai_t / BITE_TIME, 0.0, 1.0)
		lunge_want = -0.3 if bt < 0.36 else (1.0 if bt < 0.66 else 0.2)
	_lunge = _spring("lunge", lunge_want, 260.0, 0.45, delta)
	_look.position = Vector3(0, -0.28 * sp_scale * _crouch, -0.4 * sp_scale * _lunge)
	_clock += delta
	# Twitches: now and then the whole body jerks a little, more often when it
	# is hunting -- stillness broken by a flinch is what reads as wrong.
	_twitch_t -= delta
	if _twitch_t <= 0.0:
		var hunting := _ai == "stalk" or _ai == "crouch"
		_twitch_t = randf_range(0.25, 0.8) if hunting else randf_range(0.8, 2.5)
		_twitch = randf_range(-1.0, 1.0) * (0.16 if hunting else 0.07)
		# ...and the head and shoulders jerk with it, and ring out.
		_kick("head_z", randf_range(-1.0, 1.0) * (6.0 if hunting else 2.5))
		_kick("head_y", randf_range(-1.0, 1.0) * (4.0 if hunting else 1.5))
		_kick("twist", randf_range(-1.0, 1.0) * 1.5)
	_twitch = move_toward(_twitch, 0.0, delta * 0.9)
	_look.rotation = Vector3(0.18 * _crouch - 0.15 * _lunge, _twitch * 0.6, _twitch)
	# The upper body, every joint a spring. Hunched over at rest; reaching as it
	# hunts; rearing and spreading before a pounce; and a slash that winds up,
	# twists into the blow and follows through.
	var lean := 0.45 - 0.55 * _crouch
	var twist := 0.0
	var head_x := 0.08 * sin(_clock * 1.3)
	var jaw := 0.1
	var lk := 120.0
	var lz := 0.6
	var bt := clampf(1.0 - _ai_t / BITE_TIME, 0.0, 1.0)
	var st := clampf(1.0 - _ai_t / SPIT_TIME, 0.0, 1.0)
	match _ai:
		"stalk", "retreat":
			jaw = 0.35 + 0.15 * sin(_clock * 11.0)
		"crouch", "pounce":
			jaw = 0.75
		"bite":
			jaw = 0.8
			if bt < 0.36:
				lean = -0.3
				twist = 0.45
			elif bt < 0.66:
				lean = 0.8
				twist = -0.5
				lk = 420.0
				lz = 0.45
			else:
				lean = 0.55
				twist = -0.1
		"spit":
			# Rears back with its head up and its mouth shut, swelling -- then the
			# head snaps forward, jaw wide.
			if st < 0.6:
				lean = -0.4
				head_x = -0.55
				jaw = 0.0
			else:
				lean = 0.75
				head_x = 0.5
				jaw = 1.1
				lk = 600.0
				lz = 0.35
	_torso.rotation.x = -_spring("lean", lean, lk, lz, delta)
	_torso.rotation.y = _spring("twist", twist, lk, lz, delta)
	var hx := _spring("head_x", lean * 0.8 + head_x, 380.0 if _ai == "spit" else 160.0, 0.4, delta)
	var hy := _spring("head_y", _twitch * 2.0, 140.0, 0.3, delta)
	var hz := _spring("head_z", _twitch * 3.0, 140.0, 0.3, delta)
	_head.rotation = Vector3(hx, hy, hz)
	if _ai == "spit" and st < 0.6:
		# The throat swelling as it draws the glob up.
		_head.scale = Vector3.ONE * (1.0 + 0.08 * sin(st * 40.0) * st)
	else:
		_head.scale = Vector3.ONE
	_jaw.rotation.x = _spring("jaw", jaw, 300.0 if jaw > 0.9 else 150.0, 0.45, delta)
	# Arms, on the kinds that have them. In a slash the second comes down a beat
	# after the first.
	for a in _arms_p.size():
		var sh: Node3D = _arms_p[a][0]
		var el: Node3D = _arms_p[a][1]
		var sgn := -1.0 if a == 0 else 1.0
		var pose: Array
		match _ai:
			"bite":
				pose = _slash_pose(bt - (0.0 if a == 0 else 0.13))
			"stalk", "retreat":
				pose = [1.0 + 0.15 * sin(_clock * 4.0 + a), 0.3, 0.8, 90.0, 0.55]
			"crouch", "pounce":
				pose = [1.6, 0.85, 0.35, 140.0, 0.5]
			"spit":
				pose = [0.6, 0.7, 1.0, 120.0, 0.55]
			_:
				pose = [0.35 + 0.08 * sin(_clock * 1.1 + a), 0.12, 0.45, 60.0, 0.6]
		var key := "arm%d" % a
		sh.rotation.x = _spring(key + "x", pose[0], pose[3], pose[4], delta)
		sh.rotation.z = sgn * _spring(key + "z", pose[1], pose[3], pose[4], delta)
		# The elbow lags the shoulder a little, so the forearm whips.
		el.rotation.x = _spring(key + "e", pose[2], float(pose[3]) * 0.7, float(pose[4]) * 0.85, delta)
	# Eyes throb, faster when it has seen you.
	if _eye_mat != null:
		var rate := 9.0 if _ai in ["stalk", "crouch", "pounce", "bite", "spit"] else 2.0
		_eye_mat.emission_energy_multiplier = 4.0 + 1.5 * sin(_clock * rate)
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 4.0, 0.0)
		for m in _mats:
			(m as StandardMaterial3D).emission = Color(0.9, 0.1, 0.05) * _flash
	var body_up := global_transform.basis.y
	for i in sp_legs:
		var hip: Vector3 = _look.global_transform * (_hips[i] as Vector3)
		var f: Vector3 = _foot[i]
		var to_f := f - hip
		var d := to_f.length()
		var dir := to_f / maxf(d, 0.0001)
		d = clampf(d, 0.15, sp_upper + sp_lower - 0.02)
		var ca := clampf((sp_upper * sp_upper + d * d - sp_lower * sp_lower) / (2.0 * sp_upper * d), -1.0, 1.0)
		var sa := sqrt(1.0 - ca * ca)
		var outward := hip - global_position
		outward = (outward - body_up * outward.dot(body_up)).normalized()
		var pole := body_up + outward * 0.1
		var bend := pole - dir * pole.dot(dir)
		if bend.length() < 0.001:
			bend = body_up
		bend = bend.normalized()
		var knee := hip + dir * sp_upper * ca + bend * sp_upper * sa
		_segment(_femur[i], hip, knee, body_up)
		_segment(_tibia[i], knee, hip + dir * d, body_up)
		# A pale knob at the knee, the highest point of the leg.
		_segment(_spikes[i], knee - bend * 0.07 * sp_scale, knee + bend * 0.1 * sp_scale, body_up)


func _segment(mi: MeshInstance3D, a: Vector3, b: Vector3, up_hint: Vector3) -> void:
	var z := b - a
	var l := z.length()
	if l < 0.001:
		return
	z /= l
	var x := up_hint.cross(z)
	if x.length() < 0.01:
		x = z.cross(Vector3.RIGHT if absf(z.x) < 0.9 else Vector3.FORWARD)
	x = x.normalized()
	var y := z.cross(x).normalized()
	mi.global_transform = Transform3D(Basis(x, y, z * l), (a + b) * 0.5)


# --- being hit -----------------------------------------------------------------------

func take_hit(dmg: float, _stagger: float = 0.0) -> bool:
	if _ai == "dead":
		return true
	_health -= dmg
	_flash = 1.0
	if _health <= 0.0:
		_grant_drops()
		_ai = "dead"
		_die_t = 0.0
		set_collision_layer_value(1, false)
		set_collision_layer_value(CORPSE_LAYER, true)
		return true
	# A hit knocks it off whatever it was doing and back a step.
	if _ai != "pounce":
		_ai = "retreat"
		_ai_t = 0.45
		_cd = maxf(_cd, 0.6)
	return false


## Legs curl in under it, it drops, and it is gone.
func _die(delta: float) -> void:
	_die_t += delta
	var k := clampf(_die_t / 0.7, 0.0, 1.0)
	for i in sp_legs:
		var r: Vector3 = _rest[i]
		_foot[i] = global_transform * r.lerp(Vector3(r.x * 0.2, -sp_ride * 0.4, r.z * 0.2), k)
	_pose(delta)
	_look.position = Vector3(0, -0.45 * sp_scale * k, 0)
	if _die_t > 1.6:
		var s := clampf(1.0 - (_die_t - 1.6) / 0.6, 0.0, 1.0)
		scale = Vector3.ONE * maxf(s, 0.01)
		if s <= 0.0:
			queue_free()
