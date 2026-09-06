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
const MAX_PLAYERS := 8

signal world_ready(seed_value: int, system_index: int)
signal roster_changed()
## The host recognised us and sent back what we were carrying last time.
signal profile_restored(profile: Dictionary)

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

var _world: WorldManager
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
			_:
				_apply_bulk(e[1], e[2], e[3])
	_pending.clear()


func my_id() -> int:
	return multiplayer.get_unique_id() if active else 1


# --- connection plumbing --------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_host:
		return
	peers[id] = {"pos": Vector3.ZERO, "yaw": 0.0}
	roster_changed.emit()
	# Hand the newcomer the world it has to build. Nothing else can happen until
	# it has this: its terrain would not match ours.
	world_info.rpc_id(id, _seed, _system)
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


func _on_peer_disconnected(id: int) -> void:
	peers.erase(id)
	roster_changed.emit()


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

@rpc("authority", "call_remote", "reliable")
func world_info(seed_value: int, system_index: int) -> void:
	_seed = seed_value
	_system = system_index
	joining = false
	world_ready.emit(seed_value, system_index)


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


func _apply_bulk(planet_name: String, cells: PackedVector3Array, ids: PackedInt32Array) -> void:
	var p := _planet(planet_name)
	if p == null:
		return
	for i in mini(cells.size(), ids.size()):
		var c: Vector3 = cells[i]
		p.set_block(Vector3i(roundi(c.x), roundi(c.y), roundi(c.z)), ids[i])
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
func edit_block(planet_name: String, v: Vector3i, id: int) -> void:
	var p := _planet(planet_name)
	if p != null:
		p.set_block(v, id)
	if not active:
		return
	if is_host:
		apply_edit.rpc(planet_name, v, id)
	else:
		request_edit.rpc_id(1, planet_name, v, id)


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


## Client -> host. The host is the only authority on what the world contains.
@rpc("any_peer", "call_remote", "reliable")
func request_edit(planet_name: String, v: Vector3i, id: int) -> void:
	if not is_host:
		return
	var p := _planet(planet_name)
	if p != null:
		p.set_block(v, id)
	# Back out to everyone INCLUDING the requester's neighbours; the requester
	# already applied it locally.
	apply_edit.rpc(planet_name, v, id)


## Host -> clients.
@rpc("authority", "call_remote", "reliable")
func apply_edit(planet_name: String, v: Vector3i, id: int) -> void:
	if not _world_built:
		_pending.append(["blocks", planet_name,
			PackedVector3Array([Vector3(v)]), PackedInt32Array([id])])
		return
	var p := _planet(planet_name)
	if p != null:
		p.set_block(v, id)


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


func broadcast_state(pos: Vector3, facing: Vector3, action: int) -> void:
	if active:
		player_state.rpc(pos, facing, action)
