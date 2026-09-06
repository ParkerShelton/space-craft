extends Node3D
class_name RemotePlayer

## Another player, as seen by you.
##
## Deliberately a few boxes rather than the creature rig: a person is the one
## thing in this world you must be able to pick out instantly at a distance, and
## a plain silhouette in a colour nobody else has does that better than detail.

var peer_id := 0

var _target := Vector3.ZERO
var _label: Label3D


func setup(id: int) -> void:
	peer_id = id
	# A stable colour per player, so the same person is the same colour all
	# session and no two are nearly the same shade.
	var hue := fposmod(float(id) * 0.618034, 1.0)
	var body := Color.from_hsv(hue, 0.55, 0.85)
	var trim := Color.from_hsv(hue, 0.65, 0.55)
	# EVERY height here is measured from the body CENTRE, not from the feet,
	# because that is where a player's origin sits: its collision capsule is 1.8
	# tall and centred on the node. Building this figure from the feet up left it
	# hovering half a metre above the ground.
	const FEET := -0.9
	_box(Vector3(0.24, 0.78, 0.28), Vector3(-0.17, FEET + 0.39, 0), trim)
	_box(Vector3(0.24, 0.78, 0.28), Vector3(0.17, FEET + 0.39, 0), trim)
	_box(Vector3(0.62, 0.72, 0.38), Vector3(0, FEET + 1.14, 0), body)      # torso
	_box(Vector3(0.46, 0.42, 0.42), Vector3(0, FEET + 1.71, 0), trim)      # head
	for sx in [-1.0, 1.0]:
		_box(Vector3(0.18, 0.66, 0.26), Vector3(sx * 0.40, FEET + 1.14, 0), trim)
	# eyes, so you can tell which way someone is facing at a glance
	for sx in [-1.0, 1.0]:
		_box(Vector3(0.10, 0.10, 0.06), Vector3(sx * 0.11, FEET + 1.77, -0.22),
			Color(0.05, 0.05, 0.06))
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

func _box(size: Vector3, pos: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.85
	mi.material_override = mat
	add_child(mi)


## Where the network last said this player was. Updates arrive about twenty
## times a second, so they are smoothed toward rather than snapped to --
## otherwise everyone else visibly stutters.
func remote_state(pos: Vector3, facing: Vector3, up: Vector3) -> void:
	_target = pos
	var u := up.normalized()
	if u.length_squared() < 0.5:
		return
	# Flatten the facing into the surface the player is standing on. Without
	# this the body leans by however much its heading pointed into or out of the
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
	if global_position.distance_to(_target) > 12.0:
		global_position = _target      # teleport rather than sail across the map
	else:
		global_position = global_position.lerp(_target, clampf(delta * 12.0, 0.0, 1.0))
