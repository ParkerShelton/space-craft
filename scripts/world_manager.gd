class_name WorldManager
extends Node3D

## Owns every planet, decides which one you're closest to, streams that planet's
## chunks around you, and answers gravity queries for the player controller.

const RENDER_DISTANCE := 5        # chunk radius streamed around the player
const LOADS_PER_FRAME := 4        # chunks meshed per frame (spreads out hitches)
const STREAM_MARGIN := 48.0       # extra reach (voxels) beyond a planet's surface

var planets: Array[Planet] = []
var player: Node3D
var _ships: Array[Ship] = []


## Create a new ship seeded with a cockpit. Snaps orientation to the block grid
## (axis-aligned, parallel to the floor) and position to whole cells, so it lines
## up with the world instead of sitting at an odd angle.
func spawn_ship(pos: Vector3, up: Vector3, fwd: Vector3) -> Ship:
	var ship := Ship.new()
	ship.world = self
	add_child(ship)

	var y := _snap_axis(up)                          # up = the face axis you're on
	var f := _snap_axis(fwd - y * fwd.dot(y))        # forward = nearest grid axis you face
	if f == Vector3.ZERO or absf(f.dot(y)) > 0.5:
		f = _any_perp(y)
	var z := -f                                      # forward is -Z
	var x := y.cross(z)
	ship.global_transform = Transform3D(Basis(x, y, z), pos.round())

	ship.set_block(Vector3i.ZERO, Blocks.COCKPIT)
	_ships.append(ship)
	return ship


# Nearest outward cardinal axis to v (Vector3.ZERO if v is ~zero).
func _snap_axis(v: Vector3) -> Vector3:
	if v.length() < 0.001:
		return Vector3.ZERO
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


# A cardinal axis perpendicular to `axis`.
func _any_perp(axis: Vector3) -> Vector3:
	for c in [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 1, 0)]:
		if absf(c.dot(axis)) < 0.5:
			return c
	return Vector3(0, 0, -1)


## Nearest still-alive ship to a world point, or null.
func nearest_ship(world_pos: Vector3) -> Ship:
	_ships = _ships.filter(func(s): return is_instance_valid(s))
	var best: Ship = null
	var best_d := INF
	for s in _ships:
		var d: float = (s.global_position - world_pos).length_squared()
		if d < best_d:
			best_d = d
			best = s
	return best


func add_planet(cfg: Dictionary) -> Planet:
	var p := Planet.new()
	p.name = cfg.get("name", "Planet")
	p.position = cfg.get("position", Vector3.ZERO)
	add_child(p)
	p.configure(cfg)
	planets.append(p)
	return p


## Strongest gravity contributor wins (avoids fighting fields between planets).
func gravity_at(world_pos: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_mag := 0.0
	for p in planets:
		var g := p.gravity_at(world_pos)
		var m := g.length()
		if m > best_mag:
			best_mag = m
			best = g
	return best


## The planet whose surface is nearest the given point (or null if far from all).
func nearest_planet(world_pos: Vector3) -> Planet:
	var best: Planet = null
	var best_d := INF
	for p in planets:
		var surface_dist: float = p.altitude(world_pos)  # shape-aware (cube/sphere)
		if surface_dist < best_d:
			best_d = surface_dist
			best = p
	return best


func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var here := player.global_position
	var active := nearest_planet(here)
	for p in planets:
		if p == active:
			var reach := p.radius + p.terrain_amp + STREAM_MARGIN
			if p.center_distance(here) <= reach + RENDER_DISTANCE * Blocks.CHUNK_SIZE:
				p.stream(p.world_to_voxel(here), RENDER_DISTANCE)
				p.process_load_queue(LOADS_PER_FRAME)
