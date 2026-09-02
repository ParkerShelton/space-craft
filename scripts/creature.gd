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
const LUNGE_DURATION := 0.6      # safety cap; the real exit is closing to attack_range (see _lunger_ai)
const LUNGE_SPEED_MULT := 1.6    # a committed step, not a blink -- was 3.0, which blew straight through the player
const RECOVER_TIME := 0.6
const KNOCKBACK_TIME := 0.25
const KNOCKBACK_MULT := 3.0
const CIRCLE_MIN := 0.2
const CIRCLE_MAX := 0.5
const FEINT_RESET_TIME := 0.35
const BLOCK_MAX_TIME := 1.5      # safety cap in case is_heavy_telegraphed() gets stuck true
const BLOCK_DAMAGE_MULT := 0.2

var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _attack_cd := 0.0
var _landing := false     # flyer: currently descending to perch on the ground
var _perched := false     # flyer: sitting on the ground, wings folded, will take off again
var _phase := 0.0
var _legs: Array = []       # leg pivots (Node3D), animated for a walk cycle
var _arms: Array = []       # arm pivots (bipeds only), light counter-swing
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
var _shield: Node3D
var _telegraph_total := 0.45    # the actual (jittered) duration chosen for the current telegraph


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


# --- body assembly (boxes only, per body plan) ---------------------------------

func _build_body() -> void:
	_model = Node3D.new()
	add_child(_model)
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
	var leg_len := 0.6 * s
	var torso := Vector3(0.55, 0.85, 0.5) * s
	var torso_y := leg_len + torso.y * 0.5
	_mk_box(_model, torso, Vector3(0, torso_y, 0), color)
	_mk_box(_model, Vector3(0.45, 0.45, 0.45) * s, Vector3(0, torso_y + torso.y * 0.65, 0), accent)
	for sx in [-1, 1]:
		var pivot := _mk_pivot(_model, Vector3(sx * 0.18 * s, leg_len, 0))
		_mk_box(pivot, Vector3(0.2, leg_len, 0.24) * s, Vector3(0, -leg_len * 0.5, 0), accent)
		_legs.append(pivot)
	# Arms -- makes a biped actually read as humanoid instead of a legged torso.
	# arm_count is data-driven (species dict) for future extra-limb variety, but
	# only 2 is used today. Attached at shoulder height, animated as a light
	# counter-swing to the legs in _animate.
	var arm_len := 0.55 * s
	var arm_count: int = int(species.get("arm_count", 2))
	var shoulder_y := torso_y + torso.y * 0.32
	for i in arm_count:
		var sx := -1.0 if i % 2 == 0 else 1.0
		var pivot := _mk_pivot(_model, Vector3(sx * (torso.x * 0.5 + 0.06 * s), shoulder_y, 0))
		_mk_box(pivot, Vector3(0.16, arm_len, 0.16) * s, Vector3(0, -arm_len * 0.5, 0), color)
		_arms.append(pivot)
	# A "lunger" gets a visible sword (right hand) + shield (left hand) -- the
	# whole point of the user's ask ("actually feel like a real player"), and
	# reuses the same box-mesh view-model style as the player's held weapon
	# (see player.gd:_build_held_weapon). Held via the arm pivots so they
	# naturally follow the existing arm-swing animation.
	if species.get("pattern", "") == "lunger" and _arms.size() >= 2:
		_build_sword(_arms[1], s)
		_build_shield(_arms[0], s)


func _build_sword(hand: Node3D, s: float) -> void:
	_sword = Node3D.new()
	hand.add_child(_sword)
	_sword.position = Vector3(0, -0.5 * s, 0.05 * s)
	_mk_box(_sword, Vector3(0.05, 0.22, 0.05) * s, Vector3(0, -0.11 * s, 0), Color(0.3, 0.25, 0.2))    # hilt
	_mk_box(_sword, Vector3(0.18, 0.03, 0.03) * s, Vector3(0, 0, 0), Color(0.4, 0.38, 0.35))           # guard
	_mk_box(_sword, Vector3(0.05, 0.5, 0.02) * s, Vector3(0, 0.28 * s, 0), Color(0.75, 0.78, 0.82))    # blade


func _build_shield(hand: Node3D, s: float) -> void:
	_shield = Node3D.new()
	hand.add_child(_shield)
	_shield.position = Vector3(0, -0.4 * s, 0.05 * s)
	_mk_box(_shield, Vector3(0.05, 0.5, 0.35) * s, Vector3(0, 0, 0), Color(0.35, 0.3, 0.25))


func _build_serpent(s: float, color: Color, accent: Color) -> void:
	var n := 5
	var seg_len := 0.5 * s
	for i in n:
		var c := color if i % 2 == 0 else accent
		var sz := lerpf(0.55, 0.28, float(i) / float(n - 1)) * s
		var pos := Vector3(0, sz * 0.5, -float(i) * seg_len)
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

	if ppos != null:
		var to_player: Vector3 = ppos - global_position
		var dist := to_player.length()
		if temperament == "hostile" and dist < float(species.get("aggro_range", 12.0)):
			handled = true
			if species.get("pattern", "") == "lunger":
				var r := _lunger_ai(delta, up, ppos, dist, to_player)
				wish = r["wish"]
				moving_speed = speed * float(r["speed_mult"])
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
		if wish.length() > 0.001:
			var fwd := -global_transform.basis.z
			var new_fwd := fwd.slerp(wish, clampf(delta * 6.0, 0.0, 1.0)) if fwd.dot(wish) > -0.98 else wish
			look_at(global_position + new_fwd, up)

	var v_up := velocity.dot(up)
	v_up += -GRAVITY_ACCEL * delta
	if is_on_floor():
		v_up = maxf(v_up, 0.0)
	velocity = wish * moving_speed + up * v_up
	up_direction = up
	move_and_slide()


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
				_is_feint = randf() < lerpf(0.05, 0.4, skill)
				var tt: float = maxf(float(species.get("telegraph_time", 0.45)), 0.05)
				_state_t = randf_range(tt * 0.7, tt * 1.3)  # per-attempt jitter, not a fixed metronome
				_telegraph_total = _state_t
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
				else:
					_state = "attack"
					_state_t = LUNGE_DURATION
					_lunge_target = ppos  # captured NOW, not re-tracked -- see doc comment above
			return {"wish": Vector3.ZERO, "speed_mult": 1.0}
		"attack":
			var to_target := _lunge_target - global_position
			var flat_target := to_target - up * to_target.dot(up)
			if dist < attack_range or _state_t <= 0.0:
				if dist < attack_range * 1.4 and world.player.has_method("take_damage"):
					world.player.take_damage(float(species.get("damage", 5.0)))
				_state = "recover"
				_state_t = RECOVER_TIME
				return {"wish": Vector3.ZERO, "speed_mult": 1.0}
			return {"wish": flat_target, "speed_mult": LUNGE_SPEED_MULT}
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
	for i in _arms.size():
		var asgn := -1.0 if i % 2 == 0 else 1.0  # opposite leg on the same side
		_arms[i].rotation.x = sin(_phase * asgn) * 0.35 * moving
	# "lunger" wind-up/dash visual: lean back during telegraph (a readable cue
	# to dodge -- identical whether it's a real attack or a feint, on purpose),
	# snap forward into the dash, ease back to neutral otherwise.
	if _model != null:
		var scale_f: float = species.get("scale", 1.0)
		if _state == "telegraph":
			var t := clampf(1.0 - _state_t / maxf(_telegraph_total, 0.05), 0.0, 1.0)
			_model.position.z = 0.3 * scale_f * t
		elif _state == "attack":
			_model.position.z = lerpf(_model.position.z, -0.15 * scale_f, clampf(delta * 14.0, 0.0, 1.0))
		else:
			_model.position.z = lerpf(_model.position.z, 0.0, clampf(delta * 8.0, 0.0, 1.0))
	# Shield raises while actively blocking -- the visual payoff for the
	# player's heavy-swing tell actually meaning something to the enemy.
	if _shield != null:
		var target_rot := -0.9 if _state == "block" else 0.0
		_shield.rotation.x = lerpf(_shield.rotation.x, target_rot, clampf(delta * 10.0, 0.0, 1.0))
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
	var is_lunger: bool = species.get("pattern", "") == "lunger"
	if is_lunger and _state == "block":
		_health -= dmg * BLOCK_DAMAGE_MULT
	else:
		_health -= dmg
		if stagger > 0.0 and is_lunger:
			_stagger -= stagger
			if _stagger <= 0.0:
				_apply_stagger_interrupt()
	if _health <= 0.0:
		queue_free()
		return true
	return false


func _apply_stagger_interrupt() -> void:
	_stagger = float(species.get("stagger_max", 3.0))
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
