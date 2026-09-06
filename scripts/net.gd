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

var active := false          ## networking is up at all
var is_host := false
var joining := false         ## client, connected, still waiting for the seed
var last_error := ""

## peer id -> {"pos": Vector3, "yaw": float, "name": String}
var peers: Dictionary = {}

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
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)


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
		_apply_bulk(e[0], e[1], e[2])
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
		_pending.append([planet_name, cells, ids])
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
		_pending.append([planet_name, PackedVector3Array([Vector3(v)]), PackedInt32Array([id])])
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
func player_state(pos: Vector3, facing: Vector3) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not peers.has(id):
		peers[id] = {}
		roster_changed.emit()
	peers[id]["pos"] = pos
	peers[id]["facing"] = facing


func broadcast_state(pos: Vector3, facing: Vector3) -> void:
	if active:
		player_state.rpc(pos, facing)
