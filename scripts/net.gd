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
@rpc("any_peer", "call_remote", "unreliable_ordered")
func player_state(pos: Vector3, yaw: float) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not peers.has(id):
		peers[id] = {}
		roster_changed.emit()
	peers[id]["pos"] = pos
	peers[id]["yaw"] = yaw


func broadcast_state(pos: Vector3, yaw: float) -> void:
	if active:
		player_state.rpc(pos, yaw)
