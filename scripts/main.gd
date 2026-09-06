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
var _day := 1.0                    # 0 = night, 1 = full day (eased, see _process)
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


## Hands out raw ore to test the Generator with. It has to happen HERE rather
## than in the starting kit because an ore's Combustion is invented per planet,
## so there is nothing meaningful to grant until a world exists. Gives the home
## world's best and worst burning ore, so the difference between them is
## immediately visible in a generator.
func _grant_test_fuel(world: WorldManager, player) -> void:
	if world.planets.is_empty():
		return
	var home: Planet = world.planets[0]
	var best := {}
	var worst := {}
	for oid in Blocks.ORE_SLOT_IDS:
		var d: Dictionary = home.ore_def(oid)
		if d.is_empty():
			continue
		var c := Blocks.combustion_of(d.get("props", {}))
		if best.is_empty() or c > Blocks.combustion_of(best.get("props", {})):
			best = d
		if worst.is_empty() or c < Blocks.combustion_of(worst.get("props", {})):
			worst = d
	for d in [best, worst]:
		if d.is_empty():
			continue
		player._add_item(int(d["block"]), 32, d.get("props", {}), home.planet_name,
			{"name": d.get("name", "Ore"), "color": d.get("color", Color.WHITE),
				"tier": int(d.get("tier", 0))})
		print("[kit] %s ore: Combustion %d -- burns %.1fs at %.1f power/sec" % [
			d.get("name", "?"), Blocks.combustion_of(d.get("props", {})),
			Blocks.fuel_burn_time(d.get("props", {})),
			Blocks.fuel_power_rate(d.get("props", {}))])


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

	if not load_existing:
		_grant_test_fuel(world, player)

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
	# Gravity is set by how high a JUMP it leaves you, since that is what the
	# feel of walking around actually comes from. The player leaves the ground at
	# 8 m/s (Player.JUMP_SPEED), so height is 64/(2g): the old 10-15 gave a
	# 2.1-3.2 block hop, which is why everything felt like the moon. 20-26 gives
	# 1.2-1.6 blocks, against Minecraft's 1.25 -- still comfortably over the one
	# block you need to climb a step. Moons stay deliberately floaty; they are
	# the variety, not the norm.
	var gravity := rng.randf_range(7.0, 11.0) if is_moon else rng.randf_range(20.0, 26.0)

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
		# EVERY world invents its own colours, home included. A starting planet
		# that is always Earth means most players never see an alien one; the
		# strangeness roll already keeps about a third of worlds familiar, so
		# some starts are green anyway -- by chance rather than by decree.
		"alien": true,
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
	sun.directional_shadow_max_distance = 110.0  # keep shadow map focused near the player
	# Shadow acne on flat voxel walls, worst when the sun is near the horizon:
	# the depth range the shadow map has to cover stretches right out, and this
	# world sits ~1300 units from the origin, so precision is already tight. A
	# shorter range plus normal bias (which offsets the lookup along the surface
	# normal, the thing that actually helps on flat geometry) is the standard
	# remedy. If banding survives, normal_bias is the number to raise.
	sun.shadow_normal_bias = 2.6
	sun.shadow_bias = 0.045
	sun.directional_shadow_split_1 = 0.10
	sun.directional_shadow_split_2 = 0.28
	sun.directional_shadow_blend_splits = true
	add_child(sun)
	_sun = sun


# Blend the sky/ambient between deep space and a lit atmosphere based on how deep
# in an atmospheric planet the player is. No per-planet sun math -- just a mood
# that fades in as you descend and out as you climb toward space.
var _underground := 0.0   # smoothed "how far inside the planet the camera is"

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

	# --- day / night -------------------------------------------------------
	# The terrain can't rotate -- it's world-axis-aligned voxels, and turning it
	# would break chunk coords, gravity snapping and the up-axis logic. So the
	# LIGHT moves instead: the sun swings around the planet's up axis once per
	# day, which is indistinguishable from the ground turning.
	for pl in _world.planets:
		pl.day_phase = fposmod(pl.day_phase + delta / maxf(pl.day_length, 1.0), 1.0)
	var sun_dir := Vector3(0.3, -0.8, 0.4).normalized()   # fixed light in space
	var daylight := 1.0
	var sun_height := 1.0   # 1 overhead, 0 at the horizon, negative at night
	if p != null:
		# A basis on the planet's own up, so the sun tracks across ITS sky.
		var east := up.cross(Vector3(0, 0, 1))
		if east.length() < 0.1:
			east = up.cross(Vector3(1, 0, 0))
		east = east.normalized()
		var noon := up
		var ang := p.day_phase * TAU
		# sunrise at the horizon, noon overhead, sunset opposite, then below
		var sun_pos := east * cos(ang) + noon * sin(ang)
		sun_dir = -sun_pos.normalized()
		sun_height = sin(ang)
		# An atmosphere scatters light, so dusk lingers and night keeps a little
		# blue. Without one it's a hard terminator -- glare or nothing.
		var soft: float = 0.22 if p.has_atmosphere else 0.04
		daylight = clampf(smoothstep(-soft, soft, sun_height), 0.0, 1.0)
	_day = lerpf(_day, daylight, clampf(delta * 3.0, 0.0, 1.0))

	# Redden the sky near the horizon crossing, then drain it toward night.
	var dusk := 1.0 - absf(_day * 2.0 - 1.0)          # peaks mid-transition
	acol = acol.lerp(Color(1.0, 0.45, 0.2), dusk * 0.45 * _atmo)
	# Drain almost all the way to black at night: leaving 15% of the daytime
	# blue behind kept the sky milky and drowned the stars.
	acol = acol.lerp(Color(0.008, 0.011, 0.028), (1.0 - _day) * 0.97)

	# The horizon only pales toward white while the sun is actually up --
	# otherwise it stayed bright at midnight and lit the skyline from nowhere.
	var hor := acol.lerp(Color(1, 1, 1), 0.55 * _day)
	_sky_mat.set_shader_parameter("atmo", _atmo)
	_sky_mat.set_shader_parameter("atmo_up", up)
	_sky_mat.set_shader_parameter("sky_color", Vector3(acol.r, acol.g, acol.b))
	_sky_mat.set_shader_parameter("horizon_color", Vector3(hor.r, hor.g, hor.b))
	_sky_mat.set_shader_parameter("sun_dir", -sun_dir)
	_sky_mat.set_shader_parameter("day", _day)
	# Below the terrain the sky is blacked out. A giant cavern can be wider than
	# the streamed chunk radius, and an unloaded chunk shows whatever is behind
	# it -- which was stars and neighbouring planets, seen straight through the
	# rock. Fading over a few blocks keeps a cave mouth looking like a cave mouth.
	var below := 0.0
	if p != null:
		var lp := p.to_local(ppos)
		var ln := lp.length()
		var dep: float = p.surface_radius(lp / maxf(ln, 0.0001)) - p._norm(lp)
		below = clampf(dep / 5.0, 0.0, 1.0)
	_underground = lerpf(_underground, below, clampf(delta * 4.0, 0.0, 1.0))
	_sky_mat.set_shader_parameter("underground", _underground)
	_world.player.underground = _underground > 0.6
	# Never let night reach true black: this game drains O2 and applies hazard
	# damage, and being unable to see on top of that is punishing before you
	# have any light source.
	_env.ambient_light_energy = lerpf(0.27, 0.6, _atmo) * lerpf(0.20, 1.0, _day)
	# Only follow the sky's colour while it IS coloured. At night the sky is
	# almost black and strongly blue-weighted, and tinting ambient toward it
	# washed the whole world blue-purple.
	_env.ambient_light_color = SPACE_AMBIENT.lerp(acol, _atmo * 0.8 * _day)
	# The terrain shader applies ambient itself (see voxel_block.gdshader), so it
	# needs the same values the environment is using.
	var amb: Color = _env.ambient_light_color
	for pl2 in _world.planets:
		if pl2.block_material != null:
			pl2.block_material.set_shader_parameter("ambient_color",
				Vector3(amb.r, amb.g, amb.b))
			pl2.block_material.set_shader_parameter("ambient_energy",
				_env.ambient_light_energy)
	# Ground cover is lit by the same rules, so it needs the same numbers.
	var gm := Chunk._get_grass_material()
	gm.set_shader_parameter("ambient_color", Vector3(amb.r, amb.g, amb.b))
	gm.set_shader_parameter("ambient_energy", _env.ambient_light_energy)
	# looking_at() is DEGENERATE when the direction is parallel to the up
	# reference, which happens exactly at noon and midnight (the sun sits along
	# the planet's up axis). That produced an invalid basis, and with it the
	# washed-out tint and vanishing surfaces. Pick a reference that can't be
	# parallel.
	var ref_up := Vector3.UP
	if absf(sun_dir.dot(ref_up)) > 0.98:
		ref_up = Vector3.RIGHT
	_sun.global_transform = Transform3D(Basis.looking_at(sun_dir, ref_up),
		_sun.global_position)
	_sun.light_energy = lerpf(1.2, 1.5, _atmo) * _day
	# Warm the sunlight as it sits low, the way real low sun reddens.
	_sun.light_color = Color(1, 1, 1).lerp(Color(1.0, 0.62, 0.35), dusk * 0.7 * _atmo)
	# Shadow acne, and the banded lines that come with it, is a GRAZING-ANGLE
	# problem: with the sun near the horizon the depth slope across a flat voxel
	# wall is enormous, so any fixed bias is either too small to clear the acne at
	# dawn or so large it detaches shadows from their casters at noon. So the bias
	# tracks the sun instead of being one compromise value, and as a backstop the
	# shadows themselves fade out over the last few degrees -- the window where no
	# bias is enough, and also the window where the sun is dim and orange and the
	# shadows it casts are the least of what the eye is looking at.
	var graze := 1.0 - smoothstep(0.0, 0.42, absf(sun_height))
	_sun.shadow_normal_bias = lerpf(1.4, 9.0, graze)
	_sun.shadow_opacity = lerpf(1.0, 0.1, graze * graze)
	# fog hides the render-distance edge (and the far LOD sphere) behind haze
	_env.fog_sky_affect = 0.0            # keep the sky itself clear
	# Underground the fog turns BLACK rather than switching off. Sky-coloured
	# haze on a cave wall is what made the rock read as blue instead of as
	# black -- but with no fog at all, the streamed world simply stops at a hard
	# edge against the void. Black fog does both jobs: it tints nothing, and
	# distance still dissolves into darkness instead of ending.
	_env.fog_enabled = _atmo > 0.02 or _underground > 0.02
	_env.fog_light_color = acol.lerp(Color(0, 0, 0), _underground)
	# DEPTH fog, not exponential. Exponential fog starts thickening the moment
	# you look away from your own feet, which was tuned to hide a render edge 80
	# blocks out; at twice that distance the same setting reads as thick haze on
	# a clear day. Depth fog stays out of the way entirely until the far end of
	# what is actually streamed, then closes the gap to the edge.
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	var reach := float(WorldManager.RENDER_DISTANCE * Blocks.CHUNK_SIZE)
	# Underground the same fog closes right in, which is what makes a cave wall
	# beyond the streamed chunks dissolve into black rather than end at an edge.
	_env.fog_depth_begin = lerpf(reach * 0.58, 7.0, _underground)
	_env.fog_depth_end = lerpf(reach * 1.02, 32.0, _underground)
	_env.fog_depth_curve = 1.0
	_env.fog_density = lerpf(_atmo, 1.0, _underground)

	# Hide each planet's low-res LOD sphere when you're close to it (on/near the
	# surface) so you never see it through gaps or at the horizon; show it far away.
	# Underground, hide EVERY planet. These are real meshes out in space, not part
	# of the skybox, so blacking the sky out does nothing for them -- and a
	# cavern wider than the streamed chunk radius has unloaded gaps they show
	# straight through. From inside a planet you should see rock or nothing.
	for pl in _world.planets:
		if pl.lod_sphere != null:
			pl.lod_sphere.visible = _underground < 0.6 and pl.altitude(ppos) > 260.0
