class_name LeafDecay
extends Node
## Leaves that are no longer near any wood wither away, one at a time, over the
## next several seconds -- the way a crown left hanging in the air after you
## take a tree's trunk disappears in Minecraft.
##
## Only leaves the world grew. A hedge you planted leaf by leaf has no trunk
## and was never meant to have one.
##
## Nothing is scanned for this in the background. A leaf only needs asking
## about when the wood near it has changed, so the only leaves ever looked at
## are the ones around a log that has just been broken or felled.

## How far, through leaves, a leaf may be from wood and still live.
const REACH := 6
## Around a broken log, how far out leaves are looked at.
const NUDGE_RADIUS := 7
## Leaves asked about per frame, so a big crown is worked through over a few
## frames rather than all in one.
const CHECKS_PER_FRAME := 12
## A doomed leaf goes after a random wait in this range, so a crown thins out
## rather than vanishing in one frame.
const MIN_DELAY := 0.8
const MAX_DELAY := 7.0
## Bound on one "is there wood near this leaf" search.
const MAX_VISIT := 700

var planet: Planet
var world: WorldManager
var player: Node
var _check: Array[Vector3i] = []
var _queued := {}
var _dying := {}          # leaf -> seconds left


## Look at the leaves around `around` -- a log was just taken from there.
static func nudge(p: Planet, wm: WorldManager, pl: Node, around: Vector3i,
		radius: int = NUDGE_RADIUS) -> void:
	var r := Vector3i(radius, radius, radius)
	nudge_box(p, wm, pl, around - r, around + r)


## Look at every leaf inside a box, corners inclusive.
static func nudge_box(p: Planet, wm: WorldManager, pl: Node, lo: Vector3i, hi: Vector3i) -> void:
	var ld := _for(p, wm, pl)
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var v := Vector3i(x, y, z)
				if ld._queued.has(v) or ld._dying.has(v):
					continue
				if TreeFall._is_tree_leaf(p, v):
					ld._queued[v] = true
					ld._check.append(v)


## One per planet, made the first time it is needed.
static func _for(p: Planet, wm: WorldManager, pl: Node) -> LeafDecay:
	var ld := p.get_node_or_null("LeafDecay") as LeafDecay
	if ld == null:
		ld = LeafDecay.new()
		ld.name = "LeafDecay"
		ld.planet = p
		p.add_child(ld)
	ld.world = wm
	ld.player = pl
	return ld


func _process(delta: float) -> void:
	var n := 0
	while n < CHECKS_PER_FRAME and not _check.is_empty():
		var v: Vector3i = _check.pop_back()
		_queued.erase(v)
		n += 1
		if TreeFall._is_tree_leaf(planet, v) and not _near_wood(v):
			_dying[v] = randf_range(MIN_DELAY, MAX_DELAY)
	if _dying.is_empty():
		return
	var gone := {}
	for v in _dying.keys():
		var left: float = float(_dying[v]) - delta
		if left > 0.0:
			_dying[v] = left
			continue
		_dying.erase(v)
		# Asked again at the last moment: somebody may have put a log back.
		if TreeFall._is_tree_leaf(planet, v) and not _near_wood(v):
			gone[v] = Blocks.AIR
	if gone.is_empty() or world == null:
		return
	var cols := {}
	for v in gone:
		cols[v] = planet.color_of(Blocks.bottom_of(planet.get_id(v)))
	world.edit_blocks(planet, gone)
	for v in gone:
		var c: Vector3i = v
		var ax := planet._axis_of(Vector3(c) + Vector3(0.5, 0.5, 0.5))
		var up := Vector3i(roundi(ax.x), roundi(ax.y), roundi(ax.z))
		var at := Vector3(c) + Vector3(0.5, 0.5, 0.5)
		TreeFall.burst(planet, up, at, cols[v], 6)
		# The same chance a leaf broken by hand has, dropped where it was.
		# A canopy withering on its own is not a harvest: see WITHER_SAPLING_CHANCE.
		if randf() < Blocks.WITHER_SAPLING_CHANCE and player != null and is_instance_valid(player):
			var item: Dictionary = player.call("_roll_flora_seed", planet, "tree")
			if not item.is_empty():
				ItemDrop.spawn(planet, at, int(item["id"]), 1, item["props"],
					str(item["src"]), item["mat"], str(item["label"]), Vector3(up) * 1.0)


## Is there wood within REACH of this leaf, going only through leaves? Any wood
## counts, placed or grown: a log you set against a canopy holds it up.
func _near_wood(start: Vector3i) -> bool:
	var dist := {start: 0}
	var todo: Array[Vector3i] = [start]
	var i := 0
	while i < todo.size() and i < MAX_VISIT:
		var c: Vector3i = todo[i]
		i += 1
		var dc: int = dist[c]
		for nb in TreeFall._N6:
			var q: Vector3i = c + nb
			if dist.has(q):
				continue
			var id := Blocks.bottom_of(planet.get_id(q))
			if Blocks.is_wood(id):
				return true
			if dc + 1 < REACH and Blocks.is_leaf(id):
				dist[q] = dc + 1
				todo.append(q)
	return false
