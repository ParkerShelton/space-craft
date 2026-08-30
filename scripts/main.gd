extends Node3D

## Entry point: builds the environment, spawns planets, drops the player onto the
## home world, and wires the player to the world manager. Everything is created in
## code so the scene file can stay trivial and robust.

const HOME_RADIUS := 220.0

func _ready() -> void:
	_setup_environment()

	var world := WorldManager.new()
	world.name = "World"
	add_child(world)

	# --- planets: each has a distinct size, gravity feel, and palette ----------
	# Verdis: strong gravity home world -> you walk here.
	world.add_planet({
		"name": "Verdis", "position": Vector3.ZERO,
		"radius": HOME_RADIUS, "amp": 14.0, "gravity": 12.0, "seed": 1337,
		"top": Blocks.GRASS, "sub": Blocks.DIRT, "rock": Blocks.ROCK,
		"ore": Blocks.IRON_ORE, "core": Blocks.CORE,
		"tree_density": 0.4,  # lush forest
	})
	# Frost: medium gravity ice world -- sparse hardy trees.
	world.add_planet({
		"name": "Frost", "position": Vector3(900, 120, 300),
		"radius": 120.0, "amp": 10.0, "gravity": 6.0, "seed": 4242,
		"top": Blocks.SNOW, "sub": Blocks.ICE, "rock": Blocks.ROCK,
		"ore": Blocks.CRYSTAL, "core": Blocks.ICE,
		"tree_density": 0.12,
	})
	# Shard: small low-gravity crystal world -- barren, no trees.
	world.add_planet({
		"name": "Shard", "position": Vector3(-750, -200, 600),
		"radius": 70.0, "amp": 16.0, "gravity": 1.8, "seed": 9001,
		"top": Blocks.CRYSTAL, "sub": Blocks.ROCK, "rock": Blocks.ROCK,
		"ore": Blocks.IRON_ORE, "core": Blocks.CRYSTAL,
		"tree_density": 0.0,
	})
	# Ochre: desert world -- dunes, no trees.
	world.add_planet({
		"name": "Ochre", "position": Vector3(500, -700, -650),
		"radius": 100.0, "amp": 8.0, "gravity": 9.0, "seed": 2024,
		"top": Blocks.REGOLITH, "sub": Blocks.REGOLITH, "rock": Blocks.ROCK,
		"ore": Blocks.IRON_ORE, "core": Blocks.CORE,
		"tree_density": 0.0,
	})

	# --- player: drop in just above the home surface --------------------------
	var player := Player.new()
	player.name = "Player"
	player.world = world
	player.position = Vector3(0, HOME_RADIUS + 8.0, 0)
	add_child(player)
	world.player = player

	# Build a small stack of chunks under the spawn point synchronously so the
	# player lands on solid ground instead of falling while workers catch up.
	var home: Planet = world.planets[0]
	var pcc := home.chunk_of(home.world_to_voxel(player.global_position))
	for dy in range(1, -4, -1):
		home.build_chunk_sync(pcc + Vector3i(0, dy, 0))


func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()

	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/space_sky.gdshader")
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# Black sky => sky ambient would be ~0, so use a fixed dim fill instead.
	# Keep it low so the sun + baked per-face shading give real contrast.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.50, 0.55, 0.70)
	env.ambient_light_energy = 0.27
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	we.environment = env
	add_child(we)

	# a sun
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-45), deg_to_rad(30), 0)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0  # keep shadow map focused near the player
	add_child(sun)
