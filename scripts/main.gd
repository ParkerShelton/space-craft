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
var _net: Net
var _join_ip: LineEdit
var _net_mode := "single"
var _client_seed := 0
var _client_system := 0
## The host's time of day for each planet, in planet order, handed over on
## joining. Kept until the planets exist to put it on.
var _client_phases := PackedFloat32Array()
var _avatars := {}          # peer id -> RemotePlayer
var _net_tick := 0.0
var _profile_tick := 0.0
var _profile_hash := 0
## Nothing is sent up until the host has answered our hello. Until then we do not
## know whether this empty inventory is a new player or one the host is about to
## fill in, and pushing the wrong one destroys the saved copy.
var _profile_ready := false
var _menu_vb: VBoxContainer
## The Escape screen. Called the GAME MENU rather than a pause menu, because it
## does not pause anything: the world, the creatures and everyone else on the
## server carry on while it is up. Calling it "pause" would be a promise the
## game does not keep.
var _game_menu: CanvasLayer
var _game_menu_vb: VBoxContainer
var _chat_layer: CanvasLayer
var _chat_label: Label
var _chat_entry: LineEdit
var _chat_lines: Array[String] = []
var _chat_fade := 0.0
## How many lines stay on screen, and how long after the last one before they
## fade. Long enough to read something you were not looking at when it arrived.
const CHAT_LINES := 8
const CHAT_HOLD := 12.0
## Cleared once --join has been acted on, so leaving a server to the main menu
## does not walk straight back into it. Static because it has to outlive the
## scene reload that exiting performs.
static var _auto_joined := false

## How often a client checks whether its inventory has changed and, if so, tells
## the host. Not every pickup: mining a stack of stone changes the inventory on
## most frames, and the host only needs to be close enough that a crash costs a
## couple of seconds of gathering.
const PROFILE_RATE := 3.0

## How often a dedicated server writes its world down. Cheap -- the save is a
## sparse dictionary of edits, not terrain -- so this is short enough that a
## crash costs a minute of building rather than an evening of it.
const SERVER_SAVE_EVERY := 60.0

## Player preferences, kept apart from the world save: they belong to the person,
## not to the world, and should survive starting a new one.
const SETTINGS_PATH := "user://settings.cfg"
var _settings := ConfigFile.new()

func _notification(what: int) -> void:
	# Autosave when the window is closed (X button, Alt+F4, etc.). Never in a
	# headless run -- that would let test/CI runs clobber the real save.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# only autosave once a world has actually started (not from the menu), and
		# never headless
		# Never from a networked session: co-op runs on a throwaway world and has
		# no business overwriting the single-player one.
		if _world != null and _world.player != null and _net_mode == "single" 				and DisplayServer.get_name() != "headless":
			_world.save_game()
		# Leaving a server: send up what we are carrying before the connection goes,
		# so quitting does not cost whatever was gathered since the last periodic
		# push. Best effort -- a crash or a pulled cable still falls back to that.
		if _net_mode == "client" and _world != null and _world.player != null:
			_net.push_profile(_world.player.make_profile().duplicate(true))
		get_tree().quit()


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)  # route window-close through _notification
	_settings.load(SETTINGS_PATH)   # absent on a first run, which is not an error
	_setup_environment()
	var world := WorldManager.new()
	world.name = "World"
	add_child(world)
	_world = world
	world.planet_generator = Callable(self, "_generate_planets")
	# Fixed name: an RPC is addressed by NODE PATH, so both machines have to agree
	# on where this node lives before a single message can be sent.
	_net = Net.new()
	_net.name = "Net"
	add_child(_net)
	_net.bind_world(world)
	world.net = _net
	_net.world_ready.connect(_on_world_ready)
	_net.profile_restored.connect(_on_profile_restored)
	# Connected here rather than with the chat box, which does not exist until the
	# world has finished generating -- a good twenty seconds during which the
	# host may well have said something, or announced you joining.
	_net.chat_received.connect(_on_chat_line)
	# A dedicated server never shows a menu: it builds a world, opens a port and
	# waits. Started with:  godot --headless -- --server [--port=N] [--seed=N]
	var ded := _server_args()
	if not ded.is_empty():
		_start_dedicated(int(ded["port"]), int(ded["seed"]), str(ded["world"]))
		return
	_build_menu()
	# --join=host[:port] goes straight into a server, skipping the menu. Handy for
	# a shortcut that always joins the same one.
	var auto := _join_arg()
	if not auto.is_empty() and not _auto_joined:
		_auto_joined = true
		if _net.join(str(auto["host"]), int(auto["port"])):
			_start_world(false, "client")
		else:
			print("[net] ", _net.last_error)


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
	# Co-op. A multiplayer session always uses a FRESH world and never touches the
	# single-player save, so a networking bug cannot damage the world you have.
	_menu_label(" ", 10)
	_menu_button("Host Co-op Game", func(): _start_world(false, "host"))
	_menu_button("Join Co-op Game", func(): _menu_join())
	_menu_button("Quit", func(): get_tree().quit())


## The join screen: somewhere to type the host's address.
func _menu_join() -> void:
	for c in _menu_vb.get_children():
		c.queue_free()
	_menu_label("Join a game", 30)
	_menu_label("the host's IP address on your network", 15, 0.55)
	_join_ip = LineEdit.new()
	_join_ip.text = "127.0.0.1"
	_join_ip.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_join_ip.custom_minimum_size = Vector2(280, 40)
	_menu_vb.add_child(_join_ip)
	_menu_button("Connect", func():
		var ip: String = _join_ip.text.strip_edges()
		if ip.is_empty():
			return
		if not _net.join(ip):
			_menu_label(_net.last_error, 15, 0.9)
			return
		_start_world(false, "client"))
	_menu_button("Back", func(): _menu_populate(false))


## Connected, waiting to be told which world to build. Nothing can be generated
## until the seed arrives -- a client that guessed would render a different
## planet from everyone else.
func _await_host() -> void:
	for c in _menu_vb.get_children():
		c.queue_free()
	_menu_label("Connecting...", 26)
	_menu_label("waiting for the host's world", 15, 0.55)
	_menu_button("Cancel", func():
		_net.leave()
		_menu_populate(false))


func _on_world_ready(seed_value: int, system_index: int, phases: PackedFloat32Array) -> void:
	_net_mode = "client"
	_client_seed = seed_value
	_client_system = system_index
	_client_phases = phases
	_start_world(false, "joined")


# --- settings -----------------------------------------------------------------

func setting(key: String, dflt):
	return _settings.get_value("game", key, dflt)


## Written on every change rather than at shutdown, for the same reason the chat
## log is: a preference that only survives a clean exit is a preference you get
## to set twice.
func set_setting(key: String, value) -> void:
	_settings.set_value("game", key, value)
	_settings.save(SETTINGS_PATH)
	_apply_settings()


func _apply_settings() -> void:
	if _world != null and _world.player != null:
		_world.player.ghost_enabled = bool(setting("placement_ghost", true))


# --- chat ---------------------------------------------------------------------

## Built only for a networked session: there is nobody to talk to in single
## player, and an empty chat box in the corner would just be furniture.
## Old chat fades out rather than sitting on screen forever, but never while you
## are typing -- reading back what was said is most of the reason to open it.
func _fade_chat(delta: float) -> void:
	if _chat_label == null:
		return
	if _chat_entry != null and _chat_entry.visible:
		_chat_label.modulate.a = 1.0
		return
	if _chat_fade > 0.0:
		_chat_fade -= delta
	_chat_label.modulate.a = clampf(_chat_fade, 0.0, 1.0)


func _build_chat() -> void:
	if _chat_layer != null or _net == null or not _net.active:
		return
	_chat_layer = CanvasLayer.new()
	_chat_layer.layer = 9      # under the game menu, over the world
	add_child(_chat_layer)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	# Clear of the hotbar, which sits along the bottom middle.
	box.position = Vector2(16, -230)
	box.custom_minimum_size = Vector2(560, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_layer.add_child(box)
	_chat_label = Label.new()
	_chat_label.add_theme_font_size_override("font_size", 15)
	_chat_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_chat_label.add_theme_constant_override("outline_size", 4)
	_chat_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_chat_label)
	_chat_entry = LineEdit.new()
	_chat_entry.placeholder_text = "say something -- Enter to send, Esc to cancel"
	_chat_entry.custom_minimum_size = Vector2(560, 30)
	_chat_entry.max_length = Net.CHAT_MAX
	_chat_entry.visible = false
	box.add_child(_chat_entry)
	# Whatever arrived while the world was still being built.
	_chat_label.text = "
".join(_chat_lines)
	_chat_fade = CHAT_HOLD


func _on_chat_line(line: String) -> void:
	print("[chat] ", line)   # a headless server's console is its chat window
	_chat_lines.append(line)
	while _chat_lines.size() > CHAT_LINES:
		_chat_lines.remove_at(0)
	if _chat_label == null:
		return   # still loading; _build_chat will show what has piled up
	_chat_label.text = "
".join(_chat_lines)
	_chat_fade = CHAT_HOLD


func _open_chat() -> void:
	if _chat_entry == null:
		return
	_chat_entry.visible = true
	_chat_entry.text = ""
	_chat_entry.grab_focus()
	_chat_fade = CHAT_HOLD
	# The mouse stays captured so you can still look around; what has to stop is
	# the body, which is driven by polling the keyboard directly and would
	# otherwise walk you across the room as you typed.
	if _world != null and _world.player != null:
		_world.player.ui_typing = true


func _close_chat(send: bool) -> void:
	if _chat_entry == null:
		return
	if send:
		_net.say(_chat_entry.text)
	_chat_entry.text = ""
	_chat_entry.visible = false
	_chat_entry.release_focus()
	if _world != null and _world.player != null:
		_world.player.ui_typing = false


## Enter opens chat and sends it; Escape backs out without saying anything.
##
## Handled in _input rather than _unhandled_input so the keys are taken before
## anything else sees them: Escape would otherwise reach the player and open the
## game menu on top of the half-typed message.
func _input(event: InputEvent) -> void:
	if _chat_entry == null or not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k := (event as InputEventKey).keycode
	if _chat_entry.visible:
		if k == KEY_ENTER or k == KEY_KP_ENTER:
			_close_chat(true)
			get_viewport().set_input_as_handled()
		elif k == KEY_ESCAPE:
			_close_chat(false)
			get_viewport().set_input_as_handled()
	elif (k == KEY_ENTER or k == KEY_KP_ENTER) and _game_menu == null:
		_open_chat()
		get_viewport().set_input_as_handled()


## Escape, while playing. Opens if nothing is up, closes if it already is, so
## the same key that opened it by accident puts it away again.
func _toggle_game_menu() -> void:
	if _game_menu != null:
		_close_game_menu()
	else:
		_open_game_menu()


func _open_game_menu() -> void:
	if _world == null or _world.player == null:
		return
	_game_menu = CanvasLayer.new()
	_game_menu.layer = 12
	add_child(_game_menu)
	# Dimmed rather than hidden: it stays clear that the world is still there and
	# still running behind it.
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.08, 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_menu.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_menu.add_child(center)
	_game_menu_vb = VBoxContainer.new()
	_game_menu_vb.add_theme_constant_override("separation", 14)
	_game_menu_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_game_menu_vb)
	_populate_game_menu()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_world.player.menu_open = true


func _menu_page(title_text: String) -> VBoxContainer:
	for c in _game_menu_vb.get_children():
		_game_menu_vb.remove_child(c)
		c.queue_free()
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	_game_menu_vb.add_child(title)
	return _game_menu_vb


func _populate_game_menu() -> void:
	var vb := _menu_page("Game Menu")
	# Continue FIRST, because the commonest reason to be looking at this screen
	# is having pressed Escape by mistake.
	_game_menu_button(vb, "Continue", _close_game_menu)
	_game_menu_button(vb, "Settings", _populate_settings_menu)
	_game_menu_button(vb, "Save and Exit to Main Menu" if _net_mode == "single"
		else "Leave Game", _exit_to_main_menu)


func _populate_settings_menu() -> void:
	var vb := _menu_page("Settings")
	_game_menu_check(vb, "Placement preview",
		"the ghost block showing where a block would go",
		"placement_ghost", true)
	_game_menu_button(vb, "Back", _populate_game_menu)


## A labelled on/off row. Takes effect and is written to disk the moment it is
## clicked -- there is no OK button to forget to press.
func _game_menu_check(vb: VBoxContainer, text: String, hint: String,
		key: String, dflt: bool) -> void:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = bool(setting(key, dflt))
	c.custom_minimum_size = Vector2(280, 40)
	c.toggled.connect(func(on: bool): set_setting(key, on))
	vb.add_child(c)
	var l := Label.new()
	l.text = hint
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 13)
	l.modulate = Color(1, 1, 1, 0.5)
	vb.add_child(l)


func _game_menu_button(vb: VBoxContainer, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 44)
	b.pressed.connect(cb)
	vb.add_child(b)


func _close_game_menu() -> void:
	if _game_menu != null:
		_game_menu.queue_free()
		_game_menu = null
	if _world != null and _world.player != null:
		_world.player.menu_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Back to the title screen. Reloads the scene rather than unpicking the world by
## hand: planets, chunks, ships, stations, creatures and the network session all
## go at once, and none of them can be left half torn down.
func _exit_to_main_menu() -> void:
	if _net_mode == "single" and _world != null and _world.player != null:
		_world.save_game()
	elif _net_mode == "client" and _world != null and _world.player != null:
		# Same courtesy the window-close path does: hand the server what we are
		# carrying before the connection goes.
		_net.push_profile(_world.player.make_profile().duplicate(true))
	if _net != null:
		_net.leave()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


func _delete_save() -> void:
	DirAccess.remove_absolute(WorldManager.SAVE_PATH)
	DirAccess.remove_absolute(WorldManager.SAVE_BAK)


## --join=ADDRESS or --join=ADDRESS:PORT, if it was given.
func _join_arg() -> Dictionary:
	var argv: Array = []
	argv.append_array(OS.get_cmdline_user_args())
	argv.append_array(OS.get_cmdline_args())
	for a in argv:
		var arg := str(a)
		if not arg.begins_with("--join="):
			continue
		var spec := arg.substr(7).strip_edges()
		if spec == "":
			continue
		# Split on the LAST colon so an IPv6 literal keeps its own.
		var i := spec.rfind(":")
		if i > 0 and spec.substr(i + 1).is_valid_int():
			return {"host": spec.substr(0, i), "port": int(spec.substr(i + 1))}
		return {"host": spec, "port": Net.PORT}
	return {}


## Command-line options for running as a dedicated server.
##
## Godot swallows arguments it does not recognise, so the game's own options are
## meant to go after a bare "--". Both forms are read anyway, because getting
## that wrong otherwise launches the ordinary game and looks like a crash.
func _server_args() -> Dictionary:
	var argv: Array = []
	argv.append_array(OS.get_cmdline_user_args())
	argv.append_array(OS.get_cmdline_args())
	var wanted := false
	var port := Net.PORT
	var seed_value := -1
	# Named so one machine can run more than one world, and so the file is never
	# the single-player save (see WorldManager.save_slot).
	var slot := "server_world"
	for a in argv:
		var arg := str(a)
		if arg == "--server" or arg == "--dedicated":
			wanted = true
		elif arg.begins_with("--port="):
			port = int(arg.substr(7))
		elif arg.begins_with("--seed="):
			seed_value = int(arg.substr(7))
		elif arg.begins_with("--world="):
			slot = arg.substr(8).strip_edges()
	if not wanted:
		return {}
	if slot == "":
		slot = "server_world"
	return {"port": port, "seed": seed_value, "world": slot}


## Build the world, open the port, and do nothing else.
##
## There is no player here, and that is what makes it cheap: WorldManager only
## streams and meshes chunks around a player, so with none there is no terrain
## work at all. The server holds the seed and the authoritative record of every
## edit, and relays. Everything a client sees, it generates for itself.
func _start_dedicated(port: int, seed_value: int, slot: String = "server_world") -> void:
	_net_mode = "server"
	var world := _world
	world.save_slot = slot
	# Resuming beats generating: an explicit --seed still wins, but otherwise a
	# server that has been run before comes back to the world people built in it.
	# The seed has to be settled BEFORE the planets are made -- terrain is a pure
	# function of it, so generating from a fresh seed and then loading the old
	# edits would drop everyone's buildings onto unrecognisable ground.
	var resumed := false
	var wseed := seed_value
	if wseed < 0 and world.has_save():
		wseed = world.saved_world_seed()
		resumed = wseed >= 0
	if wseed < 0:
		wseed = _rand_seed()
	world.world_seed = wseed
	Chunk.set_texture_seed(wseed)

	var galaxy := Galaxy.new()
	galaxy.generate(wseed)
	world.galaxy = galaxy
	world.current_system_index = galaxy.home_system_index()
	if resumed:
		var si := world.saved_system_index()
		if si >= 0 and si < galaxy.systems.size():
			world.current_system_index = si
	var sysdef: Dictionary = galaxy.systems[world.current_system_index]
	_generate_planets(world, sysdef)
	if not resumed and not world.planets.is_empty():
		world.planets[0].day_phase = Planet.MORNING_PHASE
	# Loaded only now: load_game applies edits ONTO the planets, so they have to
	# exist first.
	if resumed and world.load_game():
		var nedits := 0
		var nparts := 0
		for pl in world.planets:
			for cc in pl._edits_by_chunk:
				nedits += (pl._edits_by_chunk[cc] as Dictionary).size()
			for cc in pl._parts_by_chunk:
				nparts += (pl._parts_by_chunk[cc] as Dictionary).size()
		print("[server] resumed world '%s': %d block changes, %d part cells, "
			% [slot, nedits, nparts] + "%d player inventories" % _net.profiles.size())
	elif world.has_save():
		print("[server] NOTE: '%s' has a save but --seed was given, so it was not "
			% slot + "loaded. Drop --seed to resume it; keeping it will overwrite it.")
	_net.world_built()

	if not _net.host(wseed, world.current_system_index, port):
		print("[server] FAILED: ", _net.last_error)
		get_tree().quit(1)
		return
	_net.roster_changed.connect(_on_server_roster)
	print("[server] listening on port %d" % port)
	print("[server] world seed %d -- pass --seed=%d to reopen this same world" % [wseed, wseed])
	print("[server] system %s, %d planets, home world %s" % [
		sysdef["name"], world.planets.size(), world.planets[0].planet_name])
	_net.chat_log_path = "user://%s_chat_logs.txt" % slot
	print("[server] chat log at %s" % ProjectSettings.globalize_path(_net.chat_log_path))
	print("[server] saving to %s every %d seconds" % [
		ProjectSettings.globalize_path(world.save_path()), int(SERVER_SAVE_EVERY)])
	print("[server] ready")
	var t := Timer.new()
	t.wait_time = SERVER_SAVE_EVERY
	t.timeout.connect(_server_autosave)
	add_child(t)
	t.start()


## The host knew us and sent back what we were carrying. Arrives shortly after
## joining, so it lands on a freshly spawned empty inventory.
func _on_profile_restored(prof: Dictionary) -> void:
	if _world == null or _world.player == null:
		return
	if prof.is_empty():
		print("[net] host has no inventory on record for you -- starting fresh")
	else:
		_world.player.apply_profile(prof)
		print("[net] restored your inventory from the host")
	_profile_hash = _world.player.make_profile().hash()
	_profile_ready = true


func _on_server_roster() -> void:
	print("[server] players connected: %d" % _net.peers.size())
	# Somebody just arrived or left. Leaving is the moment most worth capturing:
	# it is usually the end of a building session, and it costs nothing when
	# nothing changed.
	_server_autosave()


func _server_autosave() -> void:
	if _net_mode != "server" or _world == null:
		return
	if not _world.save_game():
		print("[server] WARNING: save failed")


## Last chance to write the world down, on the way out through the game's own
## exit path. Treat it as a bonus rather than a guarantee: a signal may end the
## process before the tree is ever torn down, which is what the periodic save
## above is really for.
func _exit_tree() -> void:
	if _net_mode == "server" and _world != null:
		_world.save_game()
		print("[server] saved on shutdown")


func _rand_seed() -> int:
	var r := RandomNumberGenerator.new()
	r.randomize()
	return int(r.randi() & 0x7fffffff)


## `mode` is "single", "host" or "client". A client cannot choose its own seed:
## it has to build the same world the host already has, so it waits on the wire
## for one (see _on_world_ready) instead of generating anything.
func _start_world(load_existing: bool, mode: String = "single") -> void:
	if mode == "client":
		_await_host()
		return
	_net_mode = "client" if mode == "joined" else mode
	if _menu_layer != null:
		_menu_layer.queue_free()
		_menu_layer = null
	_show_loading_screen()

	var world := _world
	var wseed := _client_seed if mode == "joined" 		else (world.saved_world_seed() if load_existing else _rand_seed())
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
	if _net_mode == "host" and not _net.host(wseed, world.current_system_index):
		_net_mode = "single"
		push_warning("could not host: " + _net.last_error)
	var sysdef: Dictionary = galaxy.systems[world.current_system_index]
	print("[galaxy] %d systems generated -- starting in %s (%s, %d planets)" % [
		galaxy.systems.size(), sysdef["name"], Galaxy.civ_name(sysdef["civ_tier"]), sysdef["planet_count"]])
	_generate_planets(world, sysdef)
	if mode == "joined":
		# Someone else's world, already part way through its day: take their clock
		# rather than starting our own (see Net.world_info).
		for i in mini(_client_phases.size(), world.planets.size()):
			world.planets[i].day_phase = _client_phases[i]
	elif not load_existing and not world.planets.is_empty():
		# A new world opens in the morning, so the first thing you do is a full
		# day's worth rather than twenty minutes before dark.
		world.planets[0].day_phase = Planet.MORNING_PHASE
	# The planets exist from here, so anything the network buffered while they
	# were being built can be applied now.
	_net.world_built()
	# ...and now there is somewhere to put an inventory, tell the host who we are
	# so it can hand back whatever we left with.
	_net.say_hello()
	_build_chat()

	# player: drop in just above dry land on the home world
	var home: Planet = world.planets[0]
	var player := Player.new()
	player.name = "Player"
	player.world = world
	player.menu_requested.connect(_toggle_game_menu)
	player.ghost_enabled = bool(setting("placement_ghost", true))
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

## Twenty updates a second. More than that is more than anyone can see on a body
## that is being smoothed anyway, and position is the cheapest thing to overspend
## bandwidth on.
const NET_RATE := 1.0 / 20.0

func _sync_players(delta: float) -> void:
	if _net == null or not _net.active or _world == null or _world.player == null:
		return
	_net_tick -= delta
	if _net_tick <= 0.0:
		_net_tick = NET_RATE
		# the player's real forward direction, not a yaw angle -- see Net.player_state
		_net.broadcast_state(_world.player.global_position,
			-_world.player.global_transform.basis.z, _world.player.action_state())
	# Send the inventory up only when it has actually changed. Comparing hashes
	# rather than dictionaries because Dictionary == is identity, not contents:
	# the live inventory IS the same object every time, so it would always
	# compare equal and nothing would ever be sent.
	_profile_tick -= delta
	if _profile_ready and _profile_tick <= 0.0:
		_profile_tick = PROFILE_RATE
		var prof: Dictionary = _world.player.make_profile()
		var h := prof.hash()
		if h != _profile_hash:
			_profile_hash = h
			_net.push_profile(prof.duplicate(true))
	for id in _net.peers:
		var st: Dictionary = _net.peers[id]
		if not st.has("pos"):
			continue
		var av: RemotePlayer = _avatars.get(id)
		if av == null or not is_instance_valid(av):
			av = RemotePlayer.new()
			add_child(av)
			av.setup(int(id))
			_avatars[id] = av
		var pos: Vector3 = st["pos"]
		var pl: Planet = _world.nearest_planet(pos)
		# SNAPPED to an axis, because that is how a player stands: Player._walk is
		# given -_snap_to_axis(gravity), not gravity itself. The raw direction away
		# from the planet's centre only agrees with it in the middle of a cube
		# face, and drifts from it all the way to the edges -- which is why other
		# players stood very slightly tilted, and more so the further they walked
		# from the middle of a face.
		var up: Vector3 = pl._axis_of(pos - pl.global_position) if pl != null else Vector3.UP
		av.remote_state(pos, st.get("facing", Vector3.FORWARD), up, int(st.get("action", 0)))
	for id in _avatars.keys():
		if not _net.peers.has(id):
			var gone: RemotePlayer = _avatars[id]
			if is_instance_valid(gone):
				gone.queue_free()
			_avatars.erase(id)


func _process(delta: float) -> void:
	_sync_players(delta)
	_fade_chat(delta)
	# Crops grow on every world at once, not just the one underfoot: a field you
	# left behind should have come on while you were away, which is most of what
	# makes planting somewhere worth doing.
	#
	# BEFORE the guard below, which wants a player and a sky. A dedicated server
	# has neither, and it is the one machine whose clock everybody else is
	# waiting on -- putting this after that return meant a field on a server
	# would never grow at all.
	if _world != null:
		_world.tick_crops(delta)
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
