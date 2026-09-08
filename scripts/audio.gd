extends Node

## Every sound the game makes goes through here.
##
## The point of a single funnel is not tidiness, it is that the things which
## make repeated sounds bearable -- pitch variation, a pool of takes, a cap on
## how often one can retrigger -- are easy to forget at each call site and
## impossible to forget here.
##
## Only the UI has recordings today. The world entries below are deliberately
## listed with no files behind them: an entry with nothing to play is silent,
## so dropping WAVs into `sounds/world/` under the names it already expects is
## the whole job of turning block and footstep audio on. No code change.

# --- catalogue ----------------------------------------------------------------

const UI := "res://sounds/ui/"
const WORLD := "res://sounds/world/"

## name -> how to play it.
##   files    -- takes to choose between. More than one is what stops a sound
##               that fires constantly from turning into a metronome.
##   db       -- trim, relative to the recording.
##   pitch    -- random detune per play, as a fraction. Costs nothing and does
##               more for repetition than any amount of recording quality.
##   throttle -- ms that must pass before this name may play again.
const CATALOG := {
	# UI. Non-positional, always audible, deliberately small.
	"ui_hover": {"files": [UI + "hover_1.wav", UI + "hover_2.wav", UI + "hover_3.wav"],
		"db": -13.0, "pitch": 0.10, "throttle": 45},
	"ui_click": {"files": [UI + "click_1.wav", UI + "click_2.wav", UI + "click_3.wav"],
		"db": -5.0, "pitch": 0.07},
	"ui_back": {"files": [UI + "back.wav"], "db": -5.0, "pitch": 0.05},
	"ui_toggle_on": {"files": [UI + "toggle_on.wav"], "db": -7.0, "pitch": 0.03},
	"ui_toggle_off": {"files": [UI + "toggle_off.wav"], "db": -7.0, "pitch": 0.03},
	# One per slider step, so it has to be cheap and it has to be capped.
	"ui_tick": {"files": [UI + "tick.wav"], "db": -10.0, "pitch": 0.14, "throttle": 28},
	"ui_open": {"files": [UI + "open.wav"], "db": -8.0, "pitch": 0.02},
	"ui_close": {"files": [UI + "close.wav"], "db": -8.0, "pitch": 0.02},
	"ui_prompt": {"files": [UI + "prompt.wav"], "db": -8.0, "pitch": 0.02},
	"ui_accept": {"files": [UI + "accept.wav"], "db": -7.0, "pitch": 0.02},
	"ui_deny": {"files": [UI + "deny.wav"], "db": -6.0, "pitch": 0.02},

	# The world. Nothing behind these yet -- see the note at the top.
	"break_stone": {"files": ["_takes", WORLD + "break_stone", 4], "pitch": 0.15},
	"break_dirt": {"files": ["_takes", WORLD + "break_dirt", 4], "pitch": 0.15},
	"break_grass": {"files": ["_takes", WORLD + "break_grass", 4], "pitch": 0.15},
	"break_wood": {"files": ["_takes", WORLD + "break_wood", 4], "pitch": 0.15},
	"break_leaves": {"files": ["_takes", WORLD + "break_leaves", 4], "pitch": 0.18},
	"break_snow": {"files": ["_takes", WORLD + "break_snow", 4], "pitch": 0.15},
	"break_metal": {"files": ["_takes", WORLD + "break_metal", 4], "pitch": 0.12},
	"break_glass": {"files": ["_takes", WORLD + "break_glass", 4], "pitch": 0.15},
	"place_stone": {"files": ["_takes", WORLD + "place_stone", 3], "pitch": 0.15},
	"place_dirt": {"files": ["_takes", WORLD + "place_dirt", 3], "pitch": 0.15},
	"place_grass": {"files": ["_takes", WORLD + "place_grass", 3], "pitch": 0.15},
	"place_wood": {"files": ["_takes", WORLD + "place_wood", 3], "pitch": 0.15},
	"place_leaves": {"files": ["_takes", WORLD + "place_leaves", 3], "pitch": 0.18},
	"place_snow": {"files": ["_takes", WORLD + "place_snow", 3], "pitch": 0.15},
	"place_metal": {"files": ["_takes", WORLD + "place_metal", 3], "pitch": 0.12},
	"place_glass": {"files": ["_takes", WORLD + "place_glass", 3], "pitch": 0.15},
	# Footsteps fire several times a second, so they get the most takes and the
	# widest detune of anything in the game.
	"step_stone": {"files": ["_takes", WORLD + "step_stone", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_dirt": {"files": ["_takes", WORLD + "step_dirt", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_grass": {"files": ["_takes", WORLD + "step_grass", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_wood": {"files": ["_takes", WORLD + "step_wood", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_leaves": {"files": ["_takes", WORLD + "step_leaves", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_snow": {"files": ["_takes", WORLD + "step_snow", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_metal": {"files": ["_takes", WORLD + "step_metal", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
	"step_glass": {"files": ["_takes", WORLD + "step_glass", 6], "db": -8.0, "pitch": 0.2, "throttle": 120},
}


## Expands the ["_takes", base, n] shorthand above into base_1.wav .. base_n.wav.
##
## A const dictionary cannot call a function, hence the marker. Missing files
## are skipped at load, so the count is a ceiling rather than a requirement:
## record three of the six and the three you recorded are what plays.
func _files_for(spec: Dictionary) -> Array:
	var f: Array = spec.get("files", [])
	if f.size() == 3 and f[0] == "_takes":
		var out := []
		for i in range(1, int(f[2]) + 1):
			out.append("%s_%d.wav" % [f[1], i])
		return out
	return f


# --- what each block sounds like ----------------------------------------------

## Anything not in the table below falls back to this, so a block added later
## makes a plausible noise on day one rather than none at all -- and most of
## what is missing from the table genuinely is rock.
const MATERIAL_DEFAULT := "stone"

## The ten base blocks that have a slab and a stair form, in the order their
## ids run. Both shaped ranges are contiguous and parallel to this list, so a
## slab can take its sound from the block it was cut out of instead of needing
## twenty more table rows.
const SHAPED_BASE := ["ROCK", "DIRT", "GRASS", "REGOLITH", "ICE", "SNOW",
	"CRYSTAL", "METAL", "WOOD", "GLASS"]

var _material := {}


## Built at runtime rather than declared as a const: it is keyed by Blocks ids,
## and a const expression cannot reach another script's constants.
##
## Names are looked up through the constant map rather than written as
## `Blocks.DIRT`, so a block that gets renamed or removed drops one row out of
## the table instead of failing to parse the whole file.
func _build_material_table() -> void:
	var k: Dictionary = (Blocks as GDScript).get_script_constant_map()
	var t := {
		"dirt": ["DIRT", "TILLED", "REGOLITH", "CORE", "PATH"],
		"grass": ["GRASS", "TALL_GRASS", "CROP", "SAPLING", "YOUNG_TREE",
			"SEEDS", "COOKED_CROP"],
		"wood": ["WOOD", "WOOD_PALE", "WOOD_DARK", "PLANK", "PLANK_PALE",
			"PLANK_DARK", "CAMPFIRE"],
		"snow": ["SNOW"],
		"glass": ["GLASS", "ICE", "CRYSTAL"],
		"metal": ["METAL", "PARTS", "MACHINE_CORE", "SMELTER", "FABRICATOR",
			"SHIPWORKS", "CARPENTER", "FORGE", "SHAPER", "CLIMATE_UNIT",
			"GENERATOR", "OXYGEN_PLANT", "HEATER", "COOLER", "WIRE", "BATTERY",
			"POWER_BAY", "CHEST", "DOOR", "DOOR_OPEN", "COCKPIT", "THRUSTER",
			"LIFE_SUPPORT", "WARP_DRIVE", "INTERFACE", "ALLOY", "CIRCUIT",
			"DRILL", "SUIT", "WEAPON", "PULSE_PISTOL", "HOE", "WRENCH",
			"TORCH", "GLOW_LAMP", "EMBER_TORCH", "ROOF_SLAB"],
	}
	for mat in t:
		for nm in t[mat]:
			if k.has(nm):
				_material[int(k[nm])] = mat
	# Every leaf colour there is, however many the tree work ends up adding.
	for id in k.get("LEAF_IDS", []):
		_material[int(id)] = "leaves"
	# Slabs and stairs sound like whatever they were cut from.
	for i in SHAPED_BASE.size():
		var base: String = SHAPED_BASE[i]
		if not k.has(base):
			continue
		var mat: String = _material.get(int(k[base]), MATERIAL_DEFAULT)
		for form in ["_SLAB", "_STAIR"]:
			if k.has(base + form):
				_material[int(k[base + form])] = mat


func material_of(id: int) -> String:
	return _material.get(id, MATERIAL_DEFAULT)


# --- the pool -----------------------------------------------------------------

const POOL_FLAT := 6
const POOL_3D := 20
const HEAR_RANGE := 48.0

var _flat: Array[AudioStreamPlayer] = []
var _positional: Array[AudioStreamPlayer3D] = []
var _streams := {}
var _last := {}
var _silent := false
var _missing: Array[String] = []


func _ready() -> void:
	# A dedicated server has no output and nobody listening to it. Building the
	# pool anyway would be harmless but pointless, and loading every WAV to
	# never play one would not be.
	_silent = DisplayServer.get_name() == "headless" \
		or OS.has_feature("dedicated_server")
	ensure_buses()
	if _silent:
		return
	_build_material_table()
	_load()
	for i in POOL_FLAT:
		var p := AudioStreamPlayer.new()
		p.bus = "Effects"
		add_child(p)
		_flat.append(p)
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.bus = "Effects"
		p3.max_distance = HEAR_RANGE
		p3.unit_size = 6.0
		add_child(p3)
		_positional.append(p3)


## Buses live here rather than in the menu because they have to exist before
## anything can be assigned to them, and an autoload is ready before the game is.
func ensure_buses() -> void:
	for nm in ["Music", "Effects"]:
		if AudioServer.get_bus_index(nm) < 0:
			var i := AudioServer.bus_count
			AudioServer.add_bus(i)
			AudioServer.set_bus_name(i, nm)
			AudioServer.set_bus_send(i, "Master")


func set_bus_volume(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_mute(i, linear <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))


## One AudioStreamRandomizer per catalogue entry: Godot does the take-picking
## and the detune itself, so neither is something a call site can get wrong.
## An entry whose files are all absent gets no stream, and playing it later is
## a no-op rather than an error.
func _load() -> void:
	for name in CATALOG:
		var spec: Dictionary = CATALOG[name]
		var rnd := AudioStreamRandomizer.new()
		var n := 0
		for path in _files_for(spec):
			if not ResourceLoader.exists(path):
				_missing.append(path)
				continue
			var s = load(path)
			if s == null:
				continue
			rnd.add_stream(n, s)
			n += 1
		if n == 0:
			continue
		rnd.random_pitch = 1.0 + float(spec.get("pitch", 0.0))
		# No-repeats needs somewhere to go; with one take there is nowhere.
		rnd.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS \
			if n > 1 else AudioStreamRandomizer.PLAYBACK_RANDOM
		_streams[name] = rnd


## What is catalogued but not yet recorded, so it stays visible instead of just
## being quiet.
func missing_report() -> String:
	if _silent:
		return "audio: off (no output on this run)"
	if _missing.is_empty():
		return "audio: every catalogued sound has a file behind it"
	var by_dir := {}
	for p in _missing:
		var d: String = p.get_base_dir()
		by_dir[d] = int(by_dir.get(d, 0)) + 1
	var parts := []
	for d in by_dir:
		parts.append("%s (%d)" % [d, by_dir[d]])
	return "audio: %d file(s) not recorded yet -- %s" % [_missing.size(),
		", ".join(parts)]


## True if this name would actually make a noise. Lets a call site skip work it
## would only be doing on behalf of a sound that is not there.
func has(name: String) -> bool:
	return _streams.has(name)


func _throttled(name: String, spec: Dictionary) -> bool:
	var ms := int(spec.get("throttle", 0))
	if ms <= 0:
		return false
	var now := Time.get_ticks_msec()
	if now - int(_last.get(name, -100000)) < ms:
		return true
	_last[name] = now
	return false


# --- playing ------------------------------------------------------------------

## Menus, and anything else without a place in the world.
func ui(name: String) -> void:
	if _silent or not _streams.has(name):
		return
	var spec: Dictionary = CATALOG[name]
	if _throttled(name, spec):
		return
	var p := _free_flat()
	p.stream = _streams[name]
	p.volume_db = float(spec.get("db", 0.0))
	p.play()


## Anything that happens somewhere.
func at(name: String, pos: Vector3) -> void:
	if _silent or not _streams.has(name):
		return
	var spec: Dictionary = CATALOG[name]
	if _throttled(name, spec):
		return
	var p := _free_positional()
	p.stream = _streams[name]
	p.volume_db = float(spec.get("db", 0.0))
	p.global_position = pos
	p.play()


## The three things the world actually asks for, taken by block rather than by
## sound name -- a caller has a block id, not an opinion about what dirt sounds
## like.
func block_broken(id: int, pos: Vector3) -> void:
	at("break_" + material_of(id), pos)


func block_placed(id: int, pos: Vector3) -> void:
	at("place_" + material_of(id), pos)


func footstep(id: int, pos: Vector3) -> void:
	at("step_" + material_of(id), pos)


## A free player, or else the one that has been going longest. Stealing beats
## going silent: the alternative to cutting off the oldest of twenty overlapping
## sounds is dropping the newest, and the newest is the one just asked for.
func _free_flat() -> AudioStreamPlayer:
	var oldest: AudioStreamPlayer = _flat[0]
	var best := -1.0
	for p in _flat:
		if not p.playing:
			return p
		var t := p.get_playback_position()
		if t > best:
			best = t
			oldest = p
	return oldest


func _free_positional() -> AudioStreamPlayer3D:
	var oldest: AudioStreamPlayer3D = _positional[0]
	var best := -1.0
	for p in _positional:
		if not p.playing:
			return p
		var t := p.get_playback_position()
		if t > best:
			best = t
			oldest = p
	return oldest
