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


var _mat: StandardMaterial3D
var _skin_tex: ImageTexture
var _pieces: Array = []
var _piece_parts: Array = []


func setup(id: int) -> void:
	# One node holding the whole figure, so crouching moves it as a piece rather
	# than as eight separate offsets that have to agree with each other.
	_body = Node3D.new()
	add_child(_body)
	peer_id = id
	# A stable colour per player, so the same person is the same colour all
	# session and no two are nearly the same shade. It is the DEFAULT skin now
	# rather than the only one: nobody's figure changes the day skins arrive, it
	# just becomes something they can paint over.
	var hue := fposmod(float(id) * 0.618034, 1.0)
	# EVERY height here is measured from the body CENTRE, because that is where a
	# player's origin sits: its collision capsule is 1.8 tall and centred on the
	# node. Building from the feet up left the figure hovering above the ground.
	const FEET := -0.9
	# The eyes used to be two small boxes stuck to the front of the head. They
	# are four pixels of the skin now, which is rather the point of having one.
	_part(_body, "body", Vector3(0.62, 0.72, 0.38), Vector3(0, FEET + 1.14, 0))
	_part(_body, "head", Vector3(0.46, 0.42, 0.42), Vector3(0, FEET + 1.71, 0))

	# Limbs hang from PIVOTS at the shoulder and hip, with the box offset below
	# so it swings from its top end. Rotating a centred box instead spins it
	# about its middle, which reads as a limb detaching and spinning in place.
	# -X is the figure's own right (it faces -Z), so that side wears the right
	# arm and leg. Mirroring this is the classic way to end up with a skin whose
	# left sleeve is on the wrong arm.
	for sx in [1.0, -1.0]:
		var side := "right" if sx < 0.0 else "left"
		var sh := _pivot(Vector3(sx * 0.40, FEET + 1.47, 0))
		_part(sh, side + "_arm", Vector3(0.18, 0.66, 0.26), Vector3(0, -0.33, 0))
		_arms.append(sh)
		var hip := _pivot(Vector3(sx * 0.17, FEET + 0.78, 0))
		_part(hip, side + "_leg", Vector3(0.24, 0.78, 0.28), Vector3(0, -0.39, 0))
		_legs.append(hip)
	set_skin(PlayerSkin.default_image(hue))

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


## Off in the skin editor's preview, where the figure is you rather than
## somebody across the map who needs labelling.
func show_nameplate(on: bool) -> void:
	if _label != null:
		_label.visible = on


func _pivot(pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	_body.add_child(n)
	return n


## One body part, wearing its own rectangles of the skin.
func _part(parent: Node3D, part: String, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = PlayerSkin.part_mesh(part, size)
	mi.position = pos
	parent.add_child(mi)
	_pieces.append(mi)
	_piece_parts.append(part)
	return mi


## The body, piece by piece, for anything that needs to turn a point on the
## figure back into a point on the skin -- which is what painting on it is.
func pieces() -> Array:
	var out: Array = []
	for i in _pieces.size():
		out.append({"node": _pieces[i], "part": _piece_parts[i]})
	return out


## Put a skin on.
##
## Every part shares ONE material, so changing skin is changing one texture
## rather than rebuilding the figure -- which is what will let the editor show
## its changes as they are painted.
func set_skin(img: Image) -> void:
	if _mat == null:
		_mat = PlayerSkin.make_material(PlayerSkin.texture_from(img))
		for p in _pieces:
			(p as MeshInstance3D).material_override = _mat
		return
	_skin_tex = _mat.albedo_texture as ImageTexture
	if _skin_tex != null and _skin_tex.get_size() == Vector2(PlayerSkin.ATLAS, PlayerSkin.ATLAS):
		_skin_tex.update(img)   # same size: reuse the texture rather than remaking it
	else:
		_mat.albedo_texture = PlayerSkin.texture_from(img)


## Which skin is on, as the hash of the bytes it came from. Only used to notice
## that a new one has arrived: decoding a PNG every frame to find out it is the
## same PNG would be the most expensive thing this class does.
var skin_tag := 0


## Wear the skin the network sent, if it is one we have not got on already.
## Anything that fails to decode, or is not a skin sheet, is IGNORED rather than
## reported: the cost of a bad packet should be that this player keeps the
## default figure, not that everyone's log fills up. A rejected packet still
## claims the tag, because this is called every frame from the bytes the network
## left in the peer record -- otherwise one bad skin would be decoded, and fail,
## sixty times a second for as long as that player stayed connected.
func wear_png(png: PackedByteArray) -> void:
	var tag := hash(png)
	if png.is_empty() or tag == skin_tag:
		return
	skin_tag = tag
	var img := Image.new()
	if img.load_png_from_buffer(png) != OK:
		return
	if img.get_width() != PlayerSkin.ATLAS or img.get_height() != PlayerSkin.ATLAS:
		return
	set_skin(img)


# --- cosmetics -------------------------------------------------------------

var _worn: Array = []              # nodes added by wear_look, to take off again
var _trail: CPUParticles3D
var look_tag := 0
## The inventory's figure trails all the time, so you can see the one you chose
## without having to walk about; everyone else's only while they move.
var trail_always := false


## Put on what is in the vanity slots: {slot: item id}. Called every frame from
## what the network holds, so it only rebuilds when that actually changes.
func wear_look(look: Dictionary) -> void:
	var tag := hash(look)
	if tag == look_tag:
		return
	look_tag = tag
	for n in _worn:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_worn.clear()
	_trail = null
	if _body == null:
		return
	for slot in look:
		var id := int(look[slot])
		if not Cosmetics.is_cosmetic(id) or Cosmetics.slot_of(id) != str(slot):
			continue
		match str(slot):
			"hat":
				_wear_mesh(_body, Cosmetics.piece_mesh(id), Cosmetics.HEAD_TOP)
			"face":
				_wear_mesh(_body, Cosmetics.piece_mesh(id), Cosmetics.HEAD_FRONT)
			"back":
				_wear_mesh(_body, Cosmetics.piece_mesh(id), Cosmetics.BACK)
			"shoes":
				for hip in _legs:
					_wear_mesh(hip, Cosmetics.piece_mesh(id), Cosmetics.SOLE)
			"shirt", "pants":
				var cb := Cosmetics.clothes_boxes(id)
				if not (cb["torso"] as Array).is_empty():
					_wear_mesh(_body, Cosmetics._boxes_mesh(cb["torso"], Vector3.ZERO, 1.0), Cosmetics.TORSO)
				# Sleeves and trouser legs are mirrored onto each side, so a stripe
				# down the outside of one leg is on the outside of the other too.
				for arm in _arms:
					if not (cb["arm"] as Array).is_empty():
						_wear_mesh(arm, Cosmetics._boxes_mesh(_mirror(cb["arm"], arm.position.x), Vector3.ZERO, 1.0), Vector3.ZERO)
				for hip in _legs:
					if not (cb["leg"] as Array).is_empty():
						_wear_mesh(hip, Cosmetics._boxes_mesh(_mirror(cb["leg"], hip.position.x), Vector3.ZERO, 1.0), Vector3.ZERO)
			"trail":
				_trail = Cosmetics.make_trail(id)
				if _trail != null:
					_trail.position = Vector3(0, -0.7, 0)
					add_child(_trail)
					_worn.append(_trail)


# --- what is in their hand ----------------------------------------------------

var _held: MeshInstance3D
var held_id := -1


## Put an item in the figure's right hand: its tool model if it has one, a small
## block of its colour if it is a block, nothing otherwise.
func hold(id: int) -> void:
	if id == held_id:
		return
	held_id = id
	if _held != null:
		_held.queue_free()
		_held = null
	if _arms.is_empty() or id <= 0:
		return
	var mi := MeshInstance3D.new()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if ToolModels.has_model(id):
		mi.mesh = ToolModels.mesh(id, Color(0.7, 0.7, 0.75))
		if ToolModels.is_upright(id):
			# Handle out forward from the fist, gripped near its end, so the
			# head swings down in front with the chop.
			mi.rotation = Vector3(-PI * 0.5, 0, 0)
			mi.position = Vector3(0, -0.62, -0.2)
		else:
			mi.position = Vector3(0, -0.5, -0.12)
	elif Blocks.is_placeable_block(Blocks.bottom_of(id)) or Blocks.is_ore(id) 			or Blocks.is_refined(id) or Blocks.is_intermediate(id):
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * 0.2
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Blocks.color_of(id)
		mat.roughness = 0.85
		bm.material = mat
		mi.mesh = bm
		mi.position = Vector3(0, -0.66, -0.1)
	else:
		mi.queue_free()
		return
	# The arm the mining chop animates.
	_arms[0].add_child(mi)
	_held = mi


func _mirror(boxes: Array, side_x: float) -> Array:
	if side_x >= 0.0:
		return boxes
	var out: Array = []
	for b in boxes:
		out.append([(b[0] as Vector3) * Vector3(-1, 1, 1), b[1], b[2]])
	return out


func _wear_mesh(parent: Node3D, mesh: Mesh, pos: Vector3) -> void:
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	_worn.append(mi)


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
	if _trail != null:
		_trail.emitting = trail_always or _speed > 0.8


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
