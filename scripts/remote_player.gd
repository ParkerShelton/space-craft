extends Node3D
class_name RemotePlayer

## Another player, as seen by you.
##
## Deliberately a few boxes rather than the creature rig: a person is the one
## thing in this world you must be able to pick out instantly at a distance, and
## a plain silhouette in a colour nobody else has does that better than detail.

const ACT_NONE := 0
const ACT_MINE := 1
const ACT_PLACE := 2
## Set alongside the action above; see Player.action_state.
const CROUCH_BIT := 4

var peer_id := 0

var _target := Vector3.ZERO
var _label: Label3D
var _body: Node3D                  # everything but the name tag
var _crouch := 0.0                 # 0 standing, 1 down
var _crouch_want := 0.0
var _arms: Array[Node3D] = []      # shoulder pivots, right first
var _legs: Array[Node3D] = []      # hip pivots, right first
var _phase := 0.0                  # walk cycle position
var _speed := 0.0                  # smoothed ground speed, for the walk cycle
var _action := ACT_NONE
var _swing := 0.0                  # 0..1 through a mine or place motion
var _last_pos := Vector3.ZERO
var _have_last := false


func setup(id: int) -> void:
	# One node holding the whole figure, so crouching moves it as a piece rather
	# than as eight separate offsets that have to agree with each other.
	_body = Node3D.new()
	add_child(_body)
	peer_id = id
	# A stable colour per player, so the same person is the same colour all
	# session and no two are nearly the same shade.
	var hue := fposmod(float(id) * 0.618034, 1.0)
	var body := Color.from_hsv(hue, 0.55, 0.85)
	var trim := Color.from_hsv(hue, 0.65, 0.55)
	# EVERY height here is measured from the body CENTRE, because that is where a
	# player's origin sits: its collision capsule is 1.8 tall and centred on the
	# node. Building from the feet up left the figure hovering above the ground.
	const FEET := -0.9
	_box(_body, Vector3(0.62, 0.72, 0.38), Vector3(0, FEET + 1.14, 0), body)   # torso
	_box(_body, Vector3(0.46, 0.42, 0.42), Vector3(0, FEET + 1.71, 0), trim)   # head
	for sx in [-1.0, 1.0]:
		_box(_body, Vector3(0.10, 0.10, 0.06),
			Vector3(sx * 0.11, FEET + 1.77, -0.22), Color(0.05, 0.05, 0.06))  # eyes

	# Limbs hang from PIVOTS at the shoulder and hip, with the box offset below
	# so it swings from its top end. Rotating a centred box instead spins it
	# about its middle, which reads as a limb detaching and spinning in place.
	for sx in [1.0, -1.0]:
		var sh := _pivot(Vector3(sx * 0.40, FEET + 1.47, 0))
		_box(sh, Vector3(0.18, 0.66, 0.26), Vector3(0, -0.33, 0), trim)
		_arms.append(sh)
		var hip := _pivot(Vector3(sx * 0.17, FEET + 0.78, 0))
		_box(hip, Vector3(0.24, 0.78, 0.28), Vector3(0, -0.39, 0), trim)
		_legs.append(hip)

	_label = Label3D.new()
	# Peer ids are large random numbers; the last four digits are enough to tell
	# two people apart and short enough to read across a field.
	_label.text = "Player %04d" % (id % 10000)
	_label.font_size = 48
	_label.pixel_size = 0.006
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.position = Vector3(0, FEET + 2.25, 0)
	add_child(_label)


func _pivot(pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	_body.add_child(n)
	return n


func _box(parent: Node3D, size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.85
	mi.material_override = mat
	parent.add_child(mi)
	return mi


## Where the network last said this player was, which way it faced, and what it
## was doing. Updates arrive about twenty times a second, so they are smoothed
## toward rather than snapped to -- otherwise everyone else visibly stutters.
func remote_state(pos: Vector3, facing: Vector3, up: Vector3, action: int) -> void:
	_target = pos
	_action = action & 3
	_crouch_want = 1.0 if (action & CROUCH_BIT) != 0 else 0.0
	var u := up.normalized()
	if u.length_squared() < 0.5:
		return
	# Flatten the facing into the surface the player is standing on. Without this
	# the body leans by however much its heading pointed into or out of the
	# ground, which is what had everyone standing diagonally.
	var f := facing - u * facing.dot(u)
	if f.length_squared() < 0.0001:
		f = u.cross(Vector3.RIGHT)
		if f.length_squared() < 0.0001:
			f = u.cross(Vector3.FORWARD)
	f = f.normalized()
	# Godot faces -Z, so the basis Z column is the BACKWARD direction.
	basis = Basis(f.cross(u).normalized(), u, -f)


func _process(delta: float) -> void:
	# Walking speed is MEASURED from how far the body actually moved rather than
	# sent over the network. It costs nothing, and it stays in step with the
	# position you can see even when an update goes missing.
	if _have_last:
		var moved := global_position.distance_to(_last_pos) / maxf(delta, 0.0001)
		_speed = lerpf(_speed, moved, clampf(delta * 8.0, 0.0, 1.0))
	_last_pos = global_position
	_have_last = true

	if global_position.distance_to(_target) > 12.0:
		global_position = _target      # teleport rather than sail across the map
	else:
		global_position = global_position.lerp(_target, clampf(delta * 12.0, 0.0, 1.0))

	_animate(delta)


func _animate(delta: float) -> void:
	if _arms.size() < 2 or _legs.size() < 2:
		return
	# Down on one knee: the whole figure drops and leans in. Eased, so it reads
	# as somebody crouching rather than as somebody teleporting downward -- and
	# on the same curve the first-person eye uses, so both look like one motion.
	_crouch = move_toward(_crouch, _crouch_want, delta * 2.2)
	if _body != null:
		_body.position.y = -0.34 * _crouch
		_body.rotation.x = 0.32 * _crouch
	# The cycle advances with SPEED, not with time, so the feet keep pace with
	# the ground instead of the legs windmilling while barely moving.
	var walking: float = clampf(_speed / 4.0, 0.0, 1.0)
	_phase += delta * (2.0 + _speed * 1.6)
	var swing := sin(_phase) * 0.85 * walking

	_legs[0].rotation.x = swing
	_legs[1].rotation.x = -swing
	# Arms counter-swing: the opposite arm goes with each leg, as in a real gait.
	var arm_swing := -swing * 0.7
	var busy := _action != ACT_NONE
	if busy:
		_swing = minf(_swing + delta * (6.0 if _action == ACT_MINE else 5.0), 1.0)
	else:
		_swing = maxf(_swing - delta * 5.0, 0.0)

	# A limb hangs along its pivot's local -Y, so a POSITIVE x rotation swings it
	# forward and a large one carries it overhead. Getting this backwards put both
	# the chop and the reach behind the body, where you cannot see them at all.
	if _action == ACT_MINE:
		# A repeated overhead chop with the right arm; the left keeps walking.
		var chop := absf(sin(_phase * 3.2))
		_arms[0].rotation.x = lerpf(arm_swing, 1.3 + chop * 1.2, _swing)
		_arms[1].rotation.x = -arm_swing
	elif _action == ACT_PLACE:
		# A single reach straight out in front, held briefly.
		_arms[0].rotation.x = lerpf(arm_swing, 1.55, _swing)
		_arms[1].rotation.x = -arm_swing
	else:
		_arms[0].rotation.x = arm_swing
		_arms[1].rotation.x = -arm_swing
