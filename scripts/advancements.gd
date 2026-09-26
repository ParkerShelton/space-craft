class_name Advancements
extends RefCounted
## What you have worked out how to do, and what that opens up next.
##
## This game deliberately refuses to hand out objectives -- the wreck teaches by
## being a wreck, and the survey teaches by being something you wrote. But
## "there is nothing to do next" and "I cannot find out what to do next" look
## identical from the inside, and the second one loses people on the first
## evening.
##
## The tutorial is ONE LINE on purpose: while you are still working out what the
## game is, a fork is a way to get lost. Everything past "it holds air" is the
## opposite -- four trees running beside each other, most of them optional, so
## what you do next is a choice rather than the next item on a list. Two of them
## never lead anywhere near the ship, which is the point: a game about being
## stranded should let you decide not to leave for a while.
##
## Adding one is a row in DEFS plus a line in Player._check_advancements, which
## polls rather than hooking twenty call sites, so nothing else in the game has
## to know this file exists.

## The trees, in the order their tabs appear.
const TABS := [
	{"id": "survival", "name": "Getting Down", "icon": "COCKPIT"},
	{"id": "craft", "name": "Metal and Machines", "icon": "ANVIL"},
	{"id": "home", "name": "Making a Home", "icon": "BED"},
	{"id": "space", "name": "Getting Off", "icon": "THRUSTER"},
]

## id, name, what you did, which tree it is in, and what it follows.
##
## `parent` may name SEVERAL entries separated by a space, and then it opens as
## soon as ANY of them is done. That is what lets the branches rejoin without
## pretending there was only ever one route through.
const DEFS := [
	# --- the tutorial: one line, no forks ------------------------------------
	{"id": "crash", "name": "Hard Landing", "parent": "", "tab": "survival",
		"desc": "Wake up in the wreck.", "icon": "COCKPIT"},
	{"id": "read", "name": "Your Own Handwriting", "parent": "crash", "tab": "survival",
		"desc": "Read the approach survey.", "icon": "JOURNAL"},
	{"id": "wood", "name": "Timber", "parent": "read", "tab": "survival",
		"desc": "Tear down a tree with your hands.", "icon": "WOOD"},
	{"id": "bench", "name": "Somewhere to Work", "parent": "wood", "tab": "survival",
		"desc": "Put down a Carpenter's Bench.", "icon": "CARPENTER"},
	{"id": "pick", "name": "Something to Dig With", "parent": "bench", "tab": "survival",
		"desc": "Make a pick. Bare hands get no ore.", "icon": "PICK"},
	{"id": "ore", "name": "First Ore", "parent": "pick", "tab": "survival",
		"desc": "Cut ore out of the ground.", "icon": "ORE_0"},
	{"id": "smelter", "name": "Fire and Rock", "parent": "ore", "tab": "survival",
		"desc": "Put down a Smelter.", "icon": "SMELTER"},
	{"id": "ingot", "name": "Ingot", "parent": "smelter", "tab": "survival",
		"desc": "Smelt ore down into metal.", "icon": "REFINED_0"},
	{"id": "anvil", "name": "Hammer and Anvil", "parent": "ingot", "tab": "survival",
		"desc": "Put down an Anvil and make a hammer.", "icon": "ANVIL"},
	{"id": "plate", "name": "Beaten Flat", "parent": "anvil", "tab": "survival",
		"desc": "Beat an ingot down to a plate.", "icon": "PLATE"},
	{"id": "hull", "name": "Hull", "parent": "plate", "tab": "survival",
		"desc": "Press four plates into a block of hull.", "icon": "METAL"},
	{"id": "sealed", "name": "It Holds Air", "parent": "hull", "tab": "survival",
		"desc": "Seal every hole in the cabin.", "icon": "LIFE_SUPPORT"},

	# --- metalwork: everything the anvil and the press can do ----------------
	{"id": "bar", "name": "Drawn Out", "parent": "plate", "tab": "craft",
		"desc": "Take a bar off the anvil instead of going further.", "icon": "BAR"},
	{"id": "sheet", "name": "Rolled Thin", "parent": "bar", "tab": "craft",
		"desc": "Beat a bar down into a sheet.", "icon": "SHEET"},
	{"id": "scrap", "name": "One Blow Too Many", "parent": "plate", "tab": "craft",
		"desc": "Crack a workpiece. Scrap remelts -- nothing is wasted.", "icon": "SCRAP"},
	{"id": "wire", "name": "Drawn Wire", "parent": "plate", "tab": "craft",
		"desc": "Make wire from a conductive ore.", "icon": "WIRE"},
	{"id": "fabricator", "name": "The Press", "parent": "plate", "tab": "craft",
		"desc": "Build a Press.", "icon": "FABRICATOR"},
	{"id": "circuit", "name": "Circuitry", "parent": "fabricator", "tab": "craft",
		"desc": "Make a circuit.", "icon": "CIRCUIT"},
	{"id": "alloy", "name": "Alloy", "parent": "fabricator", "tab": "craft",
		"desc": "Make alloy plating.", "icon": "ALLOY"},
	{"id": "shipworks", "name": "A Yard of Your Own", "parent": "alloy", "tab": "craft",
		"desc": "Build a Shipworks.", "icon": "SHIPWORKS"},
	{"id": "shaper", "name": "Cut to Shape", "parent": "bench", "tab": "craft",
		"desc": "Build a Block Shaper.", "icon": "SHAPER"},

	# --- a home: none of this is on the way to leaving ------------------------
	{"id": "torch", "name": "Something to See By", "parent": "wood", "tab": "home",
		"desc": "Set down a torch.", "icon": "TORCH"},
	{"id": "fire", "name": "A Fire Going", "parent": "torch", "tab": "home",
		"desc": "Put down a campfire.", "icon": "CAMPFIRE"},
	{"id": "ate", "name": "A Hot Meal", "parent": "fire", "tab": "home",
		"desc": "Cook something and eat it.", "icon": "COOKED_MEAT"},
	{"id": "bed", "name": "Somewhere to Sleep", "parent": "torch", "tab": "home",
		"desc": "Put down a bed.", "icon": "BED"},
	{"id": "slept", "name": "Through the Night", "parent": "bed", "tab": "home",
		"desc": "Sleep until morning.", "icon": "BED"},
	{"id": "chest", "name": "Somewhere to Put It", "parent": "bench", "tab": "home",
		"desc": "Put down a chest.", "icon": "CHEST"},
	{"id": "widechest", "name": "A Bigger Box", "parent": "chest", "tab": "home",
		"desc": "Build a Wide Chest.", "icon": "CHEST_WIDE"},
	{"id": "cargo", "name": "Modular", "parent": "circuit chest", "tab": "home",
		"desc": "Build a Cargo Module.", "icon": "CARGO_MODULE"},
	{"id": "bank", "name": "A Proper Hold", "parent": "cargo", "tab": "home",
		"desc": "Stand four Cargo Modules together and open them as one.",
		"icon": "CARGO_MODULE"},
	{"id": "boat", "name": "Wood Floats", "parent": "bench", "tab": "home",
		"desc": "Build a boat and get in it.", "icon": "BOAT"},
	{"id": "climate", "name": "Weather Kept Out", "parent": "circuit", "tab": "home",
		"desc": "Build a Climate Unit.", "icon": "CLIMATE_UNIT"},
	{"id": "o2plant", "name": "Air of Your Own", "parent": "circuit", "tab": "home",
		"desc": "Build an Oxygen Plant.", "icon": "OXYGEN_PLANT"},

	# --- getting off the ground ----------------------------------------------
	{"id": "generator", "name": "Power of Your Own", "parent": "wire", "tab": "space",
		"desc": "Build a Generator.", "icon": "GENERATOR"},
	{"id": "charged", "name": "Charged", "parent": "generator", "tab": "space",
		"desc": "Fill a battery at a Generator.", "icon": "BATTERY"},
	{"id": "shippower", "name": "Ship Power", "parent": "charged sealed", "tab": "space",
		"desc": "Put a charged battery in the ship's rack.", "icon": "POWER_BAY"},
	{"id": "lifesupport", "name": "Breathing Room", "parent": "shippower", "tab": "space",
		"desc": "Get the scrubbers running in a sealed cabin.", "icon": "LIFE_SUPPORT"},
	{"id": "thruster", "name": "Engines", "parent": "shippower", "tab": "space",
		"desc": "Fit a thruster to the ship.", "icon": "THRUSTER"},
	{"id": "trim", "name": "Flies Straight", "parent": "thruster", "tab": "space",
		"desc": "Get the engines balanced over the weight.", "icon": "THRUSTER"},
	{"id": "flew", "name": "Off the Ground", "parent": "thruster", "tab": "space",
		"desc": "Fly the ship.", "icon": "COCKPIT"},
	{"id": "built", "name": "Built, Not Salvaged", "parent": "shipworks flew", "tab": "space",
		"desc": "Fly a ship you built yourself.", "icon": "SHIPWORKS"},
	{"id": "warp", "name": "Somewhere Else", "parent": "flew", "tab": "space",
		"desc": "Fit a Warp Drive and leave the system.", "icon": "WARP_DRIVE"},
]


static func by_id(id: String) -> Dictionary:
	for d in DEFS:
		if str(d["id"]) == id:
			return d
	return {}


## Everything this one follows. Usually one; several when the branches rejoin.
static func parents_of(d: Dictionary) -> Array:
	var raw := str(d.get("parent", "")).strip_edges()
	if raw == "":
		return []
	return Array(raw.split(" ", false))


## The block whose picture stands for this one, as an actual block id.
static func icon_id(d: Dictionary) -> int:
	match str(d.get("icon", "")):
		"COCKPIT": return Blocks.COCKPIT
		"WOOD": return Blocks.WOOD
		"CARPENTER": return Blocks.CARPENTER
		"PICK": return Blocks.PICK
		"ORE_0": return Blocks.ORE_0
		"SMELTER": return Blocks.SMELTER
		"REFINED_0": return Blocks.REFINED_0
		"ANVIL": return Blocks.ANVIL
		"PLATE": return Blocks.PLATE
		"METAL": return Blocks.METAL
		"LIFE_SUPPORT": return Blocks.LIFE_SUPPORT
		"TORCH": return Blocks.TORCH
		"BED": return Blocks.BED
		"COOKED_MEAT": return Blocks.COOKED_MEAT
		"GENERATOR": return Blocks.GENERATOR
		"BATTERY": return Blocks.BATTERY
		"POWER_BAY": return Blocks.POWER_BAY
		"THRUSTER": return Blocks.THRUSTER
		"WARP_DRIVE": return Blocks.WARP_DRIVE
		"JOURNAL": return Blocks.JOURNAL
		"BOAT": return Blocks.BOAT
		"BAR": return Blocks.BAR
		"SHEET": return Blocks.SHEET
		"SCRAP": return Blocks.SCRAP
		"WIRE": return Blocks.WIRE
		"FABRICATOR": return Blocks.FABRICATOR
		"CIRCUIT": return Blocks.CIRCUIT
		"ALLOY": return Blocks.ALLOY
		"SHIPWORKS": return Blocks.SHIPWORKS
		"SHAPER": return Blocks.SHAPER
		"CAMPFIRE": return Blocks.CAMPFIRE
		"CHEST": return Blocks.CHEST
		"CHEST_WIDE": return Blocks.CHEST_WIDE
		"CARGO_MODULE": return Blocks.CARGO_MODULE
		"CLIMATE_UNIT": return Blocks.CLIMATE_UNIT
		"OXYGEN_PLANT": return Blocks.OXYGEN_PLANT
	return Blocks.ROCK


## Is this one visible yet? You see what you have done, and the one step past
## it. Everything further is blank -- the tree is a light held up, not a map.
static func visible_to(id: String, earned: Dictionary) -> bool:
	if earned.has(id):
		return true
	var d := by_id(id)
	if d.is_empty():
		return false
	var ps := parents_of(d)
	if ps.is_empty():
		return true
	for p in ps:
		if earned.has(str(p)):
			return true
	return false


## Everything you could earn next: not done, but something it follows is.
static func next_steps(earned: Dictionary) -> Array:
	var out: Array = []
	for d in DEFS:
		if earned.has(str(d["id"])):
			continue
		if visible_to(str(d["id"]), earned):
			out.append(d)
	return out


## Which column it sits in: how many steps from a root, by its SHORTEST route,
## so an entry two branches can reach is drawn beside the nearer of them rather
## than pushed out to the far one.
static func depth_of(id: String) -> int:
	return _depth(id, {})


static func _depth(id: String, seen: Dictionary) -> int:
	if seen.has(id):
		return 0
	seen[id] = true
	var d := by_id(id)
	if d.is_empty():
		return 0
	var ps := parents_of(d)
	if ps.is_empty():
		return 0
	var best := 1 << 20
	for p in ps:
		best = mini(best, _depth(str(p), seen.duplicate()) + 1)
	return 0 if best == 1 << 20 else best


## Everything belonging to one tab.
static func in_tab(tab: String) -> Array:
	var out: Array = []
	for d in DEFS:
		if str(d.get("tab", "")) == tab:
			out.append(d)
	return out


## How much of a tab is done, as done/total, for the label on the tab itself.
static func tab_progress(tab: String, earned: Dictionary) -> Vector2i:
	var done := 0
	var all := in_tab(tab)
	for d in all:
		if earned.has(str(d["id"])):
			done += 1
	return Vector2i(done, all.size())
