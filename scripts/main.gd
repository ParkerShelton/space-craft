extends Node3D

## Entry point: builds the environment, spawns planets, drops the player onto the
## home world, and wires the player to the world manager. Everything is created in
## code so the scene file can stay trivial and robust.

const SPACE_AMBIENT := Color(0.50, 0.55, 0.70)

# Planet archetypes randomly assigned to generated planets (index 0 = home/verdant).
const _ARCHETYPES := [
	{"top": Blocks.GRASS, "sub": Blocks.DIRT, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.45, 0.68, 1.0), "water": "liquid", "wmin": 0.15, "wmax": 0.4,
		"tmin": 0.3, "tmax": 0.55, "moon": false, "hazard": "none", "hdps": 0.0},
	{"top": Blocks.SNOW, "sub": Blocks.ICE, "rock": Blocks.ROCK, "core": Blocks.ICE,
		"atmo": true, "atmo_color": Color(0.62, 0.76, 0.95), "water": "ice", "wmin": 0.3, "wmax": 0.6,
		"tmin": 0.05, "tmax": 0.2, "moon": false, "hazard": "cold", "hdps": 3.5},
	{"top": Blocks.REGOLITH, "sub": Blocks.REGOLITH, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.85, 0.6, 0.4), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.0, "moon": false, "hazard": "heat", "hdps": 2.0},
	{"top": Blocks.CRYSTAL, "sub": Blocks.ROCK, "rock": Blocks.ROCK, "core": Blocks.CRYSTAL,
		"atmo": false, "atmo_color": Color(0.4, 0.85, 0.9), "water": "liquid", "wmin": 0.6, "wmax": 0.95,
		"tmin": 0.0, "tmax": 0.0, "moon": true, "hazard": "none", "hdps": 0.0},
	{"top": Blocks.ROCK, "sub": Blocks.ROCK, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": false, "atmo_color": Color(0.6, 0.6, 0.65), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.0, "moon": true, "hazard": "cold", "hdps": 3.0},
	{"top": Blocks.ROCK, "sub": Blocks.DIRT, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.9, 0.5, 0.35), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.0, "moon": false, "hazard": "heat", "hdps": 4.5},
]
const _NAME_PRE := ["Ver", "Kro", "Zel", "Nyx", "Tor", "Aur", "Hel", "Ori", "Vex",
	"Mar", "Cae", "Lun", "Sol", "Ith", "Ryl", "Dun", "Pyr", "Oss", "Tal", "Ael"]
const _NAME_SUF := ["dis", "nis", "ara", "ex", "os", "une", "ia", "or", "eth", "yn", "us", "a"]

var _world: WorldManager
var _env: Environment
var _sky_mat: ShaderMaterial
var _sun: DirectionalLight3D
var _atmo := 0.0
var _menu_layer: CanvasLayer
var _menu_vb: VBoxContainer

func _notification(what: int) -> void:
	# Autosave when the window is closed (X button, Alt+F4, etc.). Never in a
	# headless run -- that would let test/CI runs clobber the real save.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# only autosave once a world has actually started (not from the menu), and
		# never headless
		if _world != null and _world.player != null and DisplayServer.get_name() != "headless":
			_world.save_game()
		get_tree().quit()


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)  # route window-close through _notification
	_setup_environment()
	var world := WorldManager.new()
	world.name = "World"
	add_child(world)
	_world = world
	world.planet_generator = Callable(self, "_generate_planets")
	_build_menu()


# --- main menu ----------------------------------------------------------------

func _build_menu() -> void:
	_menu_layer = CanvasLayer.new()
	_menu_layer.layer = 10
	add_child(_menu_layer)
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu_layer.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu_layer.add_child(center)
	_menu_vb = VBoxContainer.new()
	_menu_vb.add_theme_constant_override("separation", 14)
	_menu_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_menu_vb)
	_menu_populate(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _menu_button(text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 44)
	b.pressed.connect(cb)
	_menu_vb.add_child(b)


func _menu_label(text: String, size: int, alpha := 1.0) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.modulate = Color(1, 1, 1, alpha)
	_menu_vb.add_child(l)


func _menu_populate(confirm_delete: bool) -> void:
	for c in _menu_vb.get_children():
		c.queue_free()
	if confirm_delete:
		_menu_label("Delete your current world", 26)
		_menu_label("and start a new one?", 26)
		_menu_label(" ", 8)
		_menu_button("Yes, start new world", func():
			_delete_save()
			_start_world(false))
		_menu_button("Cancel", func(): _menu_populate(false))
		return
	_menu_label("SPACECRAFT", 52)
	_menu_label("a voxel game in space", 18, 0.55)
	_menu_label(" ", 14)
	var has_world: bool = _world.saved_world_seed() >= 0
	if has_world:
		_menu_button("Continue", func(): _start_world(true))
	if _world.has_save():
		_menu_button("New World", func(): _menu_populate(true))
	else:
		_menu_button("New World", func(): _start_world(false))
	_menu_button("Quit", func(): get_tree().quit())


func _delete_save() -> void:
	DirAccess.remove_absolute(WorldManager.SAVE_PATH)
	DirAccess.remove_absolute(WorldManager.SAVE_BAK)


func _rand_seed() -> int:
	var r := RandomNumberGenerator.new()
	r.randomize()
	return int(r.randi() & 0x7fffffff)


# --- start the actual world (from Continue or New World) -----------------------

func _start_world(load_existing: bool) -> void:
	if _menu_layer != null:
		_menu_layer.queue_free()
		_menu_layer = null
	_show_loading_screen()

	var world := _world
	var wseed := world.saved_world_seed() if load_existing else _rand_seed()
	if wseed < 0:
		wseed = _rand_seed()
	world.world_seed = wseed
	Chunk.set_texture_seed(wseed)  # re-roll procedural block texturing per world

	var galaxy := Galaxy.new()
	galaxy.generate(wseed)
	world.galaxy = galaxy
	# home_system_index() finds the first system with at least a primitive colony,
	# so a new game always starts somewhere with intelligent life nearby -- not
	# necessarily system 0. No warp travel yet, so this is also just "the" system.
	world.current_system_index = galaxy.home_system_index()
	var sysdef: Dictionary = galaxy.systems[world.current_system_index]
	print("[galaxy] %d systems generated -- starting in %s (%s, %d planets)" % [
		galaxy.systems.size(), sysdef["name"], Galaxy.civ_name(sysdef["civ_tier"]), sysdef["planet_count"]])
	_generate_planets(world, sysdef)

	# player: drop in just above dry land on the home world
	var home: Planet = world.planets[0]
	var player := Player.new()
	player.name = "Player"
	player.world = world
	player.position = home.find_spawn_point(Vector3.UP)
	add_child(player)
	world.player = player

	if load_existing:
		world.load_game()

	# Don't let the OS close the window until we've flushed a save.
	get_tree().set_auto_accept_quit(false)

	# Build a small stack of chunks under the (possibly loaded) player position
	# so the player lands on solid ground instead of falling while workers catch up.
	var ground: Planet = world.nearest_planet(player.global_position)
	if ground == null:
		ground = home
	if ground.altitude(player.global_position) < 96.0:
		var pcc := ground.chunk_of(ground.world_to_voxel(player.global_position))
		for dy in range(1, -4, -1):
			ground.build_chunk_sync(pcc + Vector3i(0, dy, 0))

	# Frame smoothness doesn't matter behind an opaque loading screen, so push
	# far more chunks through the worker pool than we'd ever allow once the
	# world is visible -- this is the single biggest lever for shortening the
	# wait, on top of the generation_sample optimizations.
	ground.set_fast_loading(true)
	await _wait_for_world_ready(ground, player)
	ground.set_fast_loading(false)
	_hide_loading_screen()
	# Combat testing: don't leave the guaranteed home-planet enemy (see
	# force_hostile_enemy) to the normal random wildlife spawner -- that only
	# guarantees it EXISTS, not that you'll actually see it soon.
	ground.spawn_hostile_enemy_near(player.global_position, world)


# --- loading screen -------------------------------------------------------------

## Chunk radius that must have real collision before we reveal the world.
##
## Tried both extremes: radius 1 revealed almost instantly but then the full
## view distance (WorldManager.RENDER_DISTANCE=5, 1331 candidate chunks)
## visibly popped in around the player, which felt broken rather than fast.
## Waiting for the FULL render distance measured ~25-28s even after every
## other optimization here -- actual sustained throughput on this machine is
## ~48 chunks/sec, so 1331 chunks is just a genuinely large amount of work.
## Radius 2 (up to 125 candidates) is the practical middle ground: everything
## in your immediate surroundings is solid before you ever see it, and it
## reveals in a few seconds instead of ~30 -- render-distance streaming then
## continues to fill in the horizon exactly like normal gameplay streaming
## already does when you walk toward new terrain.
const LOAD_READY_RADIUS := 2
const LOAD_TIMEOUT_SEC := 25.0  # safety cap so a bug elsewhere can't hang the screen forever
var _loading_layer: CanvasLayer
var _loading_root: Control  # fades out on hide -- CanvasLayer itself has no modulate
var _loading_label: Label

func _show_loading_screen() -> void:
	_loading_layer = CanvasLayer.new()
	_loading_layer.layer = 20
	add_child(_loading_layer)
	_loading_root = Control.new()
	_loading_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_layer.add_child(_loading_root)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.06, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_root.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vb)
	var title := Label.new()
	title.text = "SPACECRAFT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	vb.add_child(title)
	_loading_label = Label.new()
	_loading_label.text = "Generating world…"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.modulate = Color(1, 1, 1, 0.7)
	vb.add_child(_loading_label)


func _hide_loading_screen() -> void:
	if _loading_layer == null:
		return
	var layer := _loading_layer
	var root := _loading_root
	_loading_layer = null
	_loading_root = null
	var tw := create_tween()
	tw.tween_property(root, "modulate:a", 0.0, 0.5)
	tw.tween_callback(layer.queue_free)


## Waits until a safe radius of chunks around the player has REAL collision --
## not just "generation_sample says solid ground here" (see
## Planet._chunk_ready_at for why that distinction matters: terrain is a pure
## function that answers instantly everywhere, but there's nothing to actually
## stand on until a chunk's mesh has been built and applied on the main
## thread). Updates the loading label with progress; capped by LOAD_TIMEOUT_SEC
## so a bug elsewhere can't hang the loading screen forever -- worst case you
## just see an incomplete world, same as before this existed.
func _wait_for_world_ready(ground: Planet, player: Player) -> void:
	var elapsed := 0.0
	while elapsed < LOAD_TIMEOUT_SEC:
		var cc0 := ground.chunk_of(ground.world_to_voxel(player.global_position))
		var total := 0
		var have := 0
		for dx in range(-LOAD_READY_RADIUS, LOAD_READY_RADIUS + 1):
			for dy in range(-LOAD_READY_RADIUS, LOAD_READY_RADIUS + 1):
				for dz in range(-LOAD_READY_RADIUS, LOAD_READY_RADIUS + 1):
					var cc := cc0 + Vector3i(dx, dy, dz)
					if not ground._chunk_possibly_solid(cc):
						continue
					total += 1
					if ground.loaded_chunks.has(cc):
						have += 1
		if _loading_label != null:
			_loading_label.text = "Generating world… (%d / %d chunks)" % [have, maxi(total, 1)]
		if total == 0 or have >= total:
			return
		await get_tree().process_frame
		elapsed += get_process_delta_time()


# Deterministically create a system's planets from its seed. Planet 0 is the
# habitable home world (verdant, and where the player spawns); the rest are
# random archetypes spread out in space. Which planets (if any) get a
# settlement, and how big it's allowed to grow, comes entirely from the
# system's civilization tier (see galaxy.gd) -- not rolled per-planet.
func _generate_planets(world: WorldManager, sysdef: Dictionary) -> void:
	var master_seed: int = sysdef["seed"]
	var civ_tier: int = sysdef["civ_tier"]
	var count: int = sysdef["planet_count"]
	var rng := RandomNumberGenerator.new()
	rng.seed = master_seed
	var settled := _plan_settlements(rng, count, civ_tier)
	var positions := []
	var used_names := {}
	for i in count:
		var cfg := _make_planet_cfg(rng, i, master_seed, positions, settled[i])
		cfg["civ_tier"] = civ_tier  # drives settlement architecture, not just placement
		# guarantee unique names (saves key planet edits by name)
		var nm: String = cfg["name"]
		if used_names.has(nm):
			nm = "%s %d" % [nm, i + 1]
		used_names[nm] = true
		cfg["name"] = nm
		positions.append(cfg["position"])
		world.add_planet(cfg)


# Decide which planet indices in this system get a settlement and how big it
# may grow, purely from the system's civilization tier. Planet 0 is always the
# player's home world, so it's the guaranteed one when the system has any
# civilization at all -- Advanced systems also seed 1-2 other colonized worlds,
# giving a real reason to travel within the system later.
func _plan_settlements(rng: RandomNumberGenerator, count: int, civ_tier: int) -> Array:
	var out := []
	for i in count:
		out.append({"enabled": false, "forced": false, "tier_cap": 0})
	if civ_tier == Galaxy.CIV_PRIMITIVE:
		out[0] = {"enabled": true, "forced": true, "tier_cap": 2}
	elif civ_tier == Galaxy.CIV_ADVANCED:
		out[0] = {"enabled": true, "forced": true, "tier_cap": 3}
		var pool := range(1, count)
		for i in range(pool.size() - 1, 0, -1):  # deterministic Fisher-Yates (our own
			var j := rng.randi_range(0, i)       # seeded rng, NOT Array.shuffle's global one)
			var tmp = pool[i]
			pool[i] = pool[j]
			pool[j] = tmp
		var extra := mini(rng.randi_range(1, 2), pool.size())
		for k in extra:
			out[pool[k]] = {"enabled": true, "forced": false, "tier_cap": 3}
	return out


func _make_planet_cfg(rng: RandomNumberGenerator, index: int, master_seed: int, used: Array,
		settled_info: Dictionary) -> Dictionary:
	var a: Dictionary = _ARCHETYPES[0] if index == 0 else _ARCHETYPES[rng.randi_range(0, _ARCHETYPES.size() - 1)]
	# home is always a big habitable world; others may be moons
	var is_moon: bool = (index != 0) and bool(a["moon"]) and rng.randf() < 0.7
	var radius := rng.randf_range(240.0, 420.0) if is_moon else rng.randf_range(1100.0, 1900.0)
	var amp := rng.randf_range(12.0, 26.0) if is_moon else rng.randf_range(45.0, 75.0)
	var gravity := rng.randf_range(4.0, 7.0) if is_moon else rng.randf_range(10.0, 15.0)

	# position: home at origin, others spread on random directions/distances, kept
	# a few thousand units apart (float precision stays fine within ~10k)
	var pos := Vector3.ZERO
	if index != 0:
		for _attempt in 12:
			var dir := Vector3(rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0)
			if dir.length() < 0.01:
				dir = Vector3.RIGHT
			pos = dir.normalized() * rng.randf_range(5000.0, 9500.0)
			var ok := true
			for u in used:
				if pos.distance_to(u) < 4000.0:
					ok = false
					break
			if ok:
				break

	var water: String = a["water"]
	var water_amount := 0.0
	if water != "none":
		water_amount = rng.randf_range(float(a["wmin"]), float(a["wmax"]))
	var trees := rng.randf_range(float(a["tmin"]), float(a["tmax"]))

	return {
		"name": _planet_name(rng), "position": pos,
		"radius": radius, "amp": amp, "gravity": gravity, "seed": master_seed + index * 7919,
		"top": a["top"], "sub": a["sub"], "rock": a["rock"], "core": a["core"],
		"ore": Blocks.IRON_ORE,  # legacy field; ores are procedural per planet
		"tree_density": trees,
		"atmosphere": bool(a["atmo"]), "atmo_color": a["atmo_color"],
		"atmo_height": rng.randf_range(600.0, 950.0),
		"water_style": water, "water_amount": water_amount,
		"hazard": a["hazard"], "hazard_dps": a["hdps"],
		"settlements_enabled": settled_info["enabled"],
		"force_settlement": settled_info["forced"],
		"settlement_tier_cap": settled_info["tier_cap"],
		# Combat v1 testing (2026-09-01): guarantee a hostile enemy on the home
		# planet regardless of the normal wildlife roll, so there's always
		# something to fight right at spawn. Remove once enemies are common
		# enough on their own merits.
		"force_hostile_enemy": index == 0,
	}


func _planet_name(rng: RandomNumberGenerator) -> String:
	return _NAME_PRE[rng.randi_range(0, _NAME_PRE.size() - 1)] + _NAME_SUF[rng.randi_range(0, _NAME_SUF.size() - 1)]


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
