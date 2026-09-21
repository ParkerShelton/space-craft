class_name Weather
extends Node3D
## Rain, snow, fog and auroras, per world.
##
## What each world is LIKE is rolled from its seed: how often it rains or snows,
## how often fog comes in, whether its nights have auroras -- and for each of
## those, never is a real answer. What the weather is doing RIGHT NOW is decided
## by the wall clock, a few minutes at a time, hashed with the world's seed. So
## everyone in a co-op game has the same rain at the same moment without a
## single message passing between them, and the weather keeps changing even for
## a player who never goes anywhere.

## How long one spell of weather lasts before the next is decided.
const SPELL := 150.0
## Seconds to come in or clear. A spell does not arrive as a switch.
const EASE := 18.0
## Rain and snow are drawn in a box this far around the player.
const REACH := 26.0
const RAIN_DROPS := 900
const SNOW_FLAKES := 700

var world: WorldManager

## Current strengths, 0..1, eased toward what the spell calls for. main.gd reads
## these for the sky, the fog and the light.
var precip := 0.0
var fog := 0.0
var aurora := 0.0
var aurora_color := Color(0.2, 1.0, 0.55)
var aurora_color2 := Color(0.55, 0.35, 1.0)
var snowing := false

var _rain: CPUParticles3D
var _snow: CPUParticles3D
var _rain_mat: StandardMaterial3D
var _snow_mat: StandardMaterial3D
var _profiles := {}      # planet name -> what its weather is like


## What a world's weather is like, from its seed.
func profile(p: Planet) -> Dictionary:
	var got = _profiles.get(p.planet_name)
	if got != null:
		return got
	var r := RandomNumberGenerator.new()
	r.seed = p._seed + 7777
	var cls := p.planet_class()
	var pr := {}
	var air: bool = p.has_atmosphere
	# How much of the time something is falling. Airless worlds never; dry ones
	# rarely if ever; the rest anything from never to often.
	var wet_choices := [0.0, 0.15, 0.3, 0.5]
	if cls == "H" or cls == "Y":
		wet_choices = [0.0, 0.0, 0.1]
	pr["precip"] = wet_choices[r.randi() % wet_choices.size()] if air else 0.0
	# Frozen worlds snow; so does anywhere whose water is ice.
	pr["snow"] = cls == "P" or p.water_style == p.WATER_ICE
	pr["fog"] = ([0.0, 0.08, 0.18] as Array)[r.randi() % 3] if air else 0.0
	# Auroras belong to cold worlds, and turn up now and then elsewhere.
	var au_choices := [0.5, 0.8, 1.0] if cls == "P" else [0.0, 0.0, 0.0, 0.6]
	pr["aurora"] = au_choices[r.randi() % au_choices.size()] if air else 0.0
	var hue := r.randf()
	pr["aurora_a"] = Color.from_hsv(hue, 0.75, 1.0)
	pr["aurora_b"] = Color.from_hsv(fposmod(hue + r.randf_range(0.2, 0.45), 1.0), 0.7, 1.0)
	_profiles[p.planet_name] = pr
	return pr


## What this world's weather is doing in the current spell: [precip, fog].
func _spell(p: Planet, pr: Dictionary) -> Array:
	var n := int(floor(Time.get_unix_time_from_system() / SPELL))
	var c := Vector3i(n, n >> 8, 5)
	var roll := p._hash01(c, 7801)
	var strength := 0.55 + 0.45 * p._hash01(c, 7802)
	var wet: float = pr["precip"]
	if roll < wet:
		return [strength, 0.0]
	if roll < wet + float(pr["fog"]):
		return [0.0, strength]
	return [0.0, 0.0]


func _ready() -> void:
	_rain_mat = StandardMaterial3D.new()
	_rain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rain_mat.albedo_color = Color(0.72, 0.8, 0.95, 0.0)
	var drop := BoxMesh.new()
	drop.size = Vector3(0.025, 0.55, 0.025)
	drop.material = _rain_mat
	_rain = _make_emitter(drop, RAIN_DROPS, 1.2)
	_rain.direction = Vector3.DOWN
	_rain.spread = 2.0
	_rain.initial_velocity_min = 20.0
	_rain.initial_velocity_max = 24.0
	_rain.particle_flag_align_y = true

	_snow_mat = StandardMaterial3D.new()
	_snow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_snow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_snow_mat.albedo_color = Color(1, 1, 1, 0.0)
	var flake := BoxMesh.new()
	flake.size = Vector3.ONE * 0.08
	flake.material = _snow_mat
	_snow = _make_emitter(flake, SNOW_FLAKES, 9.0)
	_snow.direction = Vector3.DOWN
	_snow.spread = 30.0
	_snow.initial_velocity_min = 1.2
	_snow.initial_velocity_max = 2.4
	_snow.angular_velocity_min = -90.0
	_snow.angular_velocity_max = 90.0


func _make_emitter(mesh: Mesh, n: int, life: float) -> CPUParticles3D:
	var ps := CPUParticles3D.new()
	ps.mesh = mesh
	ps.amount = n
	ps.lifetime = life
	ps.preprocess = life
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	ps.emission_box_extents = Vector3(REACH, 1.0, REACH)
	ps.emitting = false
	# Falls in the WORLD, not with the emitter: the emitter follows the player
	# around, and rain that moved with you would look like rain on a window.
	ps.local_coords = false
	add_child(ps)
	return ps


func _process(delta: float) -> void:
	if world == null or world.player == null:
		return
	var pl: Node3D = world.player
	var p: Planet = world.nearest_planet(pl.global_position)
	var target := [0.0, 0.0]
	var pr := {}
	var outside := false
	if p != null and p.has_atmosphere and p.altitude(pl.global_position) < p.atmo_height * 0.6:
		pr = profile(p)
		target = _spell(p, pr)
		outside = true
	var step := delta / EASE
	precip = move_toward(precip, float(target[0]), step)
	fog = move_toward(fog, float(target[1]), step)
	snowing = outside and bool(pr.get("snow", false))
	aurora = float(pr.get("aurora", 0.0)) if outside else 0.0
	if outside:
		aurora_color = pr["aurora_a"]
		aurora_color2 = pr["aurora_b"]
	_place_emitters(pl, p, delta)


## Keep the rain over the player and falling along the planet's down -- and dry
## under a roof, where rain would otherwise pour straight through the ceiling.
func _place_emitters(pl: Node3D, p: Planet, delta: float) -> void:
	var up := Vector3.UP
	if p != null:
		var g := p.gravity_at(pl.global_position)
		if g.length() > 0.01:
			up = -g.normalized()
	var x := up.cross(Vector3(0.31, 0.12, 0.94)).normalized()
	var b := Basis(x, up, x.cross(up))
	var sheltered := _roof_over(pl, up)
	var show := precip > 0.02 and not sheltered
	for ps in [_rain, _snow]:
		ps.global_transform = Transform3D(b, pl.global_position + up * (14.0 if ps == _rain else 10.0))
		ps.gravity = -up * (9.8 if ps == _rain else 0.6)
	_rain.emitting = show and not snowing
	_snow.emitting = show and snowing
	# Light rain is the same rain, fainter: fading it in and out through the
	# drops' opacity never restarts the particles, so there is no pop.
	var a := clampf(precip, 0.0, 1.0)
	_rain_mat.albedo_color.a = move_toward(_rain_mat.albedo_color.a,
		(0.42 * a) if _rain.emitting else 0.0, delta * 0.8)
	_snow_mat.albedo_color.a = move_toward(_snow_mat.albedo_color.a,
		(0.9 * a) if _snow.emitting else 0.0, delta * 0.8)


func _roof_over(pl: Node3D, up: Vector3) -> bool:
	var space := pl.get_world_3d().direct_space_state
	if space == null:
		return false
	var from := pl.global_position + up * 1.6
	var q := PhysicsRayQueryParameters3D.create(from, from + up * 40.0)
	q.exclude = [(pl as CollisionObject3D).get_rid()]
	return not space.intersect_ray(q).is_empty()
