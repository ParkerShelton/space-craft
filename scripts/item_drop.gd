class_name ItemDrop
extends Node3D
## An item lying in the world: falls, comes to rest on whatever is under it, and
## is picked up by walking over it.
##
## Deliberately not a physics body. It only ever needs to fall straight down
## the planet's gravity and stop on a block, and asking the voxel grid what is
## underneath does that exactly, with none of the jitter or tunnelling a rigid
## body gets on a trimesh.

## Close enough to be pulled in, and close enough to be taken.
const ATTRACT_RADIUS := 1.9
const COLLECT_RADIUS := 0.6
## Too new to pick up. Without this a drop at your feet is in your pocket
## before you have seen it land -- which defeats the point of it landing.
const PICKUP_DELAY := 0.7
## Gone after this long unclaimed, as in Minecraft. Five minutes: long enough
## to walk back for, short enough that a forest cleared an hour ago is not
## still carpeted in saplings.
const LIFETIME := 300.0
const SIZE := 0.28

var planet: Planet
var item_id := 0
var count := 1
var props := {}
var src := ""
var mat := {}
## What to say when it is picked up.
var label := ""

var velocity := Vector3.ZERO
var _age := 0.0
var _resting := false
var _mesh: MeshInstance3D
var _spin := 0.0


## `pos` is in the planet's own space.
static func spawn(p: Planet, pos: Vector3, id: int, n: int, item_props: Dictionary,
		item_src: String, item_mat: Dictionary, say: String, kick: Vector3) -> ItemDrop:
	var d := ItemDrop.new()
	d.planet = p
	d.item_id = id
	d.count = n
	d.props = item_props
	d.src = item_src
	d.mat = item_mat
	d.label = say
	d.velocity = kick
	p.add_child(d)
	d.position = pos
	return d


func _ready() -> void:
	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * SIZE
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(mat.get("color", Blocks.color_of(item_id)))
	box.material = m
	_mesh.mesh = box
	add_child(_mesh)
	_spin = randf() * TAU


func _physics_process(delta: float) -> void:
	_age += delta
	if _age > LIFETIME or planet == null or not is_instance_valid(planet):
		queue_free()
		return
	var up := _up()
	# Picked up: drawn toward the player once they are close, taken once they
	# are on top of it.
	var world: WorldManager = planet.get_parent() as WorldManager
	var pl: Node3D = world.player if world != null else null
	if pl != null and _age > PICKUP_DELAY:
		var target := planet.to_local(pl.global_position)
		var to := target - position
		var dist := to.length()
		if dist < COLLECT_RADIUS:
			_collect(pl)
			return
		if dist < ATTRACT_RADIUS:
			position += to.normalized() * minf(dist, delta * 8.0)
			_resting = false
			velocity = Vector3.ZERO
			_animate(delta, up)
			return
	if not _resting:
		velocity += -up * 18.0 * delta
		var step := position + velocity * delta
		# Landing: the cell the bottom of the item is about to enter is solid.
		var below := step - up * (SIZE * 0.5)
		if planet._is_solid_block(Vector3i(below.floor())):
			# Sit on top of that block, keeping where it is across the face.
			var cell := Vector3(Vector3i(below.floor()))
			var lp := step - cell - Vector3(0.5, 0.5, 0.5)
			var along := lp.dot(up)
			step += up * (0.5 - along + SIZE * 0.5 + 0.02)
			velocity = Vector3.ZERO
			_resting = true
		position = step
	else:
		# The ground it was sitting on could be dug out from under it.
		var under := position - up * (SIZE * 0.5 + 0.05)
		if not planet._is_solid_block(Vector3i(under.floor())):
			_resting = false
	_animate(delta, up)


## Turning slowly and bobbing on the spot, which is how you see there is
## something there to pick up.
func _animate(delta: float, up: Vector3) -> void:
	_spin += delta * 1.6
	var x := up.cross(Vector3(0.31, 0.12, 0.94)).normalized()
	var b := Basis(x, up, x.cross(up)).rotated(up, _spin)
	_mesh.transform = Transform3D(b, up * (0.06 * sin(_age * 2.6) if _resting else 0.0))


func _up() -> Vector3:
	var g := planet.gravity_at(planet.to_global(position))
	if g.length() < 0.01:
		return Vector3.UP
	return (planet.global_transform.basis.inverse() * -g).normalized()


func _collect(pl: Node) -> void:
	var left: int = pl.call("_add_item", item_id, count, props, src, mat)
	if left >= count:
		return       # no room: leave it lying there
	pl.call("_refresh_slots")
	if label != "":
		pl.call("_toast", "Picked up " + label)
	if left > 0:
		count = left
		return
	queue_free()
