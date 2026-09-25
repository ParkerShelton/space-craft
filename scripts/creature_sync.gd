extends Node
class_name CreatureSync

## Wildlife in a co-op game: the same animals and the same monsters for
## everybody.
##
## A creature is RUN by the machine that spawned it -- its AI, its physics,
## what it decides to do -- and every other machine keeps a copy of it, a
## puppet, that walks where it walks and plays what it plays. That keeps all
## the behaviour exactly as it is in single player, with nothing duplicated:
## the owner's copy is the creature.
##
## What crosses between machines:
##   spawn   the owner made one: build a puppet of it
##   pose    where the owner's are and what they are doing, ten times a second
##   clip    one of them started an attack, flinch or the like
##   died    one was killed: play its death
##   gone    one wandered off and was let go
##   hit     someone struck a puppet: the owner applies the blow
##   hurt    an owner's creature struck someone else's player
##   drops   the killing blow was someone else's: what the kill was worth
##
## Which machine spawns is decided by WorldManager.spawns_fauna_here: playing
## together, one machine spawns for the group.

const POSE_EVERY := 0.1

var net: Net
var world: WorldManager

var _owned := {}     # cid -> creature this machine runs
var _puppets := {}   # cid -> copy of one another machine runs
var _pose_t := 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func reset() -> void:
	_owned.clear()
	_puppets.clear()


func _live() -> bool:
	return net != null and net.active and net._world_built and world != null


static func _type_of(c: Creature) -> String:
	if c is NightSpider:
		return "spider"
	if c is Watcher:
		return "watcher"
	return "creature"


# --- this machine's creatures ---------------------------------------------------

## A creature this machine has just spawned: tell everyone.
func register(c: Creature) -> void:
	if not _live() or c.puppet:
		return
	c.net_cid = "%d-%08x" % [net.my_id(), randi()]
	_owned[c.net_cid] = c
	spawn_msg.rpc(_describe(c))


func _describe(c: Creature) -> Dictionary:
	var d := {"cid": c.net_cid, "type": _type_of(c), "planet": c.planet.planet_name,
		"xform": c.global_transform, "health": c._health}
	if c is NightSpider:
		d["daylight"] = (c as NightSpider).daylight_ok
	elif c is Watcher:
		d["daylight"] = (c as Watcher).daylight_ok
	else:
		d["species"] = c.species
	return d


func _process(delta: float) -> void:
	if not _live():
		return
	_pose_t -= delta
	if _pose_t > 0.0:
		return
	_pose_t = POSE_EVERY
	var batch: Array = []
	for cid in _owned.keys():
		var c = _owned[cid]
		if c == null or not is_instance_valid(c) or c.is_queued_for_deletion():
			_owned.erase(cid)
			gone_msg.rpc(cid)
			continue
		batch.append([cid, (c as Creature).global_transform, (c as Creature).net_state()])
	if not batch.is_empty():
		pose_msg.rpc(batch)


## One of this machine's creatures started a one-off clip (a swing, a flinch).
func clip(c: Creature, state: String) -> void:
	if _live() and _owned.has(c.net_cid):
		clip_msg.rpc(c.net_cid, state)


## One of this machine's creatures was killed.
func died(c: Creature) -> void:
	if _live() and _owned.has(c.net_cid):
		died_msg.rpc(c.net_cid)
		_owned.erase(c.net_cid)


## Someone on this machine hit a puppet: the blow goes to whoever runs it.
func hit_puppet(c: Creature, dmg: float, stagger: float) -> void:
	if _live() and c.net_cid != "":
		hit_msg.rpc_id(c.net_owner, c.net_cid, dmg, stagger)


func hurt_peer(peer: int, dmg: float, push: Vector3, status: String) -> void:
	if _live():
		hurt_msg.rpc_id(peer, dmg, push, status)


## What a kill was worth, handed to the player who made it.
func send_drops(peer: int, items: Array, label: String) -> void:
	if _live():
		drops_msg.rpc_id(peer, items, label)


# --- arriving from other machines ---------------------------------------------------

func _planet(pname: String) -> Planet:
	for p in world.planets:
		if is_instance_valid(p) and p.planet_name == pname:
			return p
	return null


@rpc("any_peer", "call_remote", "reliable")
func spawn_msg(d: Dictionary) -> void:
	if not _live():
		return
	var cid := str(d.get("cid", ""))
	if cid == "" or _puppets.has(cid):
		return
	var p := _planet(str(d.get("planet", "")))
	if p == null:
		return
	var c: Creature
	match str(d.get("type", "creature")):
		"spider":
			var s := NightSpider.new()
			s.daylight_ok = bool(d.get("daylight", false))
			s.puppet = true
			p.add_child(s)
			s.setup_spider(p, world, p.stalker_species)
			c = s
		"watcher":
			var w := Watcher.new()
			w.daylight_ok = bool(d.get("daylight", false))
			w.puppet = true
			p.add_child(w)
			w.setup_watcher(p, world)
			c = w
		_:
			c = Creature.new()
			c.puppet = true
			p.add_child(c)
			c.configure(d.get("species", {}), p, world)
	c.global_transform = d.get("xform", Transform3D.IDENTITY)
	c._health = float(d.get("health", c._health))
	c.net_cid = cid
	c.net_owner = multiplayer.get_remote_sender_id()
	c.net_pose(c.global_transform, "")
	_puppets[cid] = c


@rpc("any_peer", "call_remote", "unreliable_ordered")
func pose_msg(batch: Array) -> void:
	if not _live():
		return
	for e in batch:
		var c = _puppets.get(str(e[0]))
		if c != null and is_instance_valid(c):
			(c as Creature).net_pose(e[1], str(e[2]))


@rpc("any_peer", "call_remote", "reliable")
func clip_msg(cid: String, state: String) -> void:
	var c = _puppets.get(cid)
	if c != null and is_instance_valid(c):
		(c as Creature)._play_oneshot(state)


@rpc("any_peer", "call_remote", "reliable")
func died_msg(cid: String) -> void:
	var c = _puppets.get(cid)
	_puppets.erase(cid)
	if c != null and is_instance_valid(c):
		(c as Creature).net_die()


@rpc("any_peer", "call_remote", "reliable")
func gone_msg(cid: String) -> void:
	var c = _puppets.get(cid)
	_puppets.erase(cid)
	if c != null and is_instance_valid(c):
		c.queue_free()


@rpc("any_peer", "call_remote", "reliable")
func hit_msg(cid: String, dmg: float, stagger: float) -> void:
	var c = _owned.get(cid)
	if c == null or not is_instance_valid(c):
		return
	# The blow is the sender's: if it kills, the drops are theirs.
	(c as Creature)._last_hitter = multiplayer.get_remote_sender_id()
	(c as Creature).take_hit(dmg, stagger)
	if is_instance_valid(c):
		(c as Creature)._last_hitter = 0


@rpc("any_peer", "call_remote", "reliable")
func hurt_msg(dmg: float, push: Vector3, status: String) -> void:
	if world != null:
		world.apply_hurt(dmg, push, status)


@rpc("any_peer", "call_remote", "reliable")
func drops_msg(items: Array, label: String) -> void:
	var pl = world.player if world != null else null
	if pl == null:
		return
	var got: Array = []
	for it in items:
		pl.grant_item(int(it[0]), int(it[1]))
		got.append("%s x%d" % [Blocks.name_of(int(it[0])), int(it[1])])
	if not got.is_empty() and pl.has_method("notify"):
		pl.notify("%s: %s" % [label, ", ".join(got)])


# --- players coming and going -----------------------------------------------------

## Somebody new: show them everything this machine is running.
func _on_peer_connected(peer: int) -> void:
	if not _live():
		return
	for cid in _owned:
		var c = _owned[cid]
		if c != null and is_instance_valid(c):
			spawn_msg.rpc_id(peer, _describe(c))


## Somebody left: what they were running goes with them.
func _on_peer_disconnected(peer: int) -> void:
	for cid in _puppets.keys():
		var c = _puppets[cid]
		if c == null or not is_instance_valid(c) or (c as Creature).net_owner == peer:
			if c != null and is_instance_valid(c):
				c.queue_free()
			_puppets.erase(cid)
