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
## So: a tree you can open, where every step you have taken is lit, and the
## steps DIRECTLY after those are shown as the next thing to try. Anything
## further out stays hidden, so the list is never a plan handed to you -- it is
## one step of light in the direction you are already walking.
##
## Adding one is a row in DEFS. The condition lives in `earned_now`, which is
## polled a few times a second, so nothing else in the game has to know this
## file exists.

## id, what it is called, what you did, its parent (""), and the block whose
## icon stands for it.
const DEFS := [
	{"id": "crash", "name": "Hard Landing", "parent": "",
		"desc": "Wake up in the wreck.", "icon": "COCKPIT"},

	# The material chain: everything a hull plate is made of, in order.
	{"id": "wood", "name": "Timber", "parent": "crash",
		"desc": "Tear down a tree with your hands.", "icon": "WOOD"},
	{"id": "bench", "name": "Somewhere to Work", "parent": "wood",
		"desc": "Put down a Carpenter's Bench.", "icon": "CARPENTER"},
	{"id": "pick", "name": "Something to Dig With", "parent": "bench",
		"desc": "Make a pick. Bare hands get no ore.", "icon": "PICK"},
	{"id": "ore", "name": "First Ore", "parent": "pick",
		"desc": "Cut ore out of the ground.", "icon": "ORE_0"},
	{"id": "smelter", "name": "Fire and Rock", "parent": "ore",
		"desc": "Put down a Smelter.", "icon": "SMELTER"},
	{"id": "ingot", "name": "Ingot", "parent": "smelter",
		"desc": "Smelt ore down into metal.", "icon": "REFINED_0"},
	{"id": "anvil", "name": "Hammer and Anvil", "parent": "ingot",
		"desc": "Put down an Anvil and make a hammer.", "icon": "ANVIL"},
	{"id": "plate", "name": "Beaten Flat", "parent": "anvil",
		"desc": "Beat an ingot down to a plate.", "icon": "PLATE"},
	{"id": "hull", "name": "Hull", "parent": "plate",
		"desc": "Press four plates into a block of hull.", "icon": "METAL"},
	{"id": "sealed", "name": "It Holds Air", "parent": "hull",
		"desc": "Seal every hole in the cabin.", "icon": "LIFE_SUPPORT"},

	# Staying alive through the first night.
	{"id": "torch", "name": "Something to See By", "parent": "crash",
		"desc": "Set down a torch.", "icon": "TORCH"},
	{"id": "bed", "name": "Somewhere to Sleep", "parent": "torch",
		"desc": "Put down a bed.", "icon": "BED"},
	{"id": "slept", "name": "Through the Night", "parent": "bed",
		"desc": "Sleep until morning.", "icon": "BED"},
	{"id": "ate", "name": "A Hot Meal", "parent": "torch",
		"desc": "Cook something and eat it.", "icon": "COOKED_MEAT"},

	# Power, which is what the ship is waiting on.
	{"id": "generator", "name": "Power of Your Own", "parent": "plate",
		"desc": "Build a Generator.", "icon": "GENERATOR"},
	{"id": "charged", "name": "Charged", "parent": "generator",
		"desc": "Fill a battery at a Generator.", "icon": "BATTERY"},
	{"id": "shippower", "name": "Ship Power", "parent": "charged",
		"desc": "Put a charged battery in the ship's rack.", "icon": "POWER_BAY"},

	# Leaving.
	{"id": "thruster", "name": "Engines", "parent": "shippower",
		"desc": "Fit a thruster to the ship.", "icon": "THRUSTER"},
	{"id": "flew", "name": "Off the Ground", "parent": "thruster",
		"desc": "Fly the ship.", "icon": "COCKPIT"},
	{"id": "warp", "name": "Somewhere Else", "parent": "flew",
		"desc": "Fit a Warp Drive and leave the system.", "icon": "WARP_DRIVE"},

	# Things worth doing that are not on the way to anything.
	{"id": "read", "name": "Your Own Handwriting", "parent": "crash",
		"desc": "Read the approach survey.", "icon": "JOURNAL"},
	{"id": "boat", "name": "Wood Floats", "parent": "bench",
		"desc": "Build a boat and get in it.", "icon": "BOAT"},
]


static func by_id(id: String) -> Dictionary:
	for d in DEFS:
		if str(d["id"]) == id:
			return d
	return {}


## The block whose picture stands for this one, as an actual block id.
static func icon_id(d: Dictionary) -> int:
	var key := str(d.get("icon", ""))
	match key:
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
	return Blocks.ROCK


## Is this one visible yet? You see what you have done, and the one step past
## it. Everything further is blank -- the tree is a light held up, not a map.
static func visible_to(id: String, earned: Dictionary) -> bool:
	if earned.has(id):
		return true
	var d := by_id(id)
	if d.is_empty():
		return false
	var parent := str(d["parent"])
	return parent == "" or earned.has(parent)


## Everything you could earn next: not done, but its parent is.
static func next_steps(earned: Dictionary) -> Array:
	var out: Array = []
	for d in DEFS:
		var id := str(d["id"])
		if earned.has(id):
			continue
		var parent := str(d["parent"])
		if parent == "" or earned.has(parent):
			out.append(d)
	return out


## The tree laid out in columns: how many steps from a root this one is.
static func depth_of(id: String) -> int:
	var d := by_id(id)
	var n := 0
	while not d.is_empty() and str(d["parent"]) != "":
		n += 1
		d = by_id(str(d["parent"]))
		if n > 24:
			break
	return n
