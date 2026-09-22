class_name NightSpider
extends Creature
## Something that comes out after dark: six long legs, a crooked cluster of
## burning eyes, a stinging tail curled over its back, and a jump.
##
## Nothing about how it moves is animated by hand. Each leg has a spot on the
## ground it would like its foot to be -- found by casting a ray down from where
## the leg rests, relative to the body -- and the foot stays planted where it
## last landed until the body has carried that spot too far away. Then it steps:
## lifted in a short arc to the new spot, while its neighbours hold still. Legs
## go in two alternating sets of three (a tripod gait, as insects walk), so it
## always has three feet down. Each leg is two segments bent by two-bone inverse kinematics from the
## hip to wherever the foot is, with the knee pushed up and out.
##
## The body rides at a fixed height over its feet and tilts to the plane they
## make, so it climbs a step by reaching a foot up onto it first, and sits level
## on a slope. It is a Creature, so swords, bullets and loot treat it like any
## other animal; everything it does in the world is its own.

## Everything about its size in one number, so it can be grown or shrunk
## without its gait coming apart.
const S := 1.7
const LEGS := 6
const UPPER := 1.15 * S      # hip to knee
const LOWER := 1.35 * S      # knee to foot
const RIDE := 0.7 * S        # body height over the ground
const STEP_DIST := 0.75 * S  # how far the ground spot drifts before a foot moves
const STEP_TIME := 0.15
const STEP_LIFT := 0.38 * S
const LEAD := 0.22           # feet land ahead of a moving body by this many seconds
const RAY_UP := 1.8 * S
const RAY_DOWN := 2.6 * S
const MAX_CLIMB := 3.4       # a ledge higher than this turns it back

const SPEED := 4.6
const RUSH := 1.4            # how much faster it skitters once it is close
const AGGRO := 32.0
const POUNCE_RANGE := 10.0
const POUNCE_MIN := 3.5
const BITE_RANGE := 2.7
const HIT_REACH := 2.6       # how close a pounce has to bring it to land
const BITE_DAMAGE := 8.0
const POUNCE_DAMAGE := 12.0
const GRAV := 22.0
const HEALTH := 60.0

const C_BODY := Color(0.07, 0.04, 0.05)
const C_LEG := Color(0.10, 0.06, 0.07)
const C_BONE := Color(0.50, 0.45, 0.37)
const C_EYE := Color(1.0, 0.32, 0.04)

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
var _jaws: Array = []        # mandible pivots, left then right
var _tail: Array = []        # tail segment pivots, base first
var _spikes: Array = []      # a bone spike off each knee
var _eye_mat: StandardMaterial3D
var _twitch := 0.0
var _twitch_t := 0.0
var _clock := 0.0
var _air_t := 0.0
## Set on one summoned by hand, so it can be watched in daylight.
var daylight_ok := false


func setup_spider(p: Planet, w: WorldManager) -> void:
	planet = p
	world = w
	species = {"name": "Night Stalker", "kind": "land", "temperament": "hostile",
		"health": HEALTH,
		"drops": [{"id": Blocks.FIBRE, "min": 3, "max": 6}, {"id": Blocks.BONE, "min": 1, "max": 3}]}
	_health = HEALTH
	_build_spider()
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.5 * S
	col.shape = sh
	add_child(col)
	_hitbox = col
	_heading = Vector3(randf() - 0.5, 0, randf() - 0.5).normalized()


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
	var body := _mat(C_BODY)
	var bone := _mat(C_BONE)
	_eye_mat = _mat(C_EYE, 4.0)
	# A long body in segments, front (-Z) to back, each capped with a bone plate
	# and a pair of spines -- more like something's ribcage than a spider.
	var segs := [
		[Vector3(0.62, 0.40, 0.58), Vector3(0, 0.02, -0.42)],   # head
		[Vector3(0.82, 0.50, 0.62), Vector3(0, 0.10, 0.14)],    # thorax
		[Vector3(0.70, 0.44, 0.52), Vector3(0, 0.14, 0.66)],
		[Vector3(0.54, 0.36, 0.42), Vector3(0, 0.18, 1.08)],
	]
	for i in segs.size():
		var sz: Vector3 = segs[i][0] * S
		var at: Vector3 = segs[i][1] * S
		_box(_look, sz, at, body)
		_box(_look, Vector3(sz.x * 0.86, 0.07 * S, sz.z * 0.78), at + Vector3(0, sz.y * 0.5 + 0.02 * S, 0), bone)
		if i > 0:
			for sx in [-1.0, 1.0]:
				_box(_look, Vector3(0.06, 0.26 + 0.05 * i, 0.06) * S,
					at + Vector3(sx * sz.x * 0.28, sz.y * 0.5 + 0.15 * S, 0), bone)
	# Eyes: a crooked cluster, no two alike, which is most of what makes a face
	# stop reading as a face.
	var head_front := -0.71 * S
	for e in [[-0.17, 0.06, 0.11], [0.15, 0.08, 0.13], [-0.05, 0.13, 0.07], [0.04, 0.02, 0.06],
			[-0.24, -0.02, 0.05], [0.25, 0.12, 0.05], [0.09, 0.16, 0.04], [-0.12, -0.07, 0.04]]:
		var sz: float = e[2] * S
		_box(_look, Vector3(sz, sz, 0.03 * S), Vector3(e[0] * S, e[1] * S, head_front), _eye_mat)
	# The eyes light the ground in front of it -- at night the first thing you
	# see is a red glow moving where nothing should be.
	var glow := OmniLight3D.new()
	glow.light_color = C_EYE
	glow.light_energy = 1.2
	glow.omni_range = 5.0 * S * 0.6
	glow.shadow_enabled = false
	glow.position = Vector3(0, 0.05, -0.95) * S
	_look.add_child(glow)
	# Mandibles, which open as it gets close and snap shut on a bite.
	for sx in [-1.0, 1.0]:
		var jp := Node3D.new()
		jp.position = Vector3(sx * 0.16, -0.1, -0.66) * S
		_look.add_child(jp)
		_box(jp, Vector3(0.07, 0.09, 0.34) * S, Vector3(0, 0, -0.15) * S, bone)
		_box(jp, Vector3(0.12, 0.06, 0.06) * S, Vector3(-sx * 0.05, -0.02, -0.31) * S, bone)
		_jaws.append(jp)
	# A tail curled up over the back, ending in a sting that glows.
	var parent: Node3D = _look
	var base := Vector3(0, 0.22, 1.3) * S
	for i in 6:
		var tp := Node3D.new()
		tp.position = base if i == 0 else Vector3(0, 0, 0.3 * S * (1.0 - i * 0.08))
		parent.add_child(tp)
		var w := (0.3 - i * 0.035) * S
		_box(tp, Vector3(w, w * 0.85, 0.32 * S), Vector3(0, 0, 0.14 * S), body)
		_box(tp, Vector3(w * 0.7, 0.05 * S, 0.2 * S), Vector3(0, w * 0.45, 0.14 * S), bone)
		_tail.append(tp)
		parent = tp
	_box(parent, Vector3(0.1, 0.1, 0.28) * S, Vector3(0, -0.04, 0.38) * S, _eye_mat)
	var leg := _mat(C_LEG)
	for i in LEGS:
		var side := -1.0 if i < 3 else 1.0
		var k := i % 3
		var z: float = [-0.3, 0.1, 0.45][k] * S
		_hips.append(Vector3(side * 0.36 * S, 0.0, z))
		# Front pair reaches far forward, the back pair far back.
		var rz: float = [-1.55, 0.15, 1.55][k] * S
		var rx: float = [1.35, 1.8, 1.45][k] * S
		_rest.append(Vector3(side * rx, -RIDE, rz))
		_foot.append(Vector3.ZERO)
		_from.append(Vector3.ZERO)
		_to.append(Vector3.ZERO)
		_step.append(-1.0)
		for arr in [_femur, _tibia, _spikes]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			if arr == _femur:
				bm.size = Vector3(0.12 * S, 0.12 * S, 1.0)
			elif arr == _tibia:
				bm.size = Vector3(0.08 * S, 0.08 * S, 1.0)
			else:
				bm.size = Vector3(0.05 * S, 0.05 * S, 1.0)
			mi.mesh = bm
			mi.material_override = bone if arr == _spikes else leg
			# Placed in world space every frame by the IK, not carried by the body.
			mi.top_level = true
			add_child(mi)
			arr.append(mi)


# --- where things are -------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return get_world_3d().direct_space_state


## The ground under a point, along the local down. null if there is none in reach.
func _ground(p: Vector3, up_len := RAY_UP, down_len := RAY_DOWN):
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
	if i % 3 == 0 and (_ai == "crouch" or _ai == "bite"):
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
		for i in LEGS:
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
			_wish(_heading, SPEED * 0.35, delta)
			if dist < AGGRO:
				_ai = "stalk"
		"stalk":
			if dist > AGGRO * 1.5:
				_ai = "wander"
			elif dist < BITE_RANGE and _cd <= 0.0:
				_ai = "bite"
				_ai_t = 0.4
				_hit_done = false
			elif dist < POUNCE_RANGE and dist > POUNCE_MIN and _cd <= 0.0 and randf() < delta * 1.5:
				_ai = "crouch"
				_ai_t = 0.5
			# Closing in, with a little weave so it does not come in a straight line.
			var weave := sin(Time.get_ticks_msec() * 0.0021 + get_instance_id()) * 0.45
			var d := to_p.normalized().rotated(_up, weave) if to_p.length() > 0.01 else _heading
			# Slow and watchful at a distance, then a sudden rush once close.
			_wish(d, SPEED * (RUSH if dist < 14.0 else 0.8), delta)
		"crouch":
			_face(to_p, delta * 10.0)
			_wish(Vector3.ZERO, 0.0, delta)
			if _ai_t <= 0.0:
				_pounce(pl)
		"pounce":
			if not _hit_done and pl != null and dist < HIT_REACH:
				_hit_done = true
				_hurt_player(pl, POUNCE_DAMAGE)
				_hvel *= 0.2
			if not _air:
				_ai = "retreat"
				_ai_t = 0.9
				_cd = 1.8
		"bite":
			_face(to_p, delta * 12.0)
			_wish(Vector3.ZERO, 0.0, delta)
			if not _hit_done and _ai_t < 0.2:
				_hit_done = true
				if pl != null and dist < BITE_RANGE + 0.4:
					_hurt_player(pl, BITE_DAMAGE)
			if _ai_t <= 0.0:
				_ai = "retreat"
				_ai_t = 0.6
				_cd = 1.3
		"retreat":
			_wish(-to_p.normalized() if to_p.length() > 0.01 else -_heading, SPEED * 0.7, delta)
			if to_p.length() > 0.01:
				_face(to_p, delta * 4.0)
			if _ai_t <= 0.0:
				_ai = "stalk"
		"leave":
			_day_t += delta
			_wish(-to_p.normalized() if to_p.length() > 0.01 else _heading, SPEED * 0.8, delta)
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
		var g = _ground(global_position, 0.2, RIDE + 0.05)
		# Down on the ground -- or on anything else, you included: landing on top
		# of you used to leave it "in the air" for good, since its ground ray
		# looks straight through you.
		var landed := _vy < 0.0 and (g != null or is_on_floor())
		if landed or _air_t > 3.0:
			_air = false
			_air_t = 0.0
			_vy = 0.0
			if g != null:
				global_position = (g as Vector3) + _up * RIDE
			for i in LEGS:
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
		var ahead = _ground(global_position + ahead_dir * 0.95 * S, MAX_CLIMB, RAY_DOWN)
		if ahead != null:
			var ah := (ahead as Vector3).dot(_up)
			if ah - h < MAX_CLIMB - RIDE:
				target = maxf(target, ah)
	var fsum := 0.0
	for i in LEGS:
		fsum += (_foot[i] as Vector3).dot(_up)
	target = maxf(target, fsum / LEGS) if target > -INF else fsum / LEGS
	if under == null and h - target > 1.2:
		_air = true    # walked off an edge
		_vy = 0.0
		return
	var goal := target + RIDE
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
		for i in LEGS:
			var f: Vector3 = _foot[i]
			if i % 3 == 0: front += f
			elif i % 3 == 2: back += f
			if i < 3: left += f
			else: right += f
		var fwd := front - back
		var side := right - left
		var fit := side.cross(fwd)
		if fit.length() > 0.01:
			fit = fit.normalized()
			if fit.dot(_up) < 0.0:
				fit = -fit
			n = _up.lerp(fit, 0.6).normalized()
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
	for i in LEGS:
		if float(_step[i]) >= 0.0:
			stepping[_group(i)] = true
	var still := _hvel.length() < 0.3
	for i in LEGS:
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
				_foot[i] = a.lerp(b, s) + _up * sin(s * PI) * STEP_LIFT
			continue
		var drift := (_foot[i] as Vector3).distance_to(tgt)
		var need := drift > STEP_DIST or (still and drift > 0.3 * S) or drift > STEP_DIST * 2.2
		# A leg lifts only while the other set is all down, so four feet always are.
		if need and not stepping[1 - _group(i)]:
			_step[i] = 0.0
			_from[i] = _foot[i]
			_to[i] = tgt
			stepping[_group(i)] = true


## The two tripods: front-left, middle-right, back-left -- and the other three.
func _group(i: int) -> int:
	return ((i % 3) + (1 if i >= 3 else 0)) % 2


## Two-bone IK: hip to foot, knee up and out.
func _pose(delta: float) -> void:
	_crouch = move_toward(_crouch, 1.0 if _ai == "crouch" else 0.0, delta * 4.0)
	var lunge_want := 0.0
	if _ai == "bite":
		lunge_want = sin(clampf(1.0 - _ai_t / 0.4, 0.0, 1.0) * PI)
	_lunge = move_toward(_lunge, lunge_want, delta * 8.0)
	_look.position = Vector3(0, -0.28 * S * _crouch, -0.4 * S * _lunge)
	_clock += delta
	# Twitches: now and then the whole body jerks a little, more often when it
	# is hunting -- stillness broken by a flinch is what reads as wrong.
	_twitch_t -= delta
	if _twitch_t <= 0.0:
		var hunting := _ai == "stalk" or _ai == "crouch"
		_twitch_t = randf_range(0.25, 0.8) if hunting else randf_range(0.8, 2.5)
		_twitch = randf_range(-1.0, 1.0) * (0.16 if hunting else 0.07)
	_twitch = move_toward(_twitch, 0.0, delta * 0.9)
	_look.rotation = Vector3(0.18 * _crouch - 0.15 * _lunge, _twitch * 0.6, _twitch)
	# Jaws: shut when calm, working when it hunts, wide before a bite and
	# snapped shut on it.
	var jaw := 0.12 + 0.05 * sin(_clock * 3.0)
	if _ai == "stalk" or _ai == "retreat":
		jaw = 0.3 + 0.18 * sin(_clock * 17.0)
	elif _ai == "crouch" or _ai == "pounce":
		jaw = 0.75
	elif _ai == "bite":
		jaw = 0.8 if _ai_t > 0.2 else 0.0
	for j in _jaws.size():
		var jp: Node3D = _jaws[j]
		jp.rotation.y = lerp_angle(jp.rotation.y, jaw * (1.0 if j == 0 else -1.0), clampf(delta * 18.0, 0.0, 1.0))
	# The tail curls up over the back and sways; drawn back to strike before a pounce.
	var coil := 0.42 + 0.2 * _crouch
	for t in _tail.size():
		var tp: Node3D = _tail[t]
		tp.rotation.x = -coil + (0.2 if t == 0 else 0.0)
		tp.rotation.y = sin(_clock * 1.7 + t * 0.6) * 0.08
	# Eyes throb, faster when it has seen you.
	if _eye_mat != null:
		var rate := 9.0 if _ai in ["stalk", "crouch", "pounce", "bite"] else 2.0
		_eye_mat.emission_energy_multiplier = 4.0 + 1.5 * sin(_clock * rate)
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 4.0, 0.0)
		for m in _mats:
			(m as StandardMaterial3D).emission = Color(0.9, 0.1, 0.05) * _flash
	var body_up := global_transform.basis.y
	for i in LEGS:
		var hip: Vector3 = _look.global_transform * (_hips[i] as Vector3)
		var f: Vector3 = _foot[i]
		var to_f := f - hip
		var d := to_f.length()
		var dir := to_f / maxf(d, 0.0001)
		d = clampf(d, 0.15, UPPER + LOWER - 0.02)
		var ca := clampf((UPPER * UPPER + d * d - LOWER * LOWER) / (2.0 * UPPER * d), -1.0, 1.0)
		var sa := sqrt(1.0 - ca * ca)
		var outward := hip - global_position
		outward = (outward - body_up * outward.dot(body_up)).normalized()
		var pole := body_up + outward * 0.25
		var bend := pole - dir * pole.dot(dir)
		if bend.length() < 0.001:
			bend = body_up
		bend = bend.normalized()
		var knee := hip + dir * UPPER * ca + bend * UPPER * sa
		_segment(_femur[i], hip, knee, body_up)
		_segment(_tibia[i], knee, hip + dir * d, body_up)
		# A spur of bone off the top of each knee, raked back.
		_segment(_spikes[i], knee, knee + (bend * 0.8 - dir * 0.3).normalized() * 0.42 * S, body_up)


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
	for i in LEGS:
		var r: Vector3 = _rest[i]
		_foot[i] = global_transform * r.lerp(Vector3(r.x * 0.2, -RIDE * 0.4, r.z * 0.2), k)
	_pose(delta)
	_look.position = Vector3(0, -0.45 * S * k, 0)
	if _die_t > 1.6:
		var s := clampf(1.0 - (_die_t - 1.6) / 0.6, 0.0, 1.0)
		scale = Vector3.ONE * maxf(s, 0.01)
		if s <= 0.0:
			queue_free()
