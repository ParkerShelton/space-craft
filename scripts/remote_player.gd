extends Node3D
class_name RemotePlayer

## Another player, as seen by you.
##
## Deliberately a few boxes rather than the creature rig: a person is the one
## thing in this world you must be able to pick out instantly at a distance, and
## a plain silhouette in a colour nobody else has does that better than detail.

var peer_id := 0

var _target := Vector3.ZERO
var _target_yaw := 0.0
var _label: Label3D


func setup(id: int) -> void:
	peer_id = id
	# A stable colour per player, so the same person is the same colour all
	# session and two players are never nearly the same shade.
	var hue := fposmod(float(id) * 0.618034, 1.0)
	var body := Color.from_hsv(hue, 0.55, 0.85)
	var trim := Color.from_hsv(hue, 0.65, 0.55)
	_box(Vector3(0.62, 0.90, 0.38), Vector3(0, 0.95, 0), body)      # torso
	_box(Vector3(0.46, 0.42, 0.42), Vector3(0, 1.62, 0), trim)      # head
	for sx in [-1.0, 1.0]:
		_box(Vector3(0.20, 0.80, 0.24), Vector3(sx * 0.41, 0.98, 0), trim)   # arms
		_box(Vector3(0.24, 0.90, 0.28), Vector3(sx * 0.17, 0.05, 0), trim)   # legs
	# eyes, so you can tell which way someone is facing at a glance
	for sx in [-1.0, 1.0]:
		_box(Vector3(0.10, 0.10, 0.06), Vector3(sx * 0.11, 1.68, -0.22),
			Color(0.05, 0.05, 0.06))
	_label = Label3D.new()
	_label.text = "Player %d" % id
	_label.font_size = 48
	_label.pixel_size = 0.006
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.position = Vector3(0, 2.15, 0)
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


## Where the network last said this player was. Position updates arrive maybe
## twenty times a second, so they are smoothed toward rather than snapped to --
## otherwise everyone else visibly stutters.
func remote_state(pos: Vector3, yaw: float, up: Vector3) -> void:
	_target = pos
	_target_yaw = yaw
	if up.length() > 0.01:
		var fwd := Vector3(sin(yaw), 0, cos(yaw))
		var side := up.cross(fwd)
		if side.length() > 0.01:
			basis = Basis(side.normalized(), up.normalized(),
				side.normalized().cross(up.normalized()))


func _process(delta: float) -> void:
	if global_position.distance_to(_target) > 12.0:
		global_position = _target      # teleport rather than sail across the map
	else:
		global_position = global_position.lerp(_target, clampf(delta * 12.0, 0.0, 1.0))
