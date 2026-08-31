extends Node3D

## Entry point: builds the environment, spawns planets, drops the player onto the
## home world, and wires the player to the world manager. Everything is created in
## code so the scene file can stay trivial and robust.

const HOME_RADIUS := 1500.0
const SPACE_AMBIENT := Color(0.50, 0.55, 0.70)

var _world: WorldManager
var _env: Environment
var _sky_mat: ShaderMaterial
var _sun: DirectionalLight3D
var _atmo := 0.0

func _notification(what: int) -> void:
	# Autosave when the window is closed (X button, Alt+F4, etc.).
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _world != null:
			_world.save_game()
		get_tree().quit()


func _ready() -> void:
	_setup_environment()

	var world := WorldManager.new()
	world.name = "World"
	add_child(world)
	_world = world

	# --- planets: mostly massive (explore for ages before circling one), plus a
	# small one mixed in. Spaced far apart; float precision is still fine here.
	# Verdis: massive green home world with an Earth-like sky.
	world.add_planet({
		"name": "Verdis", "position": Vector3.ZERO,
		"radius": HOME_RADIUS, "amp": 55.0, "gravity": 14.0, "seed": 1337,
		"top": Blocks.GRASS, "sub": Blocks.DIRT, "rock": Blocks.ROCK,
		"ore": Blocks.IRON_ORE, "core": Blocks.CORE,
		"tree_density": 0.4,
		"atmosphere": true, "atmo_color": Color(0.45, 0.68, 1.0), "atmo_height": 750.0,
		"water_style": "liquid", "water_amount": 0.24,  # lakes & rivers, lots of land
	})
	# Frost: enormous ice world, pale cold sky, sparse hardy trees.
	world.add_planet({
		"name": "Frost", "position": Vector3(6000, 900, 2200),
		"radius": 1800.0, "amp": 70.0, "gravity": 12.0, "seed": 4242,
		"top": Blocks.SNOW, "sub": Blocks.ICE, "rock": Blocks.ROCK,
		"ore": Blocks.CRYSTAL, "core": Blocks.ICE,
		"tree_density": 0.1,
		"atmosphere": true, "atmo_color": Color(0.62, 0.76, 0.95), "atmo_height": 900.0,
		"water_style": "ice", "water_amount": 0.42,  # frozen seas, peaks poke out
	})
	# Shard: small crystal moon, thin air -> no atmosphere, barren.
	world.add_planet({
		"name": "Shard", "position": Vector3(3200, 4600, -3600),
		"radius": 260.0, "amp": 16.0, "gravity": 5.0, "seed": 9001,
		"top": Blocks.CRYSTAL, "sub": Blocks.ROCK, "rock": Blocks.ROCK,
		"ore": Blocks.IRON_ORE, "core": Blocks.CRYSTAL,
		"tree_density": 0.0,
		"atmosphere": false,
		"water_style": "liquid", "water_amount": 0.85,  # ocean moon -- almost all water
	})
	# Ochre: massive desert world, dusty orange sky.
	world.add_planet({
		"name": "Ochre", "position": Vector3(-4800, -1500, 5200),
		"radius": 1300.0, "amp": 55.0, "gravity": 11.0, "seed": 2024,
		"top": Blocks.REGOLITH, "sub": Blocks.REGOLITH, "rock": Blocks.ROCK,
		"ore": Blocks.IRON_ORE, "core": Blocks.CORE,
		"tree_density": 0.0,
		"atmosphere": true, "atmo_color": Color(0.85, 0.6, 0.4), "atmo_height": 650.0,
		"water_style": "none",  # bone-dry desert
	})

	# --- player: drop in just above dry land on the home world ----------------
	var home: Planet = world.planets[0]
	var player := Player.new()
	player.name = "Player"
	player.world = world
	player.position = home.find_spawn_point(Vector3.UP)
	add_child(player)
	world.player = player

	# If a save exists, load it now (this moves the player, restores inventory,
	# planet edits and ships). Otherwise we keep the fresh spawn point above.
	if world.has_save():
		world.load_game()

	# Don't let the OS close the window until we've flushed a save.
	get_tree().set_auto_accept_quit(false)

	# Build a small stack of chunks under the (possibly loaded) player position
	# synchronously so the player lands on solid ground instead of falling while
	# workers catch up.
	var ground: Planet = world.nearest_planet(player.global_position)
	if ground == null:
		ground = home
	if ground.altitude(player.global_position) < 96.0:
		var pcc := ground.chunk_of(ground.world_to_voxel(player.global_position))
		for dy in range(1, -4, -1):
			ground.build_chunk_sync(pcc + Vector3i(0, dy, 0))


func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()

	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/space_sky.gdshader")
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = SPACE_AMBIENT
	env.ambient_light_energy = 0.27
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	we.environment = env
	add_child(we)
	_env = env
	_sky_mat = sky_mat

	# a sun (single global light -- provides real directional shading everywhere)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-45), deg_to_rad(30), 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0  # keep shadow map focused near the player
	add_child(sun)
	_sun = sun


# Blend the sky/ambient between deep space and a lit atmosphere based on how deep
# in an atmospheric planet the player is. No per-planet sun math -- just a mood
# that fades in as you descend and out as you climb toward space.
func _process(delta: float) -> void:
	if _world == null or _world.player == null or _sky_mat == null:
		return
	var ppos: Vector3 = _world.player.global_position
	var p := _world.nearest_planet(ppos)
	var target := 0.0
	var acol := Color(0.45, 0.68, 1.0)
	var up := Vector3.UP
	if p != null and p.has_atmosphere:
		var alt := p.altitude(ppos)  # shape-aware (cube/sphere)
		# smoothstep over the whole atmo band so it eases in/out (no hard edge)
		target = smoothstep(0.0, 1.0, clampf(1.0 - alt / p.atmo_height, 0.0, 1.0))
		acol = p.atmo_color
		var g := _world.gravity_at(ppos)
		if g.length() > 0.01:
			up = -g.normalized()
	_atmo = lerpf(_atmo, target, clampf(delta * 2.0, 0.0, 1.0))

	var hor := acol.lerp(Color(1, 1, 1), 0.55)
	_sky_mat.set_shader_parameter("atmo", _atmo)
	_sky_mat.set_shader_parameter("atmo_up", up)
	_sky_mat.set_shader_parameter("sky_color", Vector3(acol.r, acol.g, acol.b))
	_sky_mat.set_shader_parameter("horizon_color", Vector3(hor.r, hor.g, hor.b))
	_env.ambient_light_energy = lerpf(0.27, 0.6, _atmo)
	_env.ambient_light_color = SPACE_AMBIENT.lerp(acol, _atmo * 0.8)
	_sun.light_energy = lerpf(1.2, 1.5, _atmo)
	# fog hides the render-distance edge (and the far LOD sphere) behind haze
	_env.fog_enabled = _atmo > 0.02
	_env.fog_light_color = acol
	_env.fog_sky_affect = 0.0            # keep the sky itself clear
	_env.fog_density = _atmo * 0.008

	# Hide each planet's low-res LOD sphere when you're close to it (on/near the
	# surface) so you never see it through gaps or at the horizon; show it far away.
	for pl in _world.planets:
		if pl.lod_sphere != null:
			pl.lod_sphere.visible = pl.altitude(ppos) > 260.0
