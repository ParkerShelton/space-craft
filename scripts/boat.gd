class_name Boat
extends CharacterBody3D
## A small wooden boat: made at a Carpenter's Bench, set down on water, sat in
## and rowed about.
##
## It is deliberately the simplest vehicle the game could have. It floats -- it
## finds the water surface under itself every frame and rides on it -- and it
## goes where you point it. There is no fuel, no damage model and nothing to
## repair, because the point of it is crossing a lake you would otherwise have
## to swim, which is a thing you want to be able to do on the first afternoon
## of a world out of nothing but wood.
##
## Riding it reuses the seat: it is in the "ship_seat" group with a `sit_at`, so
## right-clicking sits you in it and crouch gets you out, exactly as the pilot's
## chair does. The only thing it adds is `drive`, which the player calls with
## your movement input while you are sat in something that can be driven.

const FLOAT_LINE := 0.34      # how deep she sits, as a fraction of a block
const ACCEL := 7.0            # how hard she answers the throttle
const TOP_SPEED := 7.5
const DRAG := 1.6             # what the water takes back when you stop
const TURN_RATE := 1.9        # radians/sec at full helm
const SINK_RATE := 14.0       # how fast she falls when there is no water under her
const RISE_RATE := 6.0        # how fast she settles onto the surface

var world: WorldManager
var _drive := Vector2.ZERO    # what the pilot asked for this frame
var _afloat := false


func _ready() -> void:
	# FLOATING, not the default GROUNDED. Grounded mode measures everything
	# against up_direction and will stop a body it believes is standing on a
	# slope -- which, to a boat sitting in water on a round world, is every
	# frame. It answered the helm and refused the throttle.
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	add_to_group("ship_seat")
	set_meta("sit_at", Vector3(0, 0.62, 0.25))
	if get_child_count() == 0:
		_build()


func _build() -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = hull_mesh()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# Two boxes rather than one per plank: a hull you can stand in and a floor
	# under it. Colliding with every strake would catch you on the gunwale
	# climbing in, and nobody ever wants that.
	for box in [[Vector3(0, 0.12, 0), Vector3(1.5, 0.24, 2.9)],
			[Vector3(-0.72, 0.42, 0), Vector3(0.14, 0.44, 2.9)],
			[Vector3(0.72, 0.42, 0), Vector3(0.14, 0.44, 2.9)],
			[Vector3(0, 0.42, -1.44), Vector3(1.5, 0.44, 0.14)],
			[Vector3(0, 0.42, 1.44), Vector3(1.5, 0.44, 0.14)]]:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = box[1]
		cs.shape = bs
		cs.position = box[0]
		add_child(cs)


## A clinker-built dinghy in boxes: a floor, strakes lapped up either side, a
## stem and a transom, a thwart to sit on and an oar laid across it.
static func hull_mesh() -> ArrayMesh:
	# Wood, not planks: she is made of ten logs at a bench and she should look
	# like it. The three tones are the same timber worked differently -- sawn
	# strakes, the darker heartwood of floor and keel, and the pale rubbed rail.
	var plank := Blocks.color_of(Blocks.WOOD)
	var dark := Color(plank.r * 0.70, plank.g * 0.66, plank.b * 0.60)
	var trim := Color(minf(plank.r * 1.18, 1.0), minf(plank.g * 1.12, 1.0),
		minf(plank.b * 1.02, 1.0))
	var boxes: Array = [
		[Vector3(0, 0.10, 0), Vector3(1.34, 0.16, 2.74), dark],        # floor
		[Vector3(0, 0.06, 0), Vector3(0.26, 0.12, 2.86), dark],        # keel
	]
	# The strakes: three a side, each a little wider and higher than the last,
	# which is what gives a boat its flare without curving a single face.
	for i in 3:
		var y: float = 0.20 + float(i) * 0.15
		var half: float = 0.60 + float(i) * 0.075
		var col: Color = plank if (i % 2) == 0 else dark
		for sx in [-1.0, 1.0]:
			boxes.append([Vector3(sx * half, y, 0), Vector3(0.11, 0.17, 2.72), col])
	# Stem and transom, raked the way the ends of a boat are.
	boxes.append([Vector3(0, 0.30, -1.36), Vector3(1.22, 0.40, 0.13), plank])
	boxes.append([Vector3(0, 0.38, -1.44), Vector3(0.90, 0.36, 0.13), dark])
	boxes.append([Vector3(0, 0.30, 1.36), Vector3(1.30, 0.40, 0.13), plank])
	# Gunwale: the rail you grip getting in.
	for sx2 in [-1.0, 1.0]:
		boxes.append([Vector3(sx2 * 0.68, 0.60, 0), Vector3(0.16, 0.09, 2.78), trim])
	# A thwart to sit on, and a second one forward for the look of it.
	boxes.append([Vector3(0, 0.56, 0.42), Vector3(1.30, 0.10, 0.36), trim])
	boxes.append([Vector3(0, 0.56, -0.70), Vector3(1.20, 0.09, 0.30), trim])
	# An oar, shipped across the thwarts.
	boxes.append([Vector3(0.30, 0.64, -0.20), Vector3(0.09, 0.07, 1.90), trim])
	boxes.append([Vector3(0.30, 0.64, -1.24), Vector3(0.20, 0.05, 0.52), plank])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var c: Color = b[2]
		var p0: Vector3 = (b[0] as Vector3) - (b[1] as Vector3) * 0.5
		var p1: Vector3 = (b[0] as Vector3) + (b[1] as Vector3) * 0.5
		for fi in 6:
			st.set_color(c)
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var m := st.commit()
	if m.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.9
		m.surface_set_material(0, mat)
	return m


## The model shrunk into the unit cube the inventory photographs.
static func icon_mesh() -> ArrayMesh:
	var m := hull_mesh()
	var st := SurfaceTool.new()
	st.create_from(m, 0)
	var arr := st.commit_to_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] = (verts[i] - Vector3(0, 0.35, 0)) * 0.33
	arr[Mesh.ARRAY_VERTEX] = verts
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	out.surface_set_material(0, mat)
	return out


## What the pilot is asking for: y is throttle, x is helm. Called by the player
## every frame they are sat in her; zero when nobody is.
func drive(input: Vector2) -> void:
	_drive = input


func _physics_process(delta: float) -> void:
	if world == null:
		return
	var g := world.gravity_at(global_position)
	var up: Vector3 = (-g).normalized() if g.length() > 0.01 else Vector3.UP
	_keep_upright(up, delta)
	# Helm first, so the throttle pushes wherever she is now pointing.
	if absf(_drive.x) > 0.01:
		rotate(up, -_drive.x * TURN_RATE * delta)
	var fwd: Vector3 = -global_transform.basis.z
	var flat: Vector3 = (fwd - up * fwd.dot(up)).normalized()
	var along: float = velocity.dot(flat)
	if _afloat and absf(_drive.y) > 0.01:
		along = move_toward(along, TOP_SPEED * signf(_drive.y), ACCEL * delta)
	else:
		along = move_toward(along, 0.0, DRAG * delta)
	var vert: float = velocity.dot(up)
	var surf = _surface_under(up)
	if surf == null:
		# No water beneath her: she is a heavy wooden box and behaves like one.
		_afloat = false
		vert -= g.length() * delta
	else:
		_afloat = true
		# Ride the surface rather than bob toward it: a boat that springs is a
		# boat you cannot aim.
		var want: float = float(surf) - FLOAT_LINE
		var here: float = _height_along(global_position, up)
		var diff: float = want - here
		vert = clampf(diff * RISE_RATE, -SINK_RATE, RISE_RATE)
	velocity = flat * along + up * vert
	# move_and_collide, not move_and_slide. The ship moves this way too, and on
	# this project move_and_slide advanced the hull about two millimetres a
	# frame while velocity sat at full speed -- whatever it was measuring, it
	# was not the distance asked for.
	var hit := move_and_collide(velocity * delta)
	if hit != null:
		velocity = velocity.slide(hit.get_normal())
		move_and_collide(velocity * delta * 0.5)
	_drive = Vector2.ZERO


## How high a point is along the planet's up, in the planet's own frame -- the
## only "height" that means anything on a round world.
func _height_along(at: Vector3, up: Vector3) -> float:
	return at.dot(up)


## Where the water surface is under her, along `up`, or null for dry land. Looks
## a little way down from just above her, so she finds the surface she is
## sitting on rather than one two hills away.
func _surface_under(up: Vector3):
	var p: Planet = world.nearest_planet(global_position)
	if p == null or p.water_style != p.WATER_LIQUID:
		return null
	var from: Vector3 = global_position + up * 1.2
	for step in 5:
		var at: Vector3 = from - up * (float(step) * 1.0)
		var v := p.world_to_voxel(at)
		if p.get_id(v) != Blocks.WATER:
			continue
		var fill: float = p.water_fill(v)
		# The cell fills from its down face up, so the surface is that far above
		# the bottom of the cell.
		var cell_bottom: Vector3 = p.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)) - up * 0.5
		return _height_along(cell_bottom, up) + fill
	return null


## Keep her deck level with the world. She is a boat, not a spaceship: however
## she was put down, she sits flat on the water.
func _keep_upright(up: Vector3, delta: float) -> void:
	var b := global_transform.basis
	var fwd: Vector3 = -b.z
	var flat: Vector3 = fwd - up * fwd.dot(up)
	if flat.length() < 0.01:
		flat = b.x
	flat = flat.normalized()
	var want := Basis(up.cross(-flat).normalized(), up, -flat)
	var t := global_transform
	t.basis = b.slerp(want, clampf(delta * 8.0, 0.0, 1.0)).orthonormalized()
	global_transform = t
