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
	# --- dusty worlds ---------------------------------------------------------
	# The regolith world was the only one of its kind and the best of the lot to
	# look at, so it has company now: the same dust under different skies. What
	# separates them is what a player can actually feel -- air or none, warm or
	# cold, and how hard the ground is trying to kill them.
	#
	# A DUST MOON: airless, freezing, and nothing but dust. The moon you land on
	# for its ores and leave again.
	{"top": Blocks.REGOLITH, "sub": Blocks.REGOLITH, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": false, "atmo_color": Color(0.72, 0.68, 0.62), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.0, "moon": true, "hazard": "cold", "hdps": 2.5},
	# An ASH PLAIN: dust with a sky over it, and that sky is the problem.
	{"top": Blocks.REGOLITH, "sub": Blocks.ROCK, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.55, 0.38, 0.34), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.05, "moon": false, "hazard": "heat", "hdps": 3.2},
	# RUST BARRENS: dust you can stand on without a suit. Warm, dry, harmless --
	# the desert you would actually build a base on.
	{"top": Blocks.REGOLITH, "sub": Blocks.DIRT, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.86, 0.52, 0.30), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.1, "moon": false, "hazard": "heat", "hdps": 1.2},
	# A CRYSTAL DESERT: dust with something growing out of it that is not alive.
	{"top": Blocks.CRYSTAL, "sub": Blocks.REGOLITH, "rock": Blocks.ROCK, "core": Blocks.CRYSTAL,
		"atmo": true, "atmo_color": Color(0.72, 0.62, 0.92), "water": "none", "wmin": 0.0, "wmax": 0.0,
		"tmin": 0.0, "tmax": 0.0, "moon": false, "hazard": "none", "hdps": 0.0},
	# --- and two more worlds worth walking around -----------------------------
	# TUNDRA: cold, but a cold you can live in, and the only frozen world with
	# trees on it.
	{"top": Blocks.SNOW, "sub": Blocks.DIRT, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.70, 0.82, 0.92), "water": "liquid", "wmin": 0.1, "wmax": 0.3,
		"tmin": 0.1, "tmax": 0.3, "moon": false, "hazard": "cold", "hdps": 1.5},
	# ARCHIPELAGO: the temperate world, mostly drowned. Islands to find rather
	# than a continent to walk across.
	{"top": Blocks.GRASS, "sub": Blocks.DIRT, "rock": Blocks.ROCK, "core": Blocks.CORE,
		"atmo": true, "atmo_color": Color(0.40, 0.72, 0.95), "water": "liquid", "wmin": 0.72, "wmax": 0.92,
		"tmin": 0.35, "tmax": 0.6, "moon": false, "hazard": "none", "hdps": 0.0},
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
var _menu_skin_corner: MarginContainer
var _skin_editor: SkinEditor
var _skin_names: Array = []
var _skin_index := 0
var _skin_row: HBoxContainer
var _skin_scroll: ScrollContainer
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
## Where preferences live. A var rather than a const so a test can point it
## somewhere else: a test that drives the real settings menu has already written
## a render distance and a rebound jump key into a player's own preferences
## twice, and "remember to undo it" is not a mechanism.
var settings_path := "user://settings.cfg"
var _settings := ConfigFile.new()
var _fps_label: Label
var _game_menu_bg: ColorRect
## The action waiting for a key, while the controls page is listening.
var _awaiting_bind := ""
var _autosave_t := 0.0
var _bind_button: Button

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


func _still_loaded(p: Planet, v: Vector3i, rd: int) -> float:
	# Pretend every wanted chunk arrived, then time the standing-still tick.
	for cc in p._wanted:
		p.loaded_chunks[cc] = null
	var total := 0
	for i in 20:
		p._stream_last_ms = 0
		var t := Time.get_ticks_usec()
		p.stream(v, rd)
		total += Time.get_ticks_usec() - t
	p.loaded_chunks.clear()
	return total / 20000.0


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)  # route window-close through _notification
	_settings.load(settings_path)   # absent on a first run, which is not an error
	var fps_layer := CanvasLayer.new()
	fps_layer.layer = 8
	add_child(fps_layer)
	_fps_label = Label.new()
	_fps_label.position = Vector2(16, 96)
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_fps_label.add_theme_constant_override("outline_size", 4)
	_fps_label.visible = false
	fps_layer.add_child(_fps_label)
	_apply_settings()
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
	# Who you are, standing in the corner of the room you choose a world in. Out
	# here rather than in a settings page because a skin is not a setting -- it
	# is the character you are about to play as -- and in the corner rather than
	# in the button stack because it is not a thing you DO, it is a thing that
	# is true, and it should be visible whichever page you are on.
	_menu_skin_corner = MarginContainer.new()
	_menu_skin_corner.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_menu_skin_corner.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_menu_skin_corner.add_theme_constant_override("margin_left", 28)
	_menu_skin_corner.add_theme_constant_override("margin_bottom", 28)
	_menu_layer.add_child(_menu_skin_corner)
	_menu_populate(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Hover and press, for every button in the game.
##
## It lives in one place so a button added later is audible because it is a
## button, not because someone remembered. The sound is connected BEFORE the
## real callback for a reason: half of these callbacks rebuild the page they
## are on, which frees the button mid-signal, and a connection on a freed
## object does not get its turn.
func _wire_button(b: BaseButton, sound: String = "ui_click") -> void:
	b.mouse_entered.connect(func(): Audio.ui("ui_hover"))
	if sound != "":
		b.pressed.connect(func(): Audio.ui(sound))


func _menu_button(text: String, cb: Callable, sound: String = "ui_click") -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 44)
	_wire_button(b, sound)
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
		_menu_button("Cancel", func(): _menu_populate(false), "ui_back")
		return
	_menu_label("SPACECRAFT", 52)
	_menu_label("a voxel game in space", 18, 0.55)
	_menu_label(" ", 14)
	_refresh_menu_skin(true)
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


# --- skins --------------------------------------------------------------------

## Which skin is worn. Empty means the built-in one.
func skin_name() -> String:
	return str(setting("skin", ""))


## The image currently being worn, falling back to the built-in default -- which
## is also what a missing or deleted file gets you, rather than an error.
func current_skin_image() -> Image:
	var n := skin_name()
	if n != "":
		var img = PlayerSkin.load_skin(n)
		if img != null:
			return img
	return PlayerSkin.default_image(DEFAULT_SKIN_HUE)


## The hue the built-in skin is built from. Fixed rather than per-peer here: out
## on the menu there is no peer id yet, and a character that changed colour on
## joining would not be the one you picked.
const DEFAULT_SKIN_HUE := 0.55


## A character standing in the middle of a box.
##
## The portrait is a TextureRect laid over the button rather than the button's
## own icon. Button draws an expanded icon hard against one corner of its
## content box, so every character sat off to one side of the panel behind it
## with a stripe of empty grey down the other -- which is not a thing you can
## nudge back into place with padding, because the size it picks depends on the
## box. A rect that keeps its aspect and centres itself is symmetric by
## construction, at any size either of these two places asks for.
func _portrait_button(image: Image, box: Vector2) -> Button:
	var b := Button.new()
	b.custom_minimum_size = box
	b.clip_contents = true
	var tr := TextureRect.new()
	# Scaled by whole pixels first, and drawn with a nearest filter, or a
	# 16-texel-wide character stretched to fit is a smudge.
	tr.texture = PlayerSkin.portrait_texture(image, 4)
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.offset_left = 7
	tr.offset_top = 7
	tr.offset_right = -7
	tr.offset_bottom = -7
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(tr)
	return b


## The figure in the corner: a picture of who you will be, that opens the
## wardrobe when clicked. Rebuilt rather than updated, because it is four nodes
## and the alternative is four references to keep in step.
func _refresh_menu_skin(shown: bool) -> void:
	if _menu_skin_corner == null:
		return
	for c in _menu_skin_corner.get_children():
		c.queue_free()
	_menu_skin_corner.visible = shown
	if not shown:
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_menu_skin_corner.add_child(row)
	var b := _portrait_button(current_skin_image(), Vector2(76, 108))
	b.tooltip_text = "Choose or edit your character"
	b.pressed.connect(_menu_skins)
	row.add_child(b)
	var side := VBoxContainer.new()
	side.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(side)
	var who := Label.new()
	who.text = skin_name() if skin_name() != "" else "Default"
	who.add_theme_font_size_override("font_size", 17)
	side.add_child(who)
	var hint := Label.new()
	hint.text = "click to change"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.5)
	side.add_child(hint)


## The wardrobe: one row of characters you page through, and what to do with
## the one you have landed on.
##
## A row rather than a grid because the list is short and the choice is one
## thing, not a layout: arrows step through it, and everything underneath acts
## on whichever is in front of you.
func _menu_skins() -> void:
	for c in _menu_vb.get_children():
		c.queue_free()
	_refresh_menu_skin(false)
	# "" is the built-in one, always first and never deletable.
	_skin_names = [""]
	for n in PlayerSkin.list_skins():
		_skin_names.append(n)
	_skin_index = clampi(_skin_names.find(skin_name()), 0, _skin_names.size() - 1)

	_menu_label("Your character", 30)
	_menu_label("this is who you play as -- it travels with you into a game", 14, 0.55)
	_menu_label(" ", 6)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_theme_constant_override("separation", 10)
	_menu_vb.add_child(row)
	var left := Button.new()
	left.text = "<"
	left.custom_minimum_size = Vector2(40, 132)
	left.pressed.connect(func(): _step_skin(-1))
	row.add_child(left)
	_skin_scroll = ScrollContainer.new()
	_skin_scroll.custom_minimum_size = Vector2(468, 138)
	_skin_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(_skin_scroll)
	_skin_row = HBoxContainer.new()
	_skin_row.add_theme_constant_override("separation", 8)
	_skin_scroll.add_child(_skin_row)
	for i in _skin_names.size():
		var n: String = _skin_names[i]
		var img = PlayerSkin.default_image(DEFAULT_SKIN_HUE) if n == "" else PlayerSkin.load_skin(n)
		if img != null:
			_skin_tile(_skin_row, i, n, img)
	_new_skin_tile(_skin_row)
	var right := Button.new()
	right.text = ">"
	right.custom_minimum_size = Vector2(40, 132)
	right.pressed.connect(func(): _step_skin(1))
	row.add_child(right)
	_menu_label(" ", 8)

	_menu_button("Edit", func():
		# The built-in one is everybody's starting point and stays as it is;
		# editing it means editing a copy, which is what you wanted anyway.
		if _picked_skin() == "":
			_menu_new_skin()
		else:
			set_setting("skin", _picked_skin())
		_open_skin_editor())
	_menu_button("Select", func():
		# Wearing it is the decision this screen exists for, so it is also the
		# way out of it.
		set_setting("skin", _picked_skin())
		_menu_populate(false))
	if _picked_skin() != "":
		_menu_button("Delete", func():
			PlayerSkin.delete_skin(_picked_skin())
			if skin_name() == _picked_skin():
				set_setting("skin", "")
			_menu_skins(), "ui_back")
	_menu_button("Back", func(): _menu_populate(false), "ui_back")
	_highlight_skin()


func _picked_skin() -> String:
	if _skin_index < 0 or _skin_index >= _skin_names.size():
		return ""
	return str(_skin_names[_skin_index])


## Move along the row, and bring what you moved to into view.
func _step_skin(d: int) -> void:
	if _skin_names.is_empty():
		return
	_skin_index = posmod(_skin_index + d, _skin_names.size())
	_highlight_skin()


func _highlight_skin() -> void:
	if _skin_row == null:
		return
	# The plus sits in the row but is not one of the characters, so it keeps its
	# own brightness instead of being dimmed as "not the one you are on".
	for i in mini(_skin_names.size(), _skin_row.get_child_count()):
		var tile: Control = _skin_row.get_child(i)
		tile.modulate = Color(1, 1, 1, 1.0 if i == _skin_index else 0.4)
	if _skin_index < _skin_row.get_child_count() and _skin_scroll != null:
		_skin_scroll.ensure_control_visible(_skin_row.get_child(_skin_index))


## The last thing in the row: one more of these, please.
##
## A tile rather than a button underneath, because making a new character is the
## same KIND of act as choosing one -- so it belongs among the characters, at
## the end, which is where your eye already is once you have looked at them all
## and not found the one you wanted.
func _new_skin_tile(row: HBoxContainer) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)
	var b := Button.new()
	b.text = "+"
	b.add_theme_font_size_override("font_size", 40)
	b.custom_minimum_size = Vector2(78, 108)
	b.tooltip_text = "Make another character"
	b.modulate = Color(1, 1, 1, 0.7)
	# Straight into the editor: the only reason to make one is to paint it.
	b.pressed.connect(func():
		_menu_new_skin()
		_open_skin_editor())
	col.add_child(b)
	var cap := Label.new()
	cap.text = "New"
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 11)
	cap.modulate = Color(1, 1, 1, 0.6)
	col.add_child(cap)


## One character in the row. Clicking one is the same as arrowing to it: the
## arrows are for when your hand is already on them, not the only way through.
func _skin_tile(row: HBoxContainer, index: int, name: String, img: Image) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)
	var b := _portrait_button(img, Vector2(78, 108))
	b.tooltip_text = name if name != "" else "The built-in character"
	b.pressed.connect(func():
		_skin_index = index
		_highlight_skin())
	col.add_child(b)
	var cap := Label.new()
	# Which one you are WEARING has to stay visible while you page past others,
	# or you lose track of what you will be if you just leave.
	cap.text = ("%s  (worn)" % [name if name != "" else "Default"]
		if name == skin_name() else (name if name != "" else "Default"))
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 11)
	cap.modulate = Color(1, 1, 1, 0.75)
	col.add_child(cap)


## The editor, over the whole screen. It is a room you go into rather than a
## panel you open: painting wants the space, and there is nothing else on the
## menu you would want to see at the same time.
func _open_skin_editor() -> void:
	if skin_name() == "" or _skin_editor != null:
		return
	# The menu goes away rather than being covered. Relying on one full-screen
	# panel to sit over another is how you end up with a stray button poking
	# through a corner of it.
	_menu_vb.get_parent().visible = false
	_refresh_menu_skin(false)
	_skin_editor = SkinEditor.new()
	_menu_layer.add_child(_skin_editor)
	_skin_editor.setup(skin_name(), current_skin_image())
	_skin_editor.closed.connect(func(saved: bool):
		if saved:
			PlayerSkin.save_skin(skin_name(), _skin_editor.img)
		_skin_editor.queue_free()
		_skin_editor = null
		_menu_vb.get_parent().visible = true
		_menu_skins())


## A new character to work on. It starts as a copy of whatever is being worn, so
## "new" means "another one like this" rather than a blank figure -- editing
## something is a much easier start than painting one from nothing.
func _menu_new_skin() -> void:
	var name := PlayerSkin.free_name("Character")
	var img := current_skin_image()
	# A different hue from the one it was copied from, so a new character is
	# visibly a different character before a single pixel has been painted.
	if skin_name() == "":
		img = PlayerSkin.default_image(randf())
	if PlayerSkin.save_skin(name, img):
		set_setting("skin", name)
	_menu_skins()


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
			Audio.ui("ui_deny")
			_menu_label(_net.last_error, 15, 0.9)
			return
		_start_world(false, "client"))
	_menu_button("Back", func(): _menu_populate(false), "ui_back")


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
	_settings.save(settings_path)
	_apply_settings()


## Sound belongs to the Audio autoload, which owns the buses because they have
## to exist before anything can be assigned to them. These two are kept as the
## menu's way in so the settings code reads the same as it did.
func _ensure_audio_buses() -> void:
	Audio.ensure_buses()


func _set_bus_volume(bus: String, linear: float) -> void:
	Audio.set_bus_volume(bus, linear)


func _apply_settings() -> void:
	# Window settings apply whether or not a world is loaded; the rest need a
	# player to apply to, and are applied again when one is made.
	# Windowed / borderless / exclusive, and the size only means anything in the
	# first of those.
	match int(setting("window_mode", 0)):
		1:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var r: Vector2i = RESOLUTIONS[clampi(int(setting("resolution", 3)),
				0, RESOLUTIONS.size() - 1)]
			# Never bigger than the screen it has to fit on.
			var screen := DisplayServer.screen_get_size()
			r = Vector2i(mini(r.x, screen.x), mini(r.y, screen.y))
			DisplayServer.window_set_size(r)
			DisplayServer.window_set_position((screen - r) / 2)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED
		if bool(setting("vsync", true)) else DisplayServer.VSYNC_DISABLED)
	if _fps_label != null:
		_fps_label.visible = bool(setting("show_fps", false))
	_ensure_audio_buses()
	_set_bus_volume("Master", float(setting("vol_master", 0.8)))
	_set_bus_volume("Music", float(setting("vol_music", 0.7)))
	_set_bus_volume("Effects", float(setting("vol_sfx", 0.9)))
	if _world != null:
		_world.render_distance = int(setting("render_distance",
			WorldManager.RENDER_DISTANCE_DEFAULT))
	if _world != null and _world.player != null:
		var pl = _world.player
		pl.ghost_enabled = bool(setting("placement_ghost", true))
		pl.look_sensitivity = float(setting("sensitivity", 1.0))
		pl.invert_look = bool(setting("invert_y", false))
		pl.set_fov(float(setting("fov", 75.0)))
		var b := Player.DEFAULT_BINDS.duplicate()
		for a in b:
			b[a] = int(setting("bind_" + a, int(Player.DEFAULT_BINDS[a])))
		pl.binds = b
		pl.show_look_names = bool(setting("show_names", true))


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


## Built whether or not anyone else is listening. It was multiplayer-only, on
## the reasonable grounds that talking to nobody is not a feature -- but the
## same box is now where commands are typed, so in single player it is the
## console and there is nothing to talk to.
func _build_chat() -> void:
	if _chat_layer != null:
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
	_chat_entry.placeholder_text = ("say something -- Enter to send, Esc to cancel"
		if _net != null and _net.active
		else "type a command -- /help, Esc to cancel")
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
		var line := _chat_entry.text.strip_edges()
		# A line starting with / is for this machine, not for the room.
		if line.begins_with("/"):
			_run_command(line)
		elif line != "":
			if _net != null and _net.active:
				_net.say(line)
			else:
				# Nobody to say it to. Say so, rather than eating the line and
				# leaving it looking like chat is broken.
				_on_chat_line("no one else is here -- try /help")
	_chat_entry.text = ""
	_chat_entry.visible = false
	_chat_entry.release_focus()
	if _world != null and _world.player != null:
		_world.player.ui_typing = false


# --- chat commands -----------------------------------------------------------
#
# Testing aids, not cheats meant for play. They exist because the alternative is
# editing the starting inventory, and the starting inventory says "you start
# with NOTHING, everything comes out of the world" -- which is a rule worth
# keeping true even while something is being tried out.
#
# Local only: nothing here is sent to anyone else, and on a server it changes
# only the inventory of whoever typed it.
const GIVEABLE := {
	"wood": Blocks.WOOD, "plank": Blocks.PLANK, "rock": Blocks.ROCK,
	"metal": Blocks.METAL, "glass": Blocks.GLASS,
	"cloth": Blocks.CLOTH, "leather": Blocks.LEATHER, "fibre": Blocks.FIBRE,
	"hide": Blocks.HIDE, "bone": Blocks.BONE, "bonemeal": Blocks.BONEMEAL,
	"torch": Blocks.TORCH, "hoe": Blocks.HOE, "seeds": Blocks.SEEDS,
	"crop": Blocks.CROP, "meat": Blocks.RAW_MEAT,
}


func _run_command(line: String) -> void:
	var parts := line.substr(1).split(" ", false)
	if parts.is_empty():
		return
	var cmd := String(parts[0]).to_lower()
	var pl = _world.player if _world != null else null
	# Unknown first: a word that is not a command is not a command whether or
	# not there is a world, and hearing "not in a world yet" for a typo sends
	# you looking in the wrong place.
	if not cmd in ["give", "bed", "time", "perf", "help"]:
		_on_chat_line("unknown command: /" + cmd + "  (try /help)")
		return
	# The rest need somewhere to put things. Saying so beats returning quietly,
	# which looks exactly like a broken command.
	if pl == null and cmd != "help":
		_on_chat_line("not in a world yet")
		return
	match cmd:
		"give":
			if parts.size() < 2:
				_on_chat_line("give what? try: " + ", ".join(GIVEABLE.keys()))
				return
			var what := String(parts[1]).to_lower()
			if not GIVEABLE.has(what):
				_on_chat_line("no such item: " + what)
				return
			var n := int(parts[2]) if parts.size() > 2 else 1
			n = clampi(n, 1, 999)
			pl._add_item(int(GIVEABLE[what]), n)
			pl._refresh_slots()
			_on_chat_line("gave you %d %s" % [n, Blocks.name_of(int(GIVEABLE[what]))])
		"bed":
			# The one that prompted all this: exactly what a Bed pattern costs,
			# which is a block of wood and a block of soft stock, in eighths.
			pl._add_item(Blocks.WOOD, 4)
			pl._add_item(Blocks.CLOTH, 4)
			pl._refresh_slots()
			_on_chat_line("gave you 4 Wood and 4 Cloth -- a bed takes 4 eighths of wood and 8 of cloth, so the cloth is what runs out first")
		"time":
			if _world == null or _world.planets.is_empty():
				_on_chat_line("no planets yet")
				return
			var p: Planet = _world.nearest_planet(pl.global_position)
			var when := String(parts[1]).to_lower() if parts.size() > 1 else ""
			match when:
				"day":
					p.day_phase = Planet.MORNING_PHASE
				"night":
					p.day_phase = 0.75
				"":
					# Bare /time reports rather than sets. It used to quietly
					# mean morning, which also meant a typo meant morning.
					_on_chat_line("%s: %s (phase %.2f)" % [p.planet_name,
						"night" if p.is_night() else "day", p.day_phase])
					return
				_:
					_on_chat_line("/time day  or  /time night")
					return
			_on_chat_line("set %s to %s" % [p.planet_name, when])
		"perf":
			for l in WorldManager.perf_report():
				_on_chat_line(l)
		"help":
			_on_chat_line("/give <item> [n]  ·  /bed  ·  /time [day|night]  ·  /perf")
		_:
			pass   # unreachable: the list above is the same list


## Enter opens chat and sends it; Escape backs out without saying anything.
##
## Handled in _input rather than _unhandled_input so the keys are taken before
## anything else sees them: Escape would otherwise reach the player and open the
## game menu on top of the half-typed message.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Rebinding swallows the next key, whatever it is -- that is the whole point
	# of the state. Escape backs out, because a key you cannot cancel choosing
	# is a trap.
	if _awaiting_bind != "":
		var code := (event as InputEventKey).keycode
		# Backing out with Escape is a cancel, and does not get the chime that
		# says a key was taken.
		Audio.ui("ui_close" if code == KEY_ESCAPE else "ui_accept")
		if code != KEY_ESCAPE:
			set_setting("bind_" + _awaiting_bind, int(code))
		_awaiting_bind = ""
		_bind_button = null
		_populate_controls_menu()
		get_viewport().set_input_as_handled()
		return
	if _chat_entry == null:
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
	# Dimmed rather than hidden on the front page: it stays clear that the world
	# is still there and still running behind it. The settings pages go opaque --
	# see _menu_page -- because reading a list of settings over the top of the
	# HUD means reading two things at once.
	_game_menu_bg = ColorRect.new()
	var bg := _game_menu_bg
	bg.color = MENU_BG_DIM
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_menu.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_menu.add_child(center)
	_game_menu_vb = VBoxContainer.new()
	_game_menu_vb.add_theme_constant_override("separation", 6)
	_game_menu_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_game_menu_vb)
	_populate_game_menu()
	Audio.ui("ui_open")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_world.player.menu_open = true


const MENU_BG_DIM := Color(0.03, 0.04, 0.08, 0.72)
const MENU_BG_SOLID := Color(0.04, 0.05, 0.09, 1.0)


## `see_through` is for the front page only. Anything with things to read on it
## covers the HUD completely: a settings row over the top of a hotbar label is
## two things competing for the same few pixels.
func _menu_page(title_text: String, see_through: bool = false) -> VBoxContainer:
	if _game_menu_bg != null:
		_game_menu_bg.color = MENU_BG_DIM if see_through else MENU_BG_SOLID
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
	var vb := _menu_page("Game Menu", true)
	# Continue FIRST, because the commonest reason to be looking at this screen
	# is having pressed Escape by mistake.
	_game_menu_button(vb, "Continue", _close_game_menu)
	_game_menu_button(vb, "Settings", _populate_settings_menu)
	_game_menu_button(vb, "Save and Exit to Main Menu" if _net_mode == "single"
		else "Leave Game", _exit_to_main_menu)


func _populate_settings_menu() -> void:
	var vb := _menu_page("Settings")
	# One button per group, each with its own page. A single scrolling list works
	# until it does not, and the moment a fourth setting joins any of these
	# groups it stops working -- better to have the shape right while it is
	# cheap to change.
	_game_menu_button(vb, "Video", _populate_video_menu)
	_game_menu_button(vb, "Audio", _populate_audio_menu)
	_game_menu_button(vb, "Game", _populate_game_settings_menu)
	_game_menu_button(vb, "Controls", _populate_controls_menu)
	_game_menu_button(vb, "Back", _populate_game_menu, "ui_back")


## The three ways a window can own the screen. Godot's "fullscreen" is the
## borderless one; the exclusive mode is its own thing and worth offering,
## because it is the one that can change refresh rate and skip the compositor.
const WINDOW_MODES := ["Windowed", "Windowed Fullscreen", "Fullscreen"]
const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]


func _populate_video_menu() -> void:
	var vb := _menu_page("Video")
	_game_menu_cycle(vb, "Window mode", "window_mode", WINDOW_MODES, 0)
	var res_names: Array = []
	for r in RESOLUTIONS:
		res_names.append("%d x %d" % [r.x, r.y])
	# Only meaningful windowed: the other two take the size of the screen they
	# are covering, and offering a choice that does nothing is worse than not
	# offering it.
	_game_menu_cycle(vb, "Resolution", "resolution", res_names, 3,
		int(setting("window_mode", 0)) == 0)
	_game_menu_slider(vb, "Render distance", "render_distance",
		float(WorldManager.RENDER_DISTANCE_DEFAULT),
		float(WorldManager.RENDER_DISTANCE_MIN), float(WorldManager.RENDER_DISTANCE_MAX),
		1.0, "%d")
	_game_menu_slider(vb, "Field of view", "fov", 75.0, 60.0, 110.0, 1.0, "%d")
	_game_menu_check(vb, "V-Sync", "vsync", true)
	_game_menu_check(vb, "Show FPS", "show_fps", false)
	_game_menu_button(vb, "Back", _populate_settings_menu, "ui_back")


func _populate_audio_menu() -> void:
	var vb := _menu_page("Audio")
	_game_menu_slider(vb, "Master", "vol_master", 0.8, 0.0, 1.0, 0.05, "%d%%", 100.0)
	_game_menu_slider(vb, "Music", "vol_music", 0.7, 0.0, 1.0, 0.05, "%d%%", 100.0)
	_game_menu_slider(vb, "Effects", "vol_sfx", 0.9, 0.0, 1.0, 0.05, "%d%%", 100.0)
	var note := Label.new()
	note.text = "nothing plays any sound yet"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 12)
	note.modulate = Color(1, 1, 1, 0.45)
	vb.add_child(note)
	_game_menu_button(vb, "Back", _populate_settings_menu, "ui_back")


func _populate_game_settings_menu() -> void:
	var vb := _menu_page("Game")
	_game_menu_slider(vb, "Mouse sensitivity", "sensitivity", 1.0, 0.25, 3.0, 0.05, "%.2fx")
	_game_menu_check(vb, "Invert mouse Y", "invert_y", false)
	_game_menu_check(vb, "Placement preview", "placement_ghost", true)
	_game_menu_check(vb, "Name what you look at", "show_names", true)
	_game_menu_slider(vb, "Autosave", "autosave_min", 5.0, 0.0, 20.0, 1.0, "%d min")
	var note := Label.new()
	note.text = "autosave is single player only; 0 turns it off"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 12)
	note.modulate = Color(1, 1, 1, 0.45)
	vb.add_child(note)
	_game_menu_button(vb, "Back", _populate_settings_menu, "ui_back")


## A setting you step through rather than slide: arrows either side of the value.
## Stored as an index, so the list can grow without invalidating what is saved.
func _game_menu_cycle(vb: VBoxContainer, text: String, key: String,
		options: Array, dflt: int, enabled: bool = true) -> void:
	var row := _menu_row(vb, text)
	var idx := int(setting(key, dflt))
	var left := Button.new()
	left.text = "<"
	left.custom_minimum_size = Vector2(28, 26)
	var val := Label.new()
	val.custom_minimum_size = Vector2(150, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", 15)
	var right := Button.new()
	right.text = ">"
	right.custom_minimum_size = Vector2(28, 26)
	val.text = str(options[clampi(idx, 0, options.size() - 1)])
	var step := func(d: int):
		var i := posmod(int(setting(key, dflt)) + d, options.size())
		val.text = str(options[i])
		set_setting(key, i)
		# The window mode decides whether the resolution row means anything, so
		# the page is rebuilt rather than left half true.
		if key == "window_mode":
			_populate_video_menu()
	_wire_button(left)
	_wire_button(right)
	left.pressed.connect(func(): step.call(-1))
	right.pressed.connect(func(): step.call(1))
	left.disabled = not enabled
	right.disabled = not enabled
	val.modulate = Color(1, 1, 1, 1.0 if enabled else 0.4)
	row.add_child(left)
	row.add_child(val)
	row.add_child(right)


## Every key you can move it to. Its own page: fourteen rows would swamp the
## settings, and rebinding is a thing you do once rather than something you
## want in the way of the sliders you touch often.
func _populate_controls_menu() -> void:
	var page := _menu_page("Controls")
	# Scrolled, with a cap: fourteen rows is taller than a small screen, and a
	# list that runs off the bottom takes its Back button with it.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, minf(420.0,
		float(get_viewport().get_visible_rect().size.y) * 0.55))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.custom_minimum_size = Vector2(300, 0)
	scroll.add_child(vb)
	for action in Player.BIND_ORDER:
		var row := _menu_row(vb, str(Player.BIND_NAMES[action]))
		var b := Button.new()
		b.custom_minimum_size = Vector2(120, 26)
		b.text = _bind_label(action)
		_wire_button(b, "ui_prompt")
		b.pressed.connect(func():
			_awaiting_bind = action
			b.text = "press a key"
			_bind_button = b)
		row.add_child(b)
	_game_menu_button(page, "Reset to defaults", func():
		Audio.ui("ui_accept")
		for a in Player.DEFAULT_BINDS:
			set_setting("bind_" + a, int(Player.DEFAULT_BINDS[a]))
		_populate_controls_menu())
	_game_menu_button(page, "Back", _populate_settings_menu, "ui_back")


func _bind_label(action: String) -> String:
	var code := int(setting("bind_" + action, int(Player.DEFAULT_BINDS[action])))
	var nm := OS.get_keycode_string(code)
	return nm if nm != "" else "?"


## A label on the left and room for a control on the right, so a page of
## settings reads as one list rather than as a stack of centred captions.
func _menu_row(vb: VBoxContainer, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(300, 0)
	row.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 15)
	row.add_child(l)
	vb.add_child(row)
	return row


func _menu_section(vb: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.modulate = Color(0.65, 0.82, 1.0, 0.85)
	vb.add_child(l)


## A labelled slider, on one line with its value. `show_mul` scales what is
## PRINTED without touching what is stored, so a volume can be a fraction on
## disk and a percentage on screen.
func _game_menu_slider(vb: VBoxContainer, text: String, key: String,
		dflt: float, lo: float, hi: float, step: float, fmt: String,
		show_mul: float = 1.0) -> void:
	var row := _menu_row(vb, text)
	var val := Label.new()
	val.custom_minimum_size = Vector2(52, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", 15)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.value = float(setting(key, dflt))
	sl.custom_minimum_size = Vector2(130, 20)
	val.text = fmt % (sl.value * show_mul)
	sl.value_changed.connect(func(v: float):
		val.text = fmt % (v * show_mul)
		Audio.ui("ui_tick")
		set_setting(key, v))
	row.add_child(sl)
	row.add_child(val)


## A labelled on/off row. Takes effect and is written to disk the moment it is
## clicked -- there is no OK button to forget to press.
func _game_menu_check(vb: VBoxContainer, text: String, key: String, dflt: bool) -> void:
	var row := _menu_row(vb, text)
	var c := CheckButton.new()
	c.button_pressed = bool(setting(key, dflt))
	_wire_button(c, "")
	c.toggled.connect(func(on: bool):
		Audio.ui("ui_toggle_on" if on else "ui_toggle_off")
		set_setting(key, on))
	row.add_child(c)


func _game_menu_button(vb: VBoxContainer, text: String, cb: Callable,
		sound: String = "ui_click") -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 44)
	_wire_button(b, sound)
	b.pressed.connect(cb)
	vb.add_child(b)


func _close_game_menu() -> void:
	if _game_menu != null:
		Audio.ui("ui_close")
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
	# ...and what we look like, which unlike the inventory is the same for
	# everyone rather than a private thing the host keeps for us.
	_net.announce_skin(current_skin_image().save_png_to_buffer())
	_build_chat()

	# player: drop in just above dry land on the home world
	var home: Planet = world.planets[0]
	var player := Player.new()
	player.name = "Player"
	player.world = world
	player.menu_requested.connect(_toggle_game_menu)
	_apply_settings()
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
		var png = st.get("skin", null)
		if png is PackedByteArray:
			av.wear_png(png)
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
	# Autosave, single player only: on a server the host already saves on its own
	# clock, and in someone else's world there is nothing of yours to write.
	if _net_mode == "single" and _world != null and _world.player != null:
		var mins := float(setting("autosave_min", 5.0))
		if mins > 0.0:
			_autosave_t += delta
			if _autosave_t >= mins * 60.0:
				_autosave_t = 0.0
				if _world.save_game():
					_world.player.call("_toast", "Autosaved")
	if _fps_label != null and _fps_label.visible:
		_fps_label.text = "%d fps" % int(round(Engine.get_frames_per_second()))
	if _world != null:
		_world.tick_crops(delta)
		_world.tick_water(delta)
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
	var reach := float(_world.render_distance * Blocks.CHUNK_SIZE)
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
