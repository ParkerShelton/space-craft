extends Node
class_name NetSync

## Ships and stations, kept the same on every machine in a co-op game.
##
## Terrain travels as edits (see Net); these are whole objects with a lot of
## state -- a ship's blocks and tanks, a chest's contents, a smelter half way
## through a batch -- so they travel as SNAPSHOTS instead. Every ship and
## station has a network id. Each machine watches the ones it has, and when
## one changes it sends the whole of it through the host, which applies it and
## passes it on. Anything that appears is created on the other machines, and
## anything that goes is removed from them.
##
## Watching rather than hooking every place that changes one is the point:
## a slot dragged in a chest, a blow on an anvil, a batch coming out of the
## smelter, a plate knocked off a wreck -- all of it is caught the same way,
## including whatever is added later.
##
## The last change to reach the host wins. Two players emptying the same chest
## in the same instant can still see a stack twice; for friends at one base
## that is a fair price for never having to think about it.
##
## A ship being FLOWN is different: its pilot streams where it is many times
## a second, and every other machine leaves its physics alone and follows.

const SCAN_EVERY := 0.2      # how often every ship and station is checked for changes
const MIN_GAP := 0.4         # and the fastest any one of them is sent again
const POSE_EVERY := 0.05     # a flown ship's position, twenty times a second
const POSE_STALE := 0.6      # a pilot not heard from this long has landed or gone

var net: Net
var world: WorldManager

var _known := {}       # nid -> hash of the state last sent or received
var _alive := {}       # nid -> [node, "ship"|"station"]
var _next_ok := {}     # nid -> msec after which it may be sent again
var _pending_send := {}  # nid -> true: changed, waiting out MIN_GAP
var _queue: Array = []   # messages that arrived before the world was built
var _orphans: Array = []  # stations whose ship has not arrived yet
var _scan_t := 0.0
var _pose_t := 0.0
var _poses := {}       # nid -> {"xform", "t"}: where a ship someone else flies is
var _yours := {}       # which wreck the host said is this player's, until it is here


func _ready() -> void:
	set_process(true)


func reset() -> void:
	_known.clear()
	_alive.clear()
	_next_ok.clear()
	_pending_send.clear()
	_queue.clear()
	_orphans.clear()
	_poses.clear()


static func new_id() -> String:
	# Random rather than counted: ids are saved with the world, and a counter
	# that starts again at one next session would hand out ones already taken.
	return "%08x%04x" % [randi(), randi() % 0x10000]


func _live() -> bool:
	return net != null and net.active and net._world_built and world != null


# --- watching ---------------------------------------------------------------

func _process(delta: float) -> void:
	if not _live():
		return
	_follow_poses(delta)
	_pose_t -= delta
	if _pose_t <= 0.0:
		_pose_t = POSE_EVERY
		_send_pose()
	_scan_t -= delta
	if _scan_t > 0.0:
		return
	_scan_t = SCAN_EVERY
	_retry_orphans()
	_adopt_player()
	_scan()


func _scan() -> void:
	var now := Time.get_ticks_msec()
	var seen := {}
	for s in world._ships:
		if not is_instance_valid(s) or s.is_queued_for_deletion():
			continue
		if s.net_id == "":
			s.net_id = new_id()
		seen[s.net_id] = true
		_alive[s.net_id] = [s, "ship"]
		if s.remote_driven:
			# Someone else is flying her; what she is doing is theirs to say.
			_known[s.net_id] = ship_hash(s)
			continue
		_consider(s.net_id, ship_hash(s), now)
	for st in world._stations:
		if not is_instance_valid(st) or st.is_queued_for_deletion():
			continue
		if st.net_id == "":
			st.net_id = new_id()
		seen[st.net_id] = true
		_alive[st.net_id] = [st, "station"]
		_consider(st.net_id, station_hash(st), now)
	# Anything that was here and is not any more has been taken apart, mined
	# away or flown off the edge of the world by somebody on THIS machine.
	for nid in _alive.keys():
		if seen.has(nid):
			continue
		var what: String = _alive[nid][1]
		_alive.erase(nid)
		_known.erase(nid)
		_pending_send.erase(nid)
		_send("gone", {"nid": nid, "what": what})


func _consider(nid: String, h: int, now: int) -> void:
	if _known.get(nid, null) == h and not _pending_send.has(nid):
		return
	if now < int(_next_ok.get(nid, 0)):
		_pending_send[nid] = true
		return
	_pending_send.erase(nid)
	_known[nid] = h
	_next_ok[nid] = now + int(MIN_GAP * 1000.0)
	var e: Array = _alive[nid]
	if e[1] == "ship":
		_send("ship", ship_snap(e[0]))
	else:
		_send("station", station_snap(e[0]))


## Host: tell a player which wreck is theirs.
func tell_yours(peer: int, s: Ship, fresh: bool) -> void:
	if s.net_id == "":
		s.net_id = new_id()
	sync_msg.rpc_id(peer, "yours", {"nid": s.net_id, "fresh": fresh})


## Everything, to a player who has just arrived. Ships first: a station bolted
## to a ship needs the ship to be there.
func send_all_to(peer: int) -> void:
	if world == null:
		return
	for s in world._ships:
		if is_instance_valid(s) and not s.blocks.is_empty():
			if s.net_id == "":
				s.net_id = new_id()
			sync_msg.rpc_id(peer, "ship", ship_snap(s))
	for st in world._stations:
		if is_instance_valid(st):
			if st.net_id == "":
				st.net_id = new_id()
			sync_msg.rpc_id(peer, "station", station_snap(st))
	if not world.crash_site.is_empty():
		sync_msg.rpc_id(peer, "crash", {"site": world.crash_site})


# --- sending ------------------------------------------------------------------

func _send(kind: String, data: Dictionary) -> void:
	if net.is_host:
		sync_msg.rpc(kind, data)
	else:
		sync_msg.rpc_id(1, kind, data)


## Every change goes through here: from a client to the host, and from the host
## to everyone else.
@rpc("any_peer", "call_remote", "reliable")
func sync_msg(kind: String, data: Dictionary) -> void:
	var from := multiplayer.get_remote_sender_id()
	if not net.is_host and from != 1:
		return   # only the host speaks for the world
	if net.is_host:
		for p in multiplayer.get_peers():
			if p != from:
				sync_msg.rpc_id(p, kind, data)
	if not net._world_built or world == null:
		_queue.append([kind, data])
		return
	_apply(kind, data)


## Called once the world exists: everything that arrived before it.
func flush() -> void:
	var q := _queue.duplicate()
	_queue.clear()
	for m in q:
		_apply(m[0], m[1])


func _apply(kind: String, data: Dictionary) -> void:
	match kind:
		"ship":
			apply_ship(data)
		"station":
			apply_station(data)
		"gone":
			_apply_gone(data)
		"crash":
			_apply_crash(data)
		"yours":
			_yours = data


# --- ships --------------------------------------------------------------------

static func ship_hash(s: Ship) -> int:
	# Not her position, her tanks or her engines: those move all the time, and
	# travel with the pilot's stream or with the next real change.
	return hash([s.blocks, s.block_meta, s.wreck_missing, s.ship_log.size(),
		s.cabin_cells, s.seat_at, s.landed, s.flying, s.has_flown])


## The same fingerprint as ship_hash, taken from a snapshot rather than a ship.
static func _snap_hash(d: Dictionary) -> int:
	return hash([d.get("blocks", {}), d.get("meta", {}), d.get("wreck", {}),
		(d.get("log", []) as Array).size(), d.get("cabin", []), d.get("seat", Vector3.ZERO),
		bool(d.get("landed", true)), bool(d.get("flying", false)), bool(d.get("flown", false))])


static func ship_snap(s: Ship) -> Dictionary:
	return {"nid": s.net_id, "blocks": s.blocks, "meta": s.block_meta,
		"xform": s.global_transform, "air": s.air, "charge": s.charge,
		"wreck": s.wreck_missing, "log": s.ship_log, "cabin": s.cabin_cells,
		"seat": s.seat_at, "landed": s.landed, "flown": s.has_flown,
		"flying": s.flying, "crash": s.crash_wreck, "owner": s.owner_uid}


func find_ship(nid: String) -> Ship:
	for s in world._ships:
		if is_instance_valid(s) and s.net_id == nid:
			return s
	return null


func apply_ship(d: Dictionary) -> void:
	var nid := str(d.get("nid", ""))
	if nid == "":
		return
	var blocks: Dictionary = d.get("blocks", {})
	var s := find_ship(nid)
	if blocks.is_empty():
		if s != null:
			_remove(s, nid)
		return
	var fresh := s == null
	if not fresh:
		s.crash_wreck = bool(d.get("crash", s.crash_wreck))
		s.owner_uid = str(d.get("owner", s.owner_uid))
	if not fresh and _snap_hash(d) == ship_hash(s):
		# Nothing about her has changed but her tanks: no rebuild for that.
		s.air = float(d.get("air", s.air))
		s.charge = float(d.get("charge", s.charge))
		_known[nid] = ship_hash(s)
		return
	if fresh:
		s = Ship.new()
		s.world = world
		s.net_id = nid
		world.add_child(s)
		world._ships.append(s)
	var pl = world.player
	var mine: bool = pl != null and pl.piloting == s
	var old_seat := s.seat_at
	var old_cabin := s.cabin_cells
	s.blocks = blocks.duplicate(true)
	s.block_meta = (d.get("meta", {}) as Dictionary).duplicate(true)
	s.wreck_missing = (d.get("wreck", {}) as Dictionary).duplicate(true)
	s.ship_log = (d.get("log", []) as Array).duplicate(true)
	s.cabin_cells = (d.get("cabin", []) as Array).duplicate(true)
	s.seat_at = d.get("seat", Vector3.ZERO)
	s.has_flown = bool(d.get("flown", false))
	s.crash_wreck = bool(d.get("crash", false))
	s.owner_uid = str(d.get("owner", ""))
	s.air = float(d.get("air", s.air))
	s.charge = float(d.get("charge", s.charge))
	if not mine:
		s.landed = bool(d.get("landed", true))
		s.flying = bool(d.get("flying", false))
		if not s.flying:
			s.remote_driven = false
			_poses.erase(nid)
			s.velocity = Vector3.ZERO
			s.global_transform = d.get("xform", s.global_transform)
		elif fresh:
			s.global_transform = d.get("xform", s.global_transform)
	s.rebuild()
	if fresh or old_seat != s.seat_at or old_cabin != s.cabin_cells:
		s.build_props()
	if fresh:
		var wk := ShipWake.new()
		s.add_child(wk)
		wk.setup(s, world.player, world)
	_give_ghosts(s)
	_alive[nid] = [s, "ship"]
	_known[nid] = ship_hash(s)


## A wreck shows the player on THIS machine what she is missing, too.
func _give_ghosts(s: Ship) -> void:
	if s.wreck_missing.is_empty() or world.player == null:
		return
	for c in s.get_children():
		if c is RepairGhosts:
			return
	var g := RepairGhosts.new()
	s.add_child(g)
	g.setup(s, world.player)


## Ships that arrived before this machine's player existed -- everything a
## joining player is sent does -- get it now.
func _adopt_player() -> void:
	if world.player == null:
		return
	# Our own wreck, once both it and we are here.
	if not _yours.is_empty():
		var mine := find_ship(str(_yours.get("nid", "")))
		if mine != null:
			var fresh := bool(_yours.get("fresh", false))
			_yours = {}
			var p := world.nearest_planet(mine.global_position)
			if p != null:
				world.crash_site = {"planet": p.planet_name,
					"local": p.to_local(mine.global_position), "shown": false}
			world.own_wreck.emit(mine, fresh)
	for s in world._ships:
		if not is_instance_valid(s):
			continue
		for c in s.get_children():
			if c is ShipWake and c._player == null:
				c._player = world.player
		_give_ghosts(s)


## The ship this machine's player is flying, told to everyone else.
func _send_pose() -> void:
	var pl = world.player
	if pl == null:
		return
	var s = pl.piloting
	if s == null or not is_instance_valid(s):
		return
	if s.net_id == "":
		return   # not announced yet; the next scan does that
	var pose := [s.net_id, s.global_transform, s.flying, s.landed, s.engine_glow,
		s.air, s.charge]
	if net.is_host:
		ship_pose.rpc(pose)
	else:
		ship_pose.rpc_id(1, pose)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func ship_pose(pose: Array) -> void:
	var from := multiplayer.get_remote_sender_id()
	if not net.is_host and from != 1:
		return
	if net.is_host:
		for p in multiplayer.get_peers():
			if p != from:
				ship_pose.rpc_id(p, pose)
	if not _live() or pose.size() < 7:
		return
	var s := find_ship(str(pose[0]))
	var pl = world.player
	if s == null or (pl != null and pl.piloting == s):
		return
	s.remote_driven = true
	s.flying = bool(pose[2])
	s.landed = bool(pose[3])
	s.engine_glow = float(pose[4])
	s.air = float(pose[5])
	s.charge = float(pose[6])
	_poses[s.net_id] = {"xform": pose[1], "t": Time.get_ticks_msec()}


## Glide every ship someone else is flying towards where they last said it was.
func _follow_poses(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for nid in _poses.keys():
		var s := find_ship(nid)
		if s == null:
			_poses.erase(nid)
			continue
		var p: Dictionary = _poses[nid]
		var to: Transform3D = p["xform"]
		var k := clampf(delta * 14.0, 0.0, 1.0)
		var cur := s.global_transform
		s.global_transform = Transform3D(cur.basis.slerp(to.basis, k).orthonormalized(),
			cur.origin.lerp(to.origin, k))
		if now - int(p["t"]) > int(POSE_STALE * 1000.0):
			# The pilot has stopped talking: put her where they last had her and
			# let her be an ordinary parked ship again until told otherwise.
			s.global_transform = to
			s.remote_driven = false
			_poses.erase(nid)


# --- stations -----------------------------------------------------------------

static func station_hash(st: Station) -> int:
	var par := st.get_parent()
	return hash([st.kind, st.storage, st.switched_on, st._job, st._job_craft,
		st._job_times, (par as Ship).net_id if par is Ship else ""])


static func station_snap(st: Station) -> Dictionary:
	var d := {"nid": st.net_id, "kind": st.kind, "storage": st.storage,
		"on": st.switched_on, "power": st.power, "burn": [st.burn_t, st.burn_rate],
		"job": [st._job, st._job_t, st._job_total, st._job_craft, st._job_times]}
	var par := st.get_parent()
	if par is Ship:
		d["ship"] = (par as Ship).net_id
		d["local"] = st.transform
	else:
		d["xform"] = st.global_transform
	return d


func find_station(nid: String) -> Station:
	for st in world._stations:
		if is_instance_valid(st) and st.net_id == nid:
			return st
	return null


func apply_station(d: Dictionary) -> void:
	var nid := str(d.get("nid", ""))
	if nid == "":
		return
	var st := find_station(nid)
	if st == null:
		var ship: Ship = null
		if d.has("ship"):
			ship = find_ship(str(d["ship"]))
			if ship == null:
				_orphans.append(d)   # its ship is still on the way
				return
		st = Station.new()
		st.net_id = nid
		var k := int(d.get("kind", Blocks.SMELTER))
		if ship != null:
			ship.add_child(st)
			st.configure(k, world)
			st.transform = d.get("local", Transform3D.IDENTITY)
			ship.add_collision_exception_with(st)
		else:
			world.add_child(st)
			st.configure(k, world)
			st.global_transform = d.get("xform", Transform3D.IDENTITY)
		world._stations.append(st)
	# Filled in place, not swapped for a new array: an open chest window is
	# looking at this one.
	st.storage.assign((d.get("storage", []) as Array).duplicate(true))
	if st.kind == Blocks.GENERATOR:
		if st.switched_on != bool(d.get("on", true)):
			st.set_switched(bool(d.get("on", true)))
		st.power = float(d.get("power", st.power))
		var burn: Array = d.get("burn", [st.burn_t, st.burn_rate])
		st.burn_t = float(burn[0])
		st.burn_rate = float(burn[1])
	var job: Array = d.get("job", ["", 0.0, 0.0, {}, 1])
	st._job = str(job[0])
	st._job_t = float(job[1])
	st._job_total = float(job[2])
	st._job_craft = (job[3] as Dictionary).duplicate(true)
	st._job_times = int(job[4])
	st.net_refresh()
	_alive[nid] = [st, "station"]
	_known[nid] = station_hash(st)
	var pl = world.player
	if pl != null and pl._station_open == st:
		pl._refresh_station_ui()


func _retry_orphans() -> void:
	if _orphans.is_empty():
		return
	var waiting := _orphans.duplicate()
	_orphans.clear()
	for d in waiting:
		apply_station(d)


# --- going away ---------------------------------------------------------------

func _apply_gone(d: Dictionary) -> void:
	var nid := str(d.get("nid", ""))
	if str(d.get("what", "")) == "ship":
		var s := find_ship(nid)
		if s != null:
			_remove(s, nid)
	else:
		var st := find_station(nid)
		if st != null:
			var pl = world.player
			if pl != null and pl._station_open == st:
				pl._close_station()
			_remove(st, nid)


func _remove(n: Node, nid: String) -> void:
	# Forgotten BEFORE it goes, so the next scan does not read its absence as
	# something this machine did and announce it all over again.
	_alive.erase(nid)
	_known.erase(nid)
	_poses.erase(nid)
	if n is Ship:
		world._ships.erase(n)
	elif n is Station:
		world._stations.erase(n)
	n.queue_free()


# --- where the game began -------------------------------------------------------

func _apply_crash(d: Dictionary) -> void:
	var site: Dictionary = d.get("site", {})
	if site.is_empty():
		return
	world.crash_site = site.duplicate(true)
	world.crash_site_arrived()
