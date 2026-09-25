extends Node
class_name Net

## Networking for co-op play.
##
## The whole design rests on one property of this game: TERRAIN IS A PURE
## FUNCTION OF THE SEED. Planet.generation_sample() derives every block from
## world_seed, and the only other world state is a sparse dictionary of player
## edits per chunk. So a client never receives chunk data -- it generates
## identical terrain locally from the seed it is told on joining, and after that
## only the EDITS have to travel. That removes the expensive half of voxel
## networking before it starts.
##
## One player hosts and plays (a listen server). The host owns the world: it
## decides the seed, and every block edit is broadcast from it.

const PORT := 24565
## Games shout on this port so machines on the same network can find each other
## without anybody typing an address. One small packet a second and a half.
const BEACON_PORT := 24566
const BEACON_EVERY := 1.5
const BEACON_FORGET := 5.0   # a game unheard from this long has gone

var _beacon: PacketPeerUDP
var _beacon_t := 0.0
var _beacon_name := ""
var _browser: PacketPeerUDP
## Games heard on this network: address -> {name, players, when}.
var found_games: Dictionary = {}


## Start telling the network this game is here.
func start_beacon(game_name: String) -> void:
	_beacon_name = game_name
	if _beacon != null:
		return
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", BEACON_PORT)
	_beacon_t = 0.0


func stop_beacon() -> void:
	if _beacon != null:
		_beacon.close()
		_beacon = null


## Start listening for games on this network.
func start_browse() -> void:
	if _browser != null:
		return
	_browser = PacketPeerUDP.new()
	_browser.set_broadcast_enabled(true)
	if _browser.bind(BEACON_PORT) != OK:
		_browser = null


func stop_browse() -> void:
	if _browser != null:
		_browser.close()
		_browser = null
	found_games.clear()


func _process(delta: float) -> void:
	if _beacon != null:
		_beacon_t -= delta
		if _beacon_t <= 0.0:
			_beacon_t = BEACON_EVERY
			_beacon.put_packet(JSON.stringify({
				"game": "spacecraft", "name": _beacon_name,
				"players": peers.size() + 1, "port": PORT}).to_utf8_buffer())
	if _browser != null:
		while _browser.get_available_packet_count() > 0:
			var from := _browser.get_packet_ip()
			var got = JSON.parse_string(_browser.get_packet().get_string_from_utf8())
			# Our own broadcast comes back to us with no address on some
			# machines; there is nothing to join at "".
			if from.is_empty():
				continue
			if got is Dictionary and str((got as Dictionary).get("game", "")) == "spacecraft":
				found_games[from] = {"name": str((got as Dictionary).get("name", "Game")),
					"players": int((got as Dictionary).get("players", 1)),
					"when": Time.get_ticks_msec()}
		# Anything that has stopped shouting has stopped being there.
		for ip in found_games.keys():
			if Time.get_ticks_msec() - int(found_games[ip]["when"]) > int(BEACON_FORGET * 1000.0):
				found_games.erase(ip)
const MAX_PLAYERS := 8

signal world_ready(seed_value: int, system_index: int, phases: PackedFloat32Array)
signal roster_changed()
## The host recognised us and sent back what we were carrying last time.
signal profile_restored(profile: Dictionary)
## One line of chat, already formatted and ready to show.
signal chat_received(line: String)

## Where this installation's identity lives. A peer id is issued fresh on every
## connection, so it cannot be what the server remembers a player by -- it would
## hand you a stranger's backpack as often as your own. This is a random id
## written once and kept, which is also why it is not a name: two friends both
## called "Steve" must not share an inventory.
const UID_PATH := "user://player_uid.txt"

var active := false          ## networking is up at all
var is_host := false
var joining := false         ## client, connected, still waiting for the seed
var last_error := ""

## peer id -> {"pos": Vector3, "yaw": float, "name": String}
var peers: Dictionary = {}

## uid -> that player's last known inventory. Host side only, and saved with the
## world, so a server restart gives everyone their things back as well as their
## buildings.
var profiles: Dictionary = {}
## This machine's identity, sent to the host on joining.
var uid := ""
## Where the host writes chat to. Empty on a client, and on a host that is not
## keeping a log.
var chat_log_path := ""
## Longest message accepted. Anything longer is cut rather than refused -- the
## point is that one player cannot flood everyone else's screen with a single
## line, not to police what people type.
const CHAT_MAX := 240

var _world: WorldManager
## Ships and stations (see net_sync.gd).
var sync: NetSync
var _seed := 0
var _system := 0
## Edits that arrived before this client had finished building its world. A
## joining client is sent the world's changes immediately, but generating the
## planets takes tens of seconds -- so anything landing in that window has
## nowhere to go yet and would simply be lost.
var _pending: Array = []
var _world_built := false


func _ready() -> void:
	uid = _local_uid()
	sync = NetSync.new()
	sync.name = "Sync"
	sync.net = self
	add_child(sync)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)


## Read this installation's id, making one the first time. Any failure falls back
## to a throwaway id rather than refusing to play: the cost is starting empty on
## a server, which is exactly what happened before any of this existed.
func _local_uid() -> String:
	if FileAccess.file_exists(UID_PATH):
		var f := FileAccess.open(UID_PATH, FileAccess.READ)
		if f != null:
			var got := f.get_as_text().strip_edges()
			f.close()
			if got != "":
				return got
	var r := RandomNumberGenerator.new()
	r.randomize()
	var made := "%08x%08x" % [r.randi(), r.randi()]
	var w := FileAccess.open(UID_PATH, FileAccess.WRITE)
	if w != null:
		w.store_string(made)
		w.close()
	return made


func bind_world(w: WorldManager) -> void:
	_world = w
	sync.world = w


# --- starting a session ---------------------------------------------------

## Host on this machine. The caller has already decided the seed, because the
## host generates its world exactly as a single-player game does.
func host(seed_value: int, system_index: int, port: int = PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		# Almost always a server that is still running. The engine reports a bare
		# ERR_CANT_CREATE for this, which tells whoever is starting it nothing.
		if err == ERR_CANT_CREATE or err == ERR_ALREADY_IN_USE:
			last_error = ("Port %d is already in use. Another server is probably "
				+ "still running -- close it, or start this one with --port=%d.") % [port, port + 1]
		else:
			last_error = "Could not open port %d (error %d)" % [port, err]
		return false
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = true
	_seed = seed_value
	_system = system_index
	return true


func join(address: String, port: int = PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		last_error = "Could not reach %s:%d (error %d)" % [address, port, err]
		return false
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = false
	joining = true
	return true


func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	active = false
	is_host = false
	joining = false
	peers.clear()
	sync.reset()


## Called once the planets actually exist. Everything that arrived while this
## client was still generating them is applied now, in the order it came in.
func world_built() -> void:
	_world_built = true
	for e in _pending:
		match e[0]:
			"parts":
				_apply_parts_bulk(e[1], e[2], e[3])
			"part1":
				var p := _planet(e[1])
				if p != null:
					_apply_part(p, e[2], e[3], e[4])
			"plant":
				var pp := _planet(e[1])
				if pp != null:
					pp.plant(e[2], str(e[3][0]), bool(e[3][1]))
			"harvest":
				var ph := _planet(e[1])
				if ph != null:
					ph.harvest(e[2])
					ph.clear_crop(e[2])
			"stages":
				var ps := _planet(e[1])
				if ps != null:
					for c in e[2]:
						ps.set_crop_stage(c[0], int(c[1]))
			"crops":
				var pc := _planet(e[1])
				if pc != null:
					pc.load_crops(e[2])
			"water":
				var pw := _planet(e[1])
				if pw != null:
					pw.apply_water(e[2])
			"allwater":
				var pw2 := _planet(e[1])
				if pw2 != null:
					pw2.load_water(e[2])
					pw2.apply_water(e[2])
			"tags":
				_apply_tags(e[1], e[2])
			_:
				_apply_bulk(e[1], e[2], e[3])
	_pending.clear()
	sync.flush()


func my_id() -> int:
	return multiplayer.get_unique_id() if active else 1


# --- connection plumbing --------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_host:
		return
	peers[id] = {"pos": Vector3.ZERO, "yaw": 0.0}
	roster_changed.emit()
	_post("* %s joined" % player_label(id))
	# Hand the newcomer the world it has to build. Nothing else can happen until
	# it has this: its terrain would not match ours.
	world_info.rpc_id(id, _seed, _system, _day_phases())
	# ...who everyone here is, so the newcomer does not spend the session
	# looking at a field of default characters.
	_send_skins_to(id)
	_send_looks_to(id)
	# ...and everything that has been built or dug since the world was made.
	# Without this a late joiner sees the world as it was GENERATED: it would
	# generate the same terrain from the seed and then be missing every change
	# anyone had made, which on a server that has been up for a while is most of
	# what there is to see.
	for p in _world.planets if _world != null else []:
		var cells := PackedVector3Array()
		var ids := PackedInt32Array()
		for cc in p._edits_by_chunk:
			for v in p._edits_by_chunk[cc]:
				cells.append(Vector3(v))
				ids.append(int(p._edits_by_chunk[cc][v]))
		if not ids.is_empty():
			world_edits.rpc_id(id, p.planet_name, cells, ids)
		# ...and what each placed block was made from, after the blocks
		# themselves (placing a block clears whatever tag the cell had).
		if not p.block_tags.is_empty():
			world_tags.rpc_id(id, p.planet_name, p.block_tags)
		# Eighth-block builds live in their own store, not in _edits_by_chunk, so
		# they need their own pass -- otherwise a newcomer sees PARTS markers with
		# nothing in them where somebody's fine detail work should be.
		var pcells := PackedVector3Array()
		var pdata := PackedByteArray()
		for cc in p._parts_by_chunk:
			for v in p._parts_by_chunk[cc]:
				pcells.append(Vector3(v))
				pdata.append_array(p._parts_by_chunk[cc][v])
		if not pcells.is_empty():
			world_parts.rpc_id(id, p.planet_name, pcells, pdata)
		var crows: Array = p.crops_snapshot()
		if not crows.is_empty():
			world_crops.rpc_id(id, p.planet_name, crows)
		# Water that has moved. The blocks themselves already went out with the
		# edits above; what is missing without this is how deep each one is.
		var wrows: Array = p.water_rows()
		if not wrows.is_empty():
			world_water.rpc_id(id, p.planet_name, wrows)
	# ...and every ship and station, with what is in them.
	sync.send_all_to(id)


func _on_peer_disconnected(id: int) -> void:
	peers.erase(id)
	roster_changed.emit()
	if is_host:
		_post("* %s left" % player_label(id))


func _on_connected() -> void:
	pass   # nothing to do until the host sends the seed


func _on_connect_failed() -> void:
	last_error = "The host did not answer."
	active = false
	joining = false


func _on_server_gone() -> void:
	last_error = "Lost the host."
	active = false
	joining = false
	peers.clear()


# --- world handshake ------------------------------------------------------

## Time of day on each planet, in planet order. Both machines generate the same
## planets from the same seed, so the order is enough to say which is which.
##
## Without this a newcomer starts the world's day over from wherever the seed put
## it, and stands in the morning sun arguing with somebody who is watching the
## sun set. The clocks then run at the same rate on both, so one exchange at the
## door is enough.
func _day_phases() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if _world != null:
		for p in _world.planets:
			out.append(p.day_phase)
	return out


@rpc("authority", "call_remote", "reliable")
func world_info(seed_value: int, system_index: int, phases: PackedFloat32Array) -> void:
	_seed = seed_value
	_system = system_index
	joining = false
	world_ready.emit(seed_value, system_index, phases)


## Host -> a joining client: every edit made to one planet so far.
##
## Sent as two flat arrays rather than the nested dictionary the planet keeps,
## because packed arrays go over the wire far more compactly than a Dictionary of
## Dictionaries keyed by vectors.
@rpc("authority", "call_remote", "reliable")
func world_edits(planet_name: String, cells: PackedVector3Array, ids: PackedInt32Array) -> void:
	if not _world_built:
		_pending.append(["blocks", planet_name, cells, ids])
		return
	_apply_bulk(planet_name, cells, ids)


## Host -> a joining client: what every placed block on one planet is made of.
@rpc("authority", "call_remote", "reliable")
func world_tags(planet_name: String, tags: Dictionary) -> void:
	if not _world_built:
		_pending.append(["tags", planet_name, tags])
		return
	_apply_tags(planet_name, tags)


func _apply_tags(planet_name: String, tags: Dictionary) -> void:
	var p := _planet(planet_name)
	if p == null:
		return
	for v in tags:
		p.block_tags[v] = (tags[v] as Dictionary).duplicate(true)


func _apply_bulk(planet_name: String, cells: PackedVector3Array, ids: PackedInt32Array) -> void:
	var p := _planet(planet_name)
	if p == null:
		return
	for i in mini(cells.size(), ids.size()):
		var c: Vector3 = cells[i]
		# Quiet: this is a backlog being replayed, not a hundred players
		# mining at once.
		p.set_block(Vector3i(roundi(c.x), roundi(c.y), roundi(c.z)), ids[i], true)
	print("[net] caught up on %d changes to %s" % [ids.size(), planet_name])


## Host -> a joining client: every eighth-block cell on one planet.
##
## Eight bytes per cell, flat, matching the PackedByteArray the planet already
## keeps -- a part id is a byte there, so this is the storage format going over
## the wire unchanged rather than a conversion.
@rpc("authority", "call_remote", "reliable")
func world_parts(planet_name: String, cells: PackedVector3Array, data: PackedByteArray) -> void:
	if not _world_built:
		_pending.append(["parts", planet_name, cells, data])
		return
	_apply_parts_bulk(planet_name, cells, data)


func _apply_parts_bulk(planet_name: String, cells: PackedVector3Array,
		data: PackedByteArray) -> void:
	var p := _planet(planet_name)
	if p == null:
		return
	var n: int = Blocks.PART_COUNT
	var count: int = mini(cells.size(), data.size() / n)
	for i in count:
		var c: Vector3 = cells[i]
		var v := Vector3i(roundi(c.x), roundi(c.y), roundi(c.z))
		for sub in n:
			var id: int = int(data[i * n + sub])
			if id != Blocks.AIR:
				p.set_part(v, sub, id)
	print("[net] caught up on %d part cells on %s" % [count, planet_name])


# --- block edits ----------------------------------------------------------

## Called by whoever is editing. On the host this applies and tells everyone; on
## a client it applies locally straight away (so building feels instant) and
## asks the host to make it real for everyone else.
func edit_block(planet_name: String, v: Vector3i, id: int, tag: Dictionary = {}) -> void:
	var p := _planet(planet_name)
	if p != null:
		p.set_block_tagged(v, id, tag)
	if not active:
		return
	# The tag travels with the block: a hull plate somebody else put down is
	# the same plate, with the same ore in it, on every machine.
	if is_host:
		apply_edit.rpc(planet_name, v, id, tag)
	else:
		request_edit.rpc_id(1, planet_name, v, id, tag)


## The eighth-block twin of edit_block. Parts cannot ride on the block path:
## set_part writes a byte into a separate per-cell array and only THEN marks the
## voxel as PARTS, so replicating the block id alone hands the other player a
## marker with nothing inside it.
func edit_part(planet_name: String, v: Vector3i, sub: int, id: int) -> void:
	var p := _planet(planet_name)
	if p != null:
		_apply_part(p, v, sub, id)
	if not active:
		return
	if is_host:
		apply_part.rpc(planet_name, v, sub, id)
	else:
		request_part.rpc_id(1, planet_name, v, sub, id)


## AIR means "take this eighth away", and the planet turns the cell back to air
## once the last one is gone -- so one message covers both building and mining.
func _apply_part(p: Planet, v: Vector3i, sub: int, id: int) -> void:
	if id == Blocks.AIR:
		p.clear_part(v, sub)
	else:
		p.set_part(v, sub, id)


@rpc("any_peer", "call_remote", "reliable")
func request_part(planet_name: String, v: Vector3i, sub: int, id: int) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p != null:
		_apply_part(p, v, sub, id)
	apply_part.rpc(planet_name, v, sub, id)


@rpc("authority", "call_remote", "reliable")
func apply_part(planet_name: String, v: Vector3i, sub: int, id: int) -> void:
	if not _world_built:
		# Queued whole, not folded into a bulk array: a bulk payload cannot express
		# "this eighth was REMOVED" -- it treats an AIR byte as an empty slot to
		# skip -- so a removal arriving mid-load would leave a part behind forever.
		_pending.append(["part1", planet_name, v, sub, id])
		return
	var p := _planet(planet_name)
	if p != null:
		_apply_part(p, v, sub, id)


# --- planted things --------------------------------------------------------
#
# Growth is the HOST's to run. Every machine ticking its own clock would have
# the same field at a different height on every screen, and a crop that is ripe
# for one player and not for another is a race over who gets to pull it. So a
# client sows and reaps by asking, and hears back what happened.

func planted(planet_name: String, v: Vector3i, key: String, tree: bool) -> void:
	if not active:
		return
	if is_host:
		apply_plant.rpc(planet_name, v, key, tree)
	else:
		request_plant.rpc_id(1, planet_name, v, key, tree)


@rpc("any_peer", "call_remote", "reliable")
func request_plant(planet_name: String, v: Vector3i, key: String, tree: bool) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p != null:
		p.plant(v, key, tree)
	apply_plant.rpc(planet_name, v, key, tree)


@rpc("authority", "call_remote", "reliable")
func apply_plant(planet_name: String, v: Vector3i, key: String, tree: bool) -> void:
	if not _world_built:
		_pending.append(["plant", planet_name, v, [key, tree]])
		return
	var p := _planet(planet_name)
	if p != null:
		p.plant(v, key, tree)


func harvested(planet_name: String, v: Vector3i) -> void:
	if not active:
		return
	if is_host:
		apply_harvest.rpc(planet_name, v)
	else:
		request_harvest.rpc_id(1, planet_name, v)


@rpc("any_peer", "call_remote", "reliable")
func request_harvest(planet_name: String, v: Vector3i) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p != null:
		p.harvest(v)
	apply_harvest.rpc(planet_name, v)


@rpc("authority", "call_remote", "reliable")
func apply_harvest(planet_name: String, v: Vector3i) -> void:
	if not _world_built:
		_pending.append(["harvest", planet_name, v, null])
		return
	var p := _planet(planet_name)
	if p != null:
		p.harvest(v)
		p.clear_crop(v)


## Bone meal. The one place a crop changes by a RELATIVE amount, which is
## exactly what must not be sent as one: whoever asked has already applied it,
## and would apply the broadcast on top. So the answer is the stage it ended on,
## and setting a stage twice is setting it once. It also rides the existing
## crop_stages RPC rather than needing an apply of its own.
func fed(planet_name: String, v: Vector3i, stage: int) -> void:
	if not active:
		return
	if is_host:
		crop_stages.rpc(planet_name, [[v, stage]])
	else:
		request_feed.rpc_id(1, planet_name, v)


@rpc("any_peer", "call_remote", "reliable")
func request_feed(planet_name: String, v: Vector3i) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p == null:
		return
	# The host works out the stage from ITS OWN state, so a client that was
	# behind or ahead is corrected by the same message that confirms it.
	var stage := p.advance_crop(v)
	if stage == Planet.FEED_NOTHING:
		return
	crop_stages.rpc(planet_name, [[v, stage]])


# --- sleeping ---------------------------------------------------------------
#
# Any one player may end the night for everybody. Requiring all of them in bed
# is the version of this rule that gets a co-op session stuck waiting for
# whoever wandered off, and with two people that is most of the time.
#
# The phase is sent as an absolute value for the same reason a fed crop is: the
# player who asked has already applied it so their own night ends instantly, and
# they hear their request come back. Setting a clock to morning twice is setting
# it once.
func slept(planet_name: String, phase: float) -> void:
	if not active:
		return
	if is_host:
		apply_phase.rpc(planet_name, phase)
	else:
		request_sleep.rpc_id(1, planet_name)


@rpc("any_peer", "call_remote", "reliable")
func request_sleep(planet_name: String, phase: float = Planet.MORNING_PHASE) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p == null:
		return
	p.day_phase = phase
	apply_phase.rpc(planet_name, phase)


@rpc("authority", "call_remote", "reliable")
func apply_phase(planet_name: String, phase: float) -> void:
	var p := _planet(planet_name)
	if p != null:
		p.day_phase = phase


## Host -> everyone: crops that moved a stage this tick, batched.
func crops_grew(planet_name: String, changes: Array) -> void:
	if active and is_host and not changes.is_empty():
		crop_stages.rpc(planet_name, changes)


@rpc("authority", "call_remote", "reliable")
func crop_stages(planet_name: String, changes: Array) -> void:
	if not _world_built:
		_pending.append(["stages", planet_name, changes, null])
		return
	var p := _planet(planet_name)
	if p == null:
		return
	for c in changes:
		p.set_crop_stage(c[0], int(c[1]))


func water_moved(planet_name: String, rows: Array) -> void:
	if active and is_host and not rows.is_empty():
		water_levels.rpc(planet_name, rows)


@rpc("authority", "call_remote", "reliable")
func water_levels(planet_name: String, rows: Array) -> void:
	if not _world_built:
		_pending.append(["water", planet_name, rows, null])
		return
	var p := _planet(planet_name)
	if p != null:
		p.apply_water(rows)


## Host -> a joining client: every puddle that is not simply the seed's ocean.
@rpc("authority", "call_remote", "reliable")
func world_water(planet_name: String, rows: Array) -> void:
	if not _world_built:
		_pending.append(["allwater", planet_name, rows, null])
		return
	var p := _planet(planet_name)
	if p != null:
		p.load_water(rows)
		p.apply_water(rows)


## Host -> a joining client: the whole field, however far along it is.
@rpc("authority", "call_remote", "reliable")
func world_crops(planet_name: String, rows: Array) -> void:
	if not _world_built:
		_pending.append(["crops", planet_name, rows, null])
		return
	var p := _planet(planet_name)
	if p != null:
		p.load_crops(rows)


## Client -> host. The host is the only authority on what the world contains.
@rpc("any_peer", "call_remote", "reliable")
func request_edit(planet_name: String, v: Vector3i, id: int, tag: Dictionary) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p != null:
		p.set_block_tagged(v, id, tag)
	# Back out to everyone INCLUDING the requester's neighbours; the requester
	# already applied it locally.
	apply_edit.rpc(planet_name, v, id, tag)


## Host -> clients.
@rpc("authority", "call_remote", "reliable")
func apply_edit(planet_name: String, v: Vector3i, id: int, tag: Dictionary) -> void:
	if not _world_built:
		_pending.append(["blocks", planet_name,
			PackedVector3Array([Vector3(v)]), PackedInt32Array([id])])
		if not tag.is_empty():
			_pending.append(["tags", planet_name, {v: tag}])
		return
	var p := _planet(planet_name)
	if p != null:
		p.set_block_tagged(v, id, tag)


# --- felled trees ------------------------------------------------------------
#
# A falling tree is up to a thousand blocks changing. Sending each of them is a
# long burst of messages -- and the other players would see blocks blink out and
# back in with no tree ever falling. Instead the cut and the direction go out,
# and every machine plays the fall itself: which logs, where it stops and where
# each lands depend only on the world, which everyone already shares. See
# TreeFall.start.

func felled(planet_name: String, cut: Vector3i, fall: Vector3i) -> void:
	if not active:
		return
	if is_host:
		apply_fell.rpc(planet_name, cut, fall, my_id())
	else:
		request_fell.rpc_id(1, planet_name, cut, fall)


@rpc("any_peer", "call_remote", "reliable")
func request_fell(planet_name: String, cut: Vector3i, fall: Vector3i) -> void:
	if not is_host:
		return
	var by := multiplayer.get_remote_sender_id()
	_run_fell(planet_name, cut, fall)
	apply_fell.rpc(planet_name, cut, fall, by)


## Host -> everyone. `by` already has it falling: it started the moment they
## cut it, which is what makes it feel immediate for the one holding the axe.
@rpc("authority", "call_remote", "reliable")
func apply_fell(planet_name: String, cut: Vector3i, fall: Vector3i, by: int) -> void:
	if by == my_id() or not _world_built:
		return
	_run_fell(planet_name, cut, fall)


func _run_fell(planet_name: String, cut: Vector3i, fall: Vector3i) -> void:
	var p := _planet(planet_name)
	if p != null and _world != null:
		TreeFall.start(p, _world, _world.player, cut, fall, false)


func _planet(planet_name: String) -> Planet:
	if _world == null:
		return null
	for p in _world.planets:
		if p.planet_name == planet_name:
			return p
	return null


# --- where everyone is ----------------------------------------------------

## Sent often and unreliably: a dropped position update is replaced by the next
## one a moment later, and waiting for a resend would be worse than the gap.
##
## FACING is sent as a direction, not as a yaw angle. A player's yaw is measured
## against the surface it happens to be standing on, so the same number means a
## different direction on the far side of a planet -- reconstructing it elsewhere
## produced a skewed body that leaned over.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func player_state(pos: Vector3, facing: Vector3, action: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not peers.has(id):
		peers[id] = {}
		roster_changed.emit()
	peers[id]["pos"] = pos
	peers[id]["facing"] = facing
	peers[id]["action"] = action


# --- who you are, and what you were carrying --------------------------------

## Client -> host, once the client's world is up: "this is me." The host answers
## with whatever this player last had, if it has seen them before.
func say_hello() -> void:
	if active and not is_host:
		hello.rpc_id(1, uid)


@rpc("any_peer", "call_remote", "reliable")
func hello(player_uid: String) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if not peers.has(id):
		peers[id] = {}
	peers[id]["uid"] = player_uid
	# ALWAYS answered, even with nothing, because the answer is also the client's
	# permission to start pushing. Staying silent for an unknown player let the
	# client's first push land before the reply did, overwriting the very
	# inventory the host was about to send back.
	restore_profile.rpc_id(id, profiles.get(player_uid, {}))


@rpc("authority", "call_remote", "reliable")
func restore_profile(prof: Dictionary) -> void:
	profile_restored.emit(prof)


## Client -> host, whenever what it is carrying changes. Pushed rather than
## asked for on disconnect, because a player who crashes or pulls the plug is
## never around to answer a question -- this way the host is at worst a few
## seconds behind, instead of holding nothing at all.
func push_profile(prof: Dictionary) -> void:
	if active and not is_host:
		store_profile.rpc_id(1, prof)


@rpc("any_peer", "call_remote", "reliable")
func store_profile(prof: Dictionary) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	var u := str(peers.get(id, {}).get("uid", ""))
	if u == "":
		return   # never said hello; nowhere to file this
	profiles[u] = prof


# --- chat ------------------------------------------------------------------
#
# Everything goes through the host, including the sender's own line: it comes
# back to them like anyone else's. That costs a round trip on your own messages
# and buys one ordering that everybody sees, instead of each player seeing their
# own line jump ahead of the one it was answering.

## What to call a player in chat. Peer ids are large and change every session, so
## the last four digits are what is shown -- the same name their avatar wears
## over its head, so you can tell who said it by looking at them.
static func player_label(id: int) -> String:
	return "Player %04d" % (id % 10000)


## Say something. On a client this asks the host to post it; on a host it posts.
func say(text: String) -> void:
	if not active:
		return
	var t := text.strip_edges()
	if t.is_empty():
		return
	if t.length() > CHAT_MAX:
		t = t.substr(0, CHAT_MAX)
	if is_host:
		_post("%s: %s" % [player_label(my_id()), t])
	else:
		chat_send.rpc_id(1, t)


@rpc("any_peer", "call_remote", "reliable")
func chat_send(text: String) -> void:
	if not is_host:
		return   # only the host posts; a client cannot put words in mouths
	var t := text.strip_edges()
	if t.is_empty():
		return
	if t.length() > CHAT_MAX:
		t = t.substr(0, CHAT_MAX)
	_post("%s: %s" % [player_label(multiplayer.get_remote_sender_id()), t])


## Host side: send one finished line to everyone, show it here, write it down.
func _post(line: String) -> void:
	if active:
		chat_push.rpc(line)
	chat_received.emit(line)
	_write_chat_log(line)


@rpc("authority", "call_remote", "reliable")
func chat_push(line: String) -> void:
	chat_received.emit(line)


## Appended as it happens rather than held in memory and written out at the end.
## A log that only exists once the server shuts down cleanly is missing exactly
## the conversation you would want to read after it did not.
func _write_chat_log(line: String) -> void:
	if chat_log_path == "":
		return
	var f: FileAccess
	if FileAccess.file_exists(chat_log_path):
		f = FileAccess.open(chat_log_path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(chat_log_path, FileAccess.WRITE)
	if f == null:
		push_warning("chat log: could not open " + chat_log_path)
		return
	f.store_line("[%s] %s" % [Time.get_datetime_string_from_system(false, true), line])
	f.close()


func broadcast_state(pos: Vector3, facing: Vector3, action: int) -> void:
	if active:
		player_state.rpc(pos, facing, action)


# --- what everyone looks like ----------------------------------------------
#
# A skin is 64x64 pixels: under two kilobytes as a PNG, sent once when you
# arrive rather than with every position update. It rides in the same peer
# record as the position so a late-arriving skin has somewhere to sit until the
# avatar that wears it exists -- which is the usual case, since a joining player
# announces itself long before anybody has drawn it.

## Longest skin accepted. A real one is a couple of kilobytes; this is only here
## so a bad peer cannot hand everyone a hundred-megabyte image to decode.
const SKIN_MAX := 65536

## What this player is wearing, kept so the host can pass it on to whoever joins
## next -- who was not connected when it was first announced.
var my_skin := PackedByteArray()


## Tell everyone what you look like. Called once the world is up, on host and
## client alike: the host is a player too, and its own skin has to travel.
func announce_skin(png: PackedByteArray) -> void:
	my_skin = png
	if active:
		skin_worn.rpc(png)
		# Anything put on or picked up before the connection was up goes now.
		if my_held != 0:
			held_worn.rpc(my_held)
		if not my_look.is_empty():
			look_worn.rpc(my_look)


@rpc("any_peer", "call_remote", "reliable")
func skin_worn(png: PackedByteArray) -> void:
	var id := multiplayer.get_remote_sender_id()
	if png.size() > SKIN_MAX:
		return
	if not peers.has(id):
		peers[id] = {}
	peers[id]["skin"] = png
	# The host is the only one who sees everybody, so it is the only one who can
	# introduce them to each other. Relayed with the id spelled out, because the
	# sender of THIS message is the host rather than the player it describes.
	if is_host:
		for other in peers:
			if int(other) != id:
				skin_of.rpc_id(int(other), id, png)


## Host -> one client: "this is what that player looks like." Sent for everyone
## already here when somebody joins, and for each new arrival after that.
@rpc("authority", "call_remote", "reliable")
func skin_of(id: int, png: PackedByteArray) -> void:
	if png.size() > SKIN_MAX:
		return
	if not peers.has(id):
		peers[id] = {}
	peers[id]["skin"] = png


## Everything the newcomer missed: the host's own skin, and every skin the host
## has been told about so far.
func _send_skins_to(id: int) -> void:
	if not my_skin.is_empty():
		skin_of.rpc_id(id, 1, my_skin)
	for other in peers:
		var o := int(other)
		if o == id:
			continue
		var png = peers[other].get("skin", PackedByteArray())
		if png is PackedByteArray and not (png as PackedByteArray).is_empty():
			skin_of.rpc_id(id, o, png)


# --- what everyone is wearing -------------------------------------------------
#
# Cosmetics travel the same way skins do, as {slot: item id}: a handful of
# numbers, sent when they change rather than with every position update.

var my_look := {}
var my_held := 0


## Only real cosmetic ids in their own slots get through, so a bad packet can at
## worst dress somebody in nothing.
static func _clean_look(look: Dictionary) -> Dictionary:
	var out := {}
	for slot in look:
		var id := int(look[slot])
		if Cosmetics.SLOTS.has(str(slot)) and Cosmetics.is_cosmetic(id) and Cosmetics.slot_of(id) == str(slot):
			out[str(slot)] = id
	return out


func announce_look(look: Dictionary) -> void:
	my_look = look.duplicate()
	if active:
		look_worn.rpc(my_look)


@rpc("any_peer", "call_remote", "reliable")
func look_worn(look: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	var clean := _clean_look(look)
	if not peers.has(id):
		peers[id] = {}
	peers[id]["look"] = clean
	if is_host:
		for other in peers:
			if int(other) != id:
				look_of.rpc_id(int(other), id, clean)


@rpc("authority", "call_remote", "reliable")
func look_of(id: int, look: Dictionary) -> void:
	if not peers.has(id):
		peers[id] = {}
	peers[id]["look"] = _clean_look(look)


## What is in your hand, for everyone else to draw. Sent when you switch to
## something different, like the look is.
func announce_held(item: int) -> void:
	if item == my_held:
		return
	my_held = item
	if active:
		held_worn.rpc(item)


@rpc("any_peer", "call_remote", "reliable")
func held_worn(item: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not peers.has(id):
		peers[id] = {}
	peers[id]["held"] = item
	if is_host:
		for other in peers:
			if int(other) != id:
				held_of.rpc_id(int(other), id, item)


@rpc("authority", "call_remote", "reliable")
func held_of(id: int, item: int) -> void:
	if not peers.has(id):
		peers[id] = {}
	peers[id]["held"] = item


func _send_looks_to(id: int) -> void:
	if my_held != 0:
		held_of.rpc_id(id, 1, my_held)
	for other in peers:
		var h := int(peers[other].get("held", 0))
		if int(other) != id and h != 0:
			held_of.rpc_id(id, int(other), h)
	if not my_look.is_empty():
		look_of.rpc_id(id, 1, my_look)
	for other in peers:
		var o := int(other)
		if o == id:
			continue
		var lk = peers[other].get("look", {})
		if lk is Dictionary and not (lk as Dictionary).is_empty():
			look_of.rpc_id(id, o, lk)
