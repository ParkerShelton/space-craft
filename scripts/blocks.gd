class_name Blocks
extends RefCounted

## Central registry of block types. Blocks are identified by a small integer id
## that gets stored in chunks / edit dictionaries. Rendering uses per-vertex
## colors (no textures needed), so each block just needs a color and a name.

const CHUNK_SIZE := 16  # voxels per chunk edge (shared constant, lives here to avoid cycles)

const AIR := 0
const ROCK := 1
const DIRT := 2
const GRASS := 3
const REGOLITH := 4  # dusty surface (moon/desert planets)
const ICE := 5
const IRON_ORE := 6
const CRYSTAL := 7
const CORE := 8      # hot planet core
const SNOW := 9
const METAL := 10    # player-placeable hull block
const COCKPIT := 11  # ship control seat (a ship needs exactly one)
const THRUSTER := 12 # ship engine (a ship needs at least one to fly)

# --- flora ---
const WOOD := 13
const WOOD_PALE := 14
const WOOD_DARK := 15
# a spectrum of leaf colors (planets pick a palette from these)
const LEAF_0 := 16   # forest green
const LEAF_1 := 17   # lime
const LEAF_2 := 18   # deep green
const LEAF_3 := 19   # olive
const LEAF_4 := 20   # autumn orange
const LEAF_5 := 21   # rust red
const LEAF_6 := 22   # golden yellow
const LEAF_7 := 23   # teal
const LEAF_8 := 24   # violet
const LEAF_9 := 25   # sky blue
const LEAF_10 := 26  # pink
const LEAF_11 := 27  # mint

const LEAF_IDS := [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]
const WOOD_IDS := [13, 14, 15]

# STONE: the hard stuff under a planet's soil, and what ore is embedded in.
# Every planet archetype currently uses ROCK for that layer -- if a world ever
# gets its own stone (basalt, chalk), add it here and every recipe that asks for
# stone accepts it with no other change. Deliberately NOT dirt, regolith, ice or
# crystal: those are soils and surfaces, not something you would build a furnace
# out of.
const STONE_IDS := [ROCK]

# --- legacy fixed ore ids (kept so old planet configs don't break; no longer
#     generated -- ores are now procedural per planet, see ORE slots below) ---
const COPPER_ORE := 28
const GOLD_ORE := 29
const TITANIUM_ORE := 30
const SILICON_ORE := 31
const URANIUM_ORE := 32
const WATER := 33  # liquid: transparent, non-collidable (rendered as a second surface)

# --- placed machines/containers (not voxel blocks) ---
const SMELTER := 34
const FABRICATOR := 35
const SHIPWORKS := 36
const CHEST := 52     # pure storage (bigger than a machine)
const CARPENTER := 62 # base-building bench: structural blocks from plain resources
## Cut for now (station upgrades will come back as their own thing). The id is
## kept only so a world saved with one loads it as a Smelter -- see
## Station.configure.
const FORGE := 63
const CLIMATE_UNIT := 64  # planet base shelter: negates hazard damage nearby
const STATION_IDS := [SMELTER, FABRICATOR, SHIPWORKS, CHEST, CARPENTER, CLIMATE_UNIT, SHAPER, GENERATOR, OXYGEN_PLANT, HEATER, COOLER, POWER_BAY, CAMPFIRE, BED, ANVIL]

# --- procedural ore slots ---------------------------------------------------
# Each planet invents its own ores (unique name + color) and assigns each to a
# generic slot id below and a universal TIER. The slot id is what gets stored in
# the voxel/edit data; the real identity (name, color, tier, props) lives in the
# planet's ore definition and travels with mined items as metadata. So Verdis and
# Frost can both have a "tier-2" ore that looks and is named completely differently.
const ORE_0 := 43
const ORE_1 := 44
const ORE_2 := 45
const ORE_3 := 46
const ORE_SLOT_IDS := [ORE_0, ORE_1, ORE_2, ORE_3]
# refined counterparts (inventory-only items the Smelter produces)
const REFINED_0 := 47
const REFINED_1 := 48
const REFINED_2 := 49
const REFINED_3 := 50
const REFINED_SLOT_IDS := [REFINED_0, REFINED_1, REFINED_2, REFINED_3]

# Universal ore tiers (0=most common/soft .. 3=exotic). A planet's ore maps to one.
const TIER_NAMES := ["Common", "Uncommon", "Rare", "Exotic"]
# base material properties per tier (h/d/e/r, 0..100); planet adds per-ore variance
const TIER_PROPS := [
	{"h": 40, "d": 40, "e": 30, "r": 15, "c": 30},
	{"h": 55, "d": 50, "e": 50, "r": 30, "c": 35},
	{"h": 72, "d": 62, "e": 68, "r": 55, "c": 40},
	{"h": 88, "d": 82, "e": 85, "r": 85, "c": 45},
]
const TIER_HARDNESS := [1.0, 1.4, 2.0, 2.8]   # base mining seconds (before hand penalty / tool)
const TIER_MIN_POWER := [1.0, 1.0, 1.6, 2.4]  # mine_power needed to break at all (hands=1.0)

# Syllables for inventing ore names (planet combines a prefix + suffix from its seed).
# --- names are identities ----------------------------------------------------
#
# Two planets that land on the same name for an ore, a creature or a plant now
# describe THE SAME THING, rather than two unrelated things wearing one label.
# It works by turning the usual arrangement around: the name is not a decoration
# generated alongside the properties, it is the SEED they are all generated
# from. Same name in, same colour, same stats, same everything out.
#
# The other half is that the name pools are partitioned -- by tier for ores, by
# kind for creatures, by species for plants -- so a name cannot belong to two
# different sorts of thing in the first place. A "-ite" is always common, a
# "-gill" is always a fish, and a "-fescue" is always the same grass.
#
# Repeats are made rare by the size of the pools, and harmless by the above.
static func identity_rng(name: String) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash(name)
	return r


const ORE_NAME_PRE := ["Vel", "Cryo", "Pyr", "Aur", "Fer", "Lum", "Xen", "Tor",
	"Zin", "Mag", "Cor", "Nyx", "Hal", "Ryn", "Quar", "Bas", "Dra", "Eos",
	"Grav", "Ith", "Kal", "Myr", "Ob", "Phos", "Sel", "Tarn", "Ulth", "Ves",
	"Wex", "Yttr", "Zeb", "Ang", "Bry", "Cind",
	# The pools are deliberately long. A repeated name is harmless now -- it is
	# the same ore -- but it should still be a thing you notice and remark on
	# rather than something that happens on the next planet along.
	"Del", "Emb", "Fyr", "Gald", "Hyx", "Irr", "Jov", "Krel", "Lath", "Mir",
	"Nal", "Osp", "Pell", "Quin", "Rav", "Syl", "Thex", "Urn", "Vand", "Wroth",
	"Xal", "Ymir", "Zor", "Ael", "Bor", "Cald", "Dros", "Ekt", "Fal", "Gorm"]
## Split by TIER, so an ore's ending says what it is: the same name can never be
## a common ore on one world and an exotic one on the next.
const ORE_NAME_SUF := [
	["ite", "ar", "ide", "ash", "stone", "grit"],     # tier 0 -- Common
	["ium", "ine", "ora", "yte", "lith", "spar"],     # tier 1 -- Uncommon
	["ex", "onite", "yr", "isk", "crys", "vein"],     # tier 2 -- Rare
	["ax", "yx", "arch", "ovar", "helion", "core"],   # tier 3 -- Exotic
]


static func ore_name(r: RandomNumberGenerator, tier: int) -> String:
	var suf: Array = ORE_NAME_SUF[clampi(tier, 0, ORE_NAME_SUF.size() - 1)]
	return ORE_NAME_PRE[r.randi() % ORE_NAME_PRE.size()] 		+ str(suf[r.randi() % suf.size()])

# Syllables for inventing PLANT names, per planet, the same way ores and
# creatures get theirs. A world whose grass is called Meadow Grass like every
# other world's grass is a world you have already been to.
#
# The ending depends on what kind of plant it is, because "Virewood" reads as a
# tree and "Virereed" does not, and a name that fights its own shape is worse
# than no name at all.
const FLORA_NAME_PRE := ["Vire", "Sable", "Mor", "Tass", "Ely", "Bram", "Silt",
	"Ashen", "Corr", "Dun", "Wyl", "Fen", "Gale", "Hesp", "Iri", "Ker", "Lune",
	"Marr", "Nyss", "Orv", "Pell", "Quill", "Rhe", "Sten", "Thry", "Umb",
	"Vess", "Wend", "Yarr", "Zell", "Alder", "Brack", "Cael", "Drift",
	# Longest of the three pools: a world grows several plants and you meet them
	# constantly, so this is where a repeat would be noticed soonest.
	"Ember", "Fallow", "Gloam", "Hollow", "Inkle", "Juniper", "Kindle",
	"Larkin", "Mellow", "Nettle", "Osier", "Prattle", "Quicken", "Rowan",
	"Sorrel", "Tamar", "Ussel", "Verdant", "Willow", "Yarrow", "Amber",
	"Bracken", "Cinder", "Dapple", "Elder", "Frost", "Golden", "Hazel",
	"Ivory", "Jasper", "Kestrel", "Linden", "Murk", "Nimble", "Oaken",
	"Pallid", "Quiver", "Russet", "Sallow", "Thicket"]


## Only the front of the name is rolled. The ending belongs to the SPECIES (see
## the `suffix` on each entry below), so a "-fescue" is the same grass on every
## world that grows one -- which is the whole point: a repeated name is a
## repeated plant, not a coincidence.
static func flora_name(r: RandomNumberGenerator, sp: Dictionary) -> String:
	var suf := str(sp.get("suffix", "grass"))
	# Skip a front that already says the ending: "Frost" + "frost" is
	# Frostfrost, and "Ashen" + "ash" is Ashenash. Both are in the pools because
	# they are good plant words, so the fix is to not put them together rather
	# than to lose them.
	for _try in 12:
		var pre := str(FLORA_NAME_PRE[r.randi() % FLORA_NAME_PRE.size()])
		var low := pre.to_lower()
		if not (low.contains(suf) or suf.contains(low)):
			return pre + suf
	return str(FLORA_NAME_PRE[r.randi() % FLORA_NAME_PRE.size()]) + suf

# Syllables for inventing creature/fish species names (per-planet, like ores).
const FAUNA_NAME_PRE := ["Grum", "Ska", "Bri", "Lox", "Fen", "Wob", "Thal", "Kree",
	"Mun", "Snap", "Grov", "Piv", "Ux", "Yar", "Zeph", "Bok", "Crin", "Dus",
	"Hesk", "Jarn", "Klu", "Morv", "Nub", "Ozz", "Prit", "Quon", "Rusk", "Tev",
	"Vunt", "Warl", "Xob", "Yeld",
	"Abb", "Blun", "Chit", "Dorv", "Emm", "Frul", "Gnash", "Hurl", "Ick",
	"Jub", "Knar", "Lurk", "Meep", "Nix", "Obb", "Purr", "Quag", "Ripp",
	"Scud", "Thrum", "Udd", "Vray", "Whel", "Yop", "Zunk", "Blep", "Crox",
	"Dweb", "Flet", "Gulp"]
## Split by KIND. A "-gill" is a fish wherever you meet it, so the same name can
## never be a fish on one world and something that walks on the next.
const FAUNA_NAME_SUF := {
	"fish":  ["gill", "fin", "scale", "minnow"],
	"air":   ["wing", "flit", "soar", "quill"],
	"cave":  ["crawler", "burrow", "grub", "creep"],
	"land":  ["back", "hide", "snout", "hopper", "beast", "hoof"],
	"npc":   ["folk", "kin", "wright", "tender"],
	"enemy": ["fang", "claw", "render", "maw"],
}


static func fauna_name(r: RandomNumberGenerator, kind: String) -> String:
	var suf: Array = FAUNA_NAME_SUF.get(kind, FAUNA_NAME_SUF["land"])
	return FAUNA_NAME_PRE[r.randi() % FAUNA_NAME_PRE.size()] 		+ str(suf[r.randi() % suf.size()])

## Planet families, and the ore each one alone holds. Every home system has at
## least one world of each family (main.gd), and the Warp Drive needs a part
## made from each signature ore -- so building one means visiting all four.
const FAMILIES := ["verdant", "dust", "frozen", "scorched"]
const FAMILY_NAMES := {"verdant": "Living world", "dust": "Dust world",
	"frozen": "Frozen world", "scorched": "Scorched world"}
const FAMILY_SIGNATURE := {
	# Living worlds: the best conductor there is, for coils and batteries.
	"verdant": {"prop": "e", "suffixes": ["volt", "flux", "spark"],
		"color": Color(0.35, 0.85, 1.0)},
	# Dust worlds: the fiercest fuel, black with soot.
	"dust": {"prop": "c", "suffixes": ["pyre", "char", "cinder"],
		"color": Color(0.95, 0.42, 0.12)},
	# Frozen worlds: an ore that reacts at a touch, for coolant.
	"frozen": {"prop": "r", "suffixes": ["rime", "quell", "frost"],
		"color": Color(0.7, 0.9, 1.0)},
	# Scorched worlds: metal so dense the heat of a warp cannot move it.
	"scorched": {"prop": "d", "suffixes": ["slag", "mass", "plumb"],
		"color": Color(0.45, 0.35, 0.3)},
}
## The ceiling on an ordinary ore's properties. Signature ores roll 88-100, so
## anything asking for more than these can only be made from one.
const ORDINARY_PROP_CAP := {"e": 74, "c": 82, "r": 74, "d": 80}

const PROP_KEYS := ["h", "d", "e", "r", "c"]
const PROP_LABELS := {"h": "Hardness", "d": "Density", "e": "Energy",
	"r": "Reactivity", "c": "Combustion"}

## Combustion turns an ore into fuel. It drives how far and how bright a torch
## made from it burns, and is the same figure that will decide how far a unit of
## warp fuel gets you -- so a volatile ore is worth hauling home whatever its
## tier. Unlike the other properties it is NOT tied to tier: a common surface
## ore can burn ferociously while a deep exotic one barely smoulders, which
## gives low-tier worlds something worth mining.
const TORCH_TIERS := 4


static func combustion_of(props: Dictionary) -> int:
	return int(props.get("c", 0))


## 0..3, the brightness step a torch made from this material burns at.
## How long a unit of ore burns, and how much power it yields -- both scaled by
## that ore's Combustion. This is what makes a volatile ore worth hauling home
## rather than being just another rock.
static func fuel_burn_time(props: Dictionary) -> float:
	return 2.0 + float(combustion_of(props)) * 0.10      # ~2 .. 12 seconds


static func fuel_power_rate(props: Dictionary) -> float:
	return 1.0 + float(combustion_of(props)) * 0.05      # ~1 .. 6 power/sec


static func is_fuel(id: int, props: Dictionary) -> bool:
	return is_ore(id) and combustion_of(props) > 0


## The Combustion at which an ore counts as FUEL rather than a metal that
## happens to smoulder. Every ore burns a little; the volatile third of them
## (see Planet._make_ore) come out at 62 or more and the rest top out at 40,
## so this line falls in the gap between the two. An ore over it sits in black,
## sooty stone in the ground, so you can tell a coal seam from a metal vein
## before you have dug any of it.
const FUEL_GRADE := 55


static func is_fuel_grade(props: Dictionary) -> bool:
	return combustion_of(props) >= FUEL_GRADE


static func conductivity_of(props: Dictionary) -> int:
	return int(props.get("r", 0))


## How many hull plates a unit of refined ore casts.
##
## This is what makes a fuel ore and a metal ore different THINGS rather than
## the same thing with different numbers on it. An ore that burns readily is a
## poor casting: it wants to go up rather than set. A dull, inert one is the
## best plate on the planet and no use at all in a generator. So you sort what
## you dig into a pile to build with and a pile to burn, which is the decision
## the property was always describing and never asked you to make.
static func plate_yield(props: Dictionary) -> int:
	return clampi(int(round(6.0 - float(combustion_of(props)) / 18.0)), 2, 5)


## How much wire a unit of ore draws. Reactivity is how well the stuff carries a
## current, so a conductive ore goes further -- the same lump gives you four
## lengths or thirteen depending on what it is.
static func wire_yield(props: Dictionary) -> int:
	return clampi(int(round(2.0 + float(conductivity_of(props)) / 8.0)), 2, 14)


## How much charge a battery built from this material holds. A cell is a thing
## for moving current about, so what it is made of decides how much it will
## take: a poor conductor is a small battery.
static func battery_capacity(props: Dictionary) -> float:
	if props.is_empty():
		return 400.0     # anything from before materials were carried
	return 200.0 + float(conductivity_of(props)) * 4.0


## How many a craft actually yields, for the ones whose output depends on what
## went into them. `base` is what the recipe says; the material has the last
## word. Anything from before materials were carried keeps the base.
static func yield_for(out: int, props: Dictionary, base: int) -> int:
	if props.is_empty():
		return base
	match out:
		METAL:
			return plate_yield(props)
		WIRE:
			return wire_yield(props)
		_:
			return base


## What an ore is FOR, in a few words, from the two properties that now decide
## it. Shown under the numbers so the numbers mean something.
static func ore_verdict(props: Dictionary) -> String:
	var c := combustion_of(props)
	var r := conductivity_of(props)
	# Read off the YIELD rather than off a second set of thresholds. Two sets of
	# bands drift apart: this said "casts the best plate" about an ore that cast
	# four, the same as the one it called middling.
	var parts: Array = []
	match plate_yield(props):
		5:
			parts.append("inert: the best plate there is, and no use as fuel")
		4:
			parts.append("steady: good plate, poor fuel")
		3:
			parts.append("lively: middling either way")
		_:
			parts.append("volatile: burns hard, casts badly")
	if c >= 62:
		parts.append("burns hot")
	elif c <= 20:
		parts.append("will barely light")
	if r >= 62:
		parts.append("conducts well")
	elif r <= 25:
		parts.append("barely conducts")
	return ", ".join(PackedStringArray(parts))


static func torch_tier_for(props: Dictionary) -> int:
	return clampi(int(floor(float(combustion_of(props)) / 26.0)), 0, TORCH_TIERS - 1)

# --- crafted gear (inventory-only tools produced at stations) ---
const DRILL := 51            # mining tool; its power (from its material) sets mine speed & max tier
# 55 was the O2 Tank (extra suit oxygen). Removed -- personal air is being
# reworked around refillable base/ship tanks instead. The id stays reserved so
# an old save's leftover item still resolves to a name instead of garbage.
const O2_TANK := 55
const SUIT := 56             # worn gear: reduces hazard damage (insulation from Density)
const WEAPON := 59           # melee weapon: its damage (from its material) beats bare hands
const TOOL_IDS := [DRILL, SUIT, WEAPON, PULSE_PISTOL, WRENCH, PICK, AXE, SPADE, SWORD, HAMMER]

const LIFE_SUPPORT := 53     # ship block: with a sealed interior it makes the ship habitable
const GLASS := 54            # transparent, solid hull -- windows that still seal a cabin
const DOOR := 57             # closed door: solid, seals, collides
const DOOR_OPEN := 58        # open door: passable, does NOT seal (air escapes)

# --- intermediate materials (Smelter combines refined + a base resource into
#     these; specific stations build FROM them instead of raw refined material,
#     so not everything is gated behind "refine ore and you're done") ---
const ALLOY := 60      # refined + Metal -> structural stock (Shipworks: Thruster, Life Support)
const CIRCUIT := 61    # refined + Metal -> functional stock (Fabricator: Drill, Suit, Weapon)
const INTERMEDIATE_IDS := [ALLOY, CIRCUIT, BAR, SHEET, SCRAP, PLATE]

const INTERFACE := 65  # placeable trigger block: surround it with a recognized shell
						# pattern (see MULTIBLOCK_RECIPES) to build a bigger structure
const ROOF_SLAB := 66   # half-height roof block (real partial-height geometry, like water)
const PATH := 67         # worn dirt/gravel walkway generated between settlement buildings
const WARP_DRIVE := 68   # ship block: with the ship in space, unlocks the star map for warp travel
const PULSE_PISTOL := 69 # ranged weapon: fires a traveling energy bolt, damage from its material

# --- block shaping -----------------------------------------------------------
# SHAPER is a bench that reshapes a plain block into other FORMS of the same
# material. It deliberately has no fixed recipe list: you load a block and it
# offers whatever shapes that material supports, so adding a new shape later
# (stairs, pillars) costs one entry here and works for every material at once,
# instead of one recipe per material per shape.
const SHAPER := 70       # "Block Shaper" bench: reshape a block into slabs etc.

## The only blocks that emit light. Nights are genuinely dark and caves are
## carved deep, so a light source is what makes either of them explorable
## rather than a wall of black.
const TORCH := 91        # small standing flame: cheap, bright, warm
const GLOW_LAMP := 92     # full block of steady light, for finished builds
const EMBER_TORCH := 93   # torch burning a combustible ore -- brightness from its Combustion
const LIGHT_IDS := [TORCH, GLOW_LAMP, EMBER_TORCH]

## Brightness step baked into a placed ember torch. Packed above the id (the
## bits stairs use for facing -- a block is one or the other, never both)
## because a placed voxel is a bare int and cannot carry the item's properties.
const TORCH_TIER_SHIFT := 16
const TORCH_TIER_MASK := 0x3


static func make_torch(id: int, tier: int) -> int:
	return (id & ID_MASK) | ((tier & TORCH_TIER_MASK) << TORCH_TIER_SHIFT)


static func torch_tier_of(v: int) -> int:
	return (v >> TORCH_TIER_SHIFT) & TORCH_TIER_MASK


static func is_light(id: int) -> bool:
	return id in LIGHT_IDS


## Light radius and colour per light block.
## Emission level 0..15 for a light block, Minecraft-style: this is how many
## blocks its light carries before it dies out.
static func light_level(raw: int) -> int:
	var id := bottom_of(raw)
	# Light falls off a level per block, so these ARE the reach in blocks: a
	# torch at 11 lit a room you could cross in four strides, which is not what
	# a torch is for. Fifteen is the ceiling the flood fill can carry (it is a
	# byte per cell, and Chunk.LIGHT_PAD is sized to match), so a torch now
	# reaches nearly as far as light can go and the better lights edge past it.
	if id == EMBER_TORCH:
		return 12 + torch_tier_of(raw)     # 12..15, brighter ore burns further
	if id == TORCH:
		return 14
	if id == GLOW_LAMP:
		return 15
	return 0


static func light_def(raw: int) -> Dictionary:
	var id := bottom_of(raw)
	if id == EMBER_TORCH:
		# The whole point of a combustible ore: a fiercely burning one throws
		# light most of the way across a cavern, a dull one barely beats a
		# plain torch.
		var t := float(torch_tier_of(raw))
		return {"range": 13.0 + t * 4.5, "energy": 1.6 + t * 0.45,
			"color": Color(1.0, 0.66, 0.30).lerp(Color(1.0, 0.93, 0.72), t / 3.0)}
	if id == TORCH:
		return {"range": 14.0, "energy": 1.6, "color": Color(1.0, 0.72, 0.38)}
	return {"range": 15.0, "energy": 1.8, "color": Color(0.92, 0.95, 1.0)}

# Half-height version of each shapeable material. One id per material is still
# needed because slabs are real inventory items you carry and place; the SHAPE
# side of the matrix is what stays open-ended.
const ROCK_SLAB := 71
const DIRT_SLAB := 72
const GRASS_SLAB := 73
const REGOLITH_SLAB := 74
const ICE_SLAB := 75
const SNOW_SLAB := 76
const CRYSTAL_SLAB := 77
const METAL_SLAB := 78
const WOOD_SLAB := 79
const GLASS_SLAB := 80
# Sawn boards get their own slabs and stairs, one per timber rather than one
# shared "plank" shape. A log already keeps its species through the saw (see
# PLANK_OF); losing it again at the next cut would mean a pale house could not
# have a pale staircase.
const PLANK_SLAB := 130
const PLANK_PALE_SLAB := 131
const PLANK_DARK_SLAB := 132
const PLANK_STAIR := 133
const PLANK_PALE_STAIR := 134
const PLANK_DARK_STAIR := 135
# Logs cut the same way. WOOD_SLAB and WOOD_STAIR stay the plain timber's own
# shapes rather than being retired, so anything already standing in a saved
# world is still the block it was built from.
const WOOD_PALE_SLAB := 136
const WOOD_DARK_SLAB := 137
const WOOD_PALE_STAIR := 138
const WOOD_DARK_STAIR := 139

## material -> its slab. Drives both the Shaper's offered shapes and meshing.
const SLAB_OF := {
	ROCK: ROCK_SLAB, DIRT: DIRT_SLAB, GRASS: GRASS_SLAB, REGOLITH: REGOLITH_SLAB,
	ICE: ICE_SLAB, SNOW: SNOW_SLAB, CRYSTAL: CRYSTAL_SLAB, METAL: METAL_SLAB,
	WOOD: WOOD_SLAB, WOOD_PALE: WOOD_PALE_SLAB, WOOD_DARK: WOOD_DARK_SLAB,
	GLASS: GLASS_SLAB,
	PLANK: PLANK_SLAB, PLANK_PALE: PLANK_PALE_SLAB, PLANK_DARK: PLANK_DARK_SLAB,
}
## slab -> the material it is made of. Colour, name and surface texturing all
## come from the material, so a slab never needs its own palette entry.
# Stairs, one id per material like slabs. FACING and the corner flag are packed
# into the placed voxel (see make_stair), not baked into the id -- otherwise
# every material would need eight ids instead of one.
const ROCK_STAIR := 81
const DIRT_STAIR := 82
const GRASS_STAIR := 83
const REGOLITH_STAIR := 84
const ICE_STAIR := 85
const SNOW_STAIR := 86
const CRYSTAL_STAIR := 87
const METAL_STAIR := 88
const WOOD_STAIR := 89
const GLASS_STAIR := 90

const STAIR_OF := {
	ROCK: ROCK_STAIR, DIRT: DIRT_STAIR, GRASS: GRASS_STAIR, REGOLITH: REGOLITH_STAIR,
	ICE: ICE_STAIR, SNOW: SNOW_STAIR, CRYSTAL: CRYSTAL_STAIR, METAL: METAL_STAIR,
	WOOD: WOOD_STAIR, WOOD_PALE: WOOD_PALE_STAIR, WOOD_DARK: WOOD_DARK_STAIR,
	GLASS: GLASS_STAIR,
	PLANK: PLANK_STAIR, PLANK_PALE: PLANK_PALE_STAIR, PLANK_DARK: PLANK_DARK_STAIR,
}
const STAIR_MATERIAL := {
	ROCK_STAIR: ROCK, DIRT_STAIR: DIRT, GRASS_STAIR: GRASS, REGOLITH_STAIR: REGOLITH,
	ICE_STAIR: ICE, SNOW_STAIR: SNOW, CRYSTAL_STAIR: CRYSTAL, METAL_STAIR: METAL,
	WOOD_STAIR: WOOD, GLASS_STAIR: GLASS,
	WOOD_PALE_STAIR: WOOD_PALE, WOOD_DARK_STAIR: WOOD_DARK,
	PLANK_STAIR: PLANK, PLANK_PALE_STAIR: PLANK_PALE, PLANK_DARK_STAIR: PLANK_DARK,
}

const SLAB_MATERIAL := {
	ROCK_SLAB: ROCK, DIRT_SLAB: DIRT, GRASS_SLAB: GRASS, REGOLITH_SLAB: REGOLITH,
	ICE_SLAB: ICE, SNOW_SLAB: SNOW, CRYSTAL_SLAB: CRYSTAL, METAL_SLAB: METAL,
	WOOD_SLAB: WOOD, GLASS_SLAB: GLASS,
	WOOD_PALE_SLAB: WOOD_PALE, WOOD_DARK_SLAB: WOOD_DARK,
	PLANK_SLAB: PLANK, PLANK_PALE_SLAB: PLANK_PALE, PLANK_DARK_SLAB: PLANK_DARK,
}


static func is_slab(id: int) -> bool:
	return SLAB_MATERIAL.has(id)


static func is_stair(id: int) -> bool:
	return STAIR_MATERIAL.has(id)


# --- placed-stair orientation ------------------------------------------------
# A stair's FACING (which way you climb) and whether it is a corner are packed
# into the stored voxel above the id, so one stair id per material covers all
# eight placements instead of needing an id each.
const FACING_SHIFT := 16
const FACING_MASK := 0x3
const VARIANT_SHIFT := 18
const VARIANT_MASK := 0x3

## Stair shapes, cycled with R before placing. Stored as an index rather than a
## flag so more can be added without changing the packing or the key handling.
## Only two SHAPES exist: a straight run and a corner. A second corner variant
## would be redundant -- rotating the corner through its four facings already
## reaches all four corner quarters.
const STAIR_VARIANTS := ["Straight", "Corner"]
const STAIR_STRAIGHT := 0
const STAIR_CORNER := 1

## Every placeable stair state, cycled in order by R: the straight run turned
## through all four quarters, then the corner through all four. Facing is part
## of the cycle rather than taken from the camera, so what you see previewed is
## exactly what you get.
const STAIR_STATES := 8


static func stair_state_facing(state: int) -> int:
	return state % 4


static func stair_state_variant(state: int) -> int:
	return STAIR_STRAIGHT if state < 4 else STAIR_CORNER


static func stair_state_name(state: int) -> String:
	return "%s  %d°" % [STAIR_VARIANTS[stair_state_variant(state)],
		stair_state_facing(state) * 90]


## Upside down: the solid half on top and the step hanging below it, for the
## underside of a staircase and for eaves. Above the facing and the variant.
const STAIR_FLIP_SHIFT := 20

static func make_stair(stair_id: int, facing: int, variant: int, flipped := false) -> int:
	return (stair_id & ID_MASK) 		| ((facing & FACING_MASK) << FACING_SHIFT) 		| ((variant & VARIANT_MASK) << VARIANT_SHIFT) 		| ((1 if flipped else 0) << STAIR_FLIP_SHIFT)


static func stair_flipped_of(v: int) -> bool:
	return ((v >> STAIR_FLIP_SHIFT) & 1) == 1


static func stair_facing_of(v: int) -> int:
	return (v >> FACING_SHIFT) & FACING_MASK


static func stair_variant_of(v: int) -> int:
	return (v >> VARIANT_SHIFT) & VARIANT_MASK


static func stair_variant_name(variant: int) -> String:
	return STAIR_VARIANTS[variant % STAIR_VARIANTS.size()]


# --- log orientation ---------------------------------------------------------
# A log records which way its trunk runs, so the cut ends land on the right two
# faces. Without it, "which face is the cut end" has to be guessed from the
# planet's up, which is only right for an upright trunk. Packed in the same
# bits stairs use for facing -- a block is one or the other, never both.
# Surface-mounted conduit: which of its cell's six faces the wire clings to,
# stored +1 so 0 means "not placed against anything" (world-gen / hand-given).
# Kept clear of the log-axis and stair bits below.
# A BITMASK of the faces a wire clings to, not a single face: one cell can carry
# a run along its floor and another up its wall, so a cable turns a corner inside
# one block instead of needing two. 0 means "not placed against anything".
const WIRE_FACE_SHIFT := 24
const WIRE_FACE_MASK := 0x3F

static func is_wire(id: int) -> bool:
	return id == WIRE

## Bitmask over Chunk._WFACE indices; 0 when unset.
static func wire_faces_of(v: int) -> int:
	return int((v >> WIRE_FACE_SHIFT) & WIRE_FACE_MASK)

static func wire_with_faces(mask: int) -> int:
	return WIRE | ((mask & WIRE_FACE_MASK) << WIRE_FACE_SHIFT)

## Add one face to whatever this cell already carries.
static func wire_add_face(v: int, face: int) -> int:
	return wire_with_faces(wire_faces_of(v) | (1 << face))


const LOG_AXIS_SHIFT := 16
const LOG_AXIS_MASK := 0x3
const AXIS_X := 0
const AXIS_Y := 1
const AXIS_Z := 2


## Stored as axis+1 so that 0 means "no axis recorded". A plain WOOD id from
## world generation has all-zero high bits, and reading that as axis 0 made
## every naturally grown trunk render as though it were lying along X.
static func make_log(wood_id: int, axis: int) -> int:
	return (wood_id & ID_MASK) | (((axis + 1) & LOG_AXIS_MASK) << LOG_AXIS_SHIFT)


## The trunk axis, or -1 when the log doesn't record one (grown, not placed).
static func log_axis_of(v: int) -> int:
	return (((v >> LOG_AXIS_SHIFT) & LOG_AXIS_MASK)) - 1


# --- stacked slabs -----------------------------------------------------------
# Two DIFFERENT slabs can share one voxel (a rock slab with a wood slab on top).
# Rather than inventing an id for every pair -- 10 materials would need 45 --
# the second slab is packed into the high bits of the stored voxel value.
# Two slabs of the SAME material never take this path: they merge into the plain
# full block instead, which is both simpler and what you'd expect.
const TOP_SHIFT := 8
const ID_MASK := 0xFF


static func make_stacked(bottom: int, top: int) -> int:
	return (bottom & ID_MASK) | ((top & ID_MASK) << TOP_SHIFT)


## The slab sitting in the upper half of a voxel, or AIR if there isn't one.
static func top_slab_of(v: int) -> int:
	return (v >> TOP_SHIFT) & ID_MASK


## The block occupying the lower half (or the whole) of a voxel.
static func bottom_of(v: int) -> int:
	return v & ID_MASK


static func is_stacked_slab(v: int) -> bool:
	return top_slab_of(v) != AIR


## What a voxel becomes when `placing` is put on top of the slab already in it.
## Returns AIR when the two don't combine, so the caller falls back to normal
## placement in the next voxel up.
##   same material      -> the plain full block (two halves make a whole)
##   different material -> both slabs packed into the one voxel
static func stack_result(existing: int, placing: int) -> int:
	if not is_slab(existing) or not is_slab(placing):
		return AIR
	if existing == placing:
		return base_material_of(placing)
	return make_stacked(existing, placing)


## The material a shaped block is made of -- itself, if it isn't shaped.
static func base_material_of(id: int) -> int:
	if STAIR_MATERIAL.has(id):
		return int(STAIR_MATERIAL[id])
	return SLAB_MATERIAL.get(id, id)


## Every shape `mat` can be turned into at a Shaper, as
## {"label", "out", "n", "cost_n"}. One entry per SHAPE, not per material.
static func shapes_for(mat: int) -> Array:
	var out: Array = []
	# Sawing a log is the one shape that MULTIPLIES: one log gives four boards,
	# and they keep the timber they came from.
	if PLANK_OF.has(mat):
		out.append({"shape": "Planks", "out": int(PLANK_OF[mat]), "n": 4, "cost_n": 1})
	if SLAB_OF.has(mat):
		out.append({"shape": "Slab", "out": int(SLAB_OF[mat]), "n": 2, "cost_n": 1})
	if STAIR_OF.has(mat):
		out.append({"shape": "Stairs", "out": int(STAIR_OF[mat]), "n": 1, "cost_n": 1})
	return out

# A 3x3x3 shell of `shell` around a placed INTERFACE block collapses into a
# `result` station -- the multiblock alternative to just crafting a plain item.
## The block you interact with to assemble and operate a built machine. Placing
## one is how you declare "a machine goes here"; it is worthless on its own.
const MACHINE_CORE := 94
## Burns combustible ore for power. Deliberately has no single-block version:
## a generator is the kind of thing whose whole point is that it's big.
const GENERATOR := 95
const OXYGEN_PLANT := 96  # multiblock: floods a SEALED room with breathable air
const HEATER := 97        # multiblock: warms a sealed room on a cold world
const COOLER := 98        # multiblock: the opposite -- sheds heat on a scorching one
const WIRE := 99          # planet-side conduit: carries power between machines
const BATTERY := 100      # carried charge: fill it at a base, empty it into a ship
const POWER_BAY := 101    # ship station: batteries in, ship tanks filled

# --- eighth-block PARTS -------------------------------------------------------
# A voxel holding PARTS is a marker: its real contents are eight sub-cells kept
# in the planet's parts table, addressed as sx + sy*2 + sz*4. Machines are meant
# to be BUILT rather than conjured from a menu, and a full cube is too coarse a
# brush for a workbench leg or a control panel.
const PARTS := 102
const WRENCH := 103       # right-click a build with this to turn it into a station

# Sawn boards, one per timber. A log keeps its species through the saw, so a
# pale forest builds a pale house -- the material is the player's signature and
# turning every wood into one generic plank would throw that away.
const PLANK := 104
const PLANK_PALE := 105
const PLANK_DARK := 106

# --- food and animal products ---------------------------------------------
# Dropped by wildlife, not mined. Meat is the whole point of hunting: raw keeps
# you alive in a pinch, cooked is what actually feeds you (see FOOD_VALUE).
const RAW_MEAT := 107
const COOKED_MEAT := 108
const HIDE := 109
const BONE := 110
## A fire you can cook on, built from a single 2x2 layer of wood eighths --
## the cheapest structure in the game, because going hungry should not be
## gated behind a workshop.
const CAMPFIRE := 111
## Ground cover: thin blades standing on soil. Not something you stand on -- it
## has no collision and you walk straight through it.
const TALL_GRASS := 112
## What tall grass sometimes leaves behind. Not placeable: it is planted, which
## is a different verb and will want its own rules (see farming).
const SEEDS := 113
## A young tree. Like SEEDS, one id for every species -- which one it is rides
## in its props.
const SAPLING := 114
## Soil worked for planting. Crops will only take root in it, which is what
## makes a farm a place you built rather than a patch of ground you found.
const TILLED := 115
## A planted crop, at whatever stage it has reached. Which plant it is and how
## far along it has come live in the planet's crop table, not in the id -- the
## same arrangement eighth-blocks and campfires already use, and for the same
## reason: there is no room in a byte for a species.
const CROP := 116
## A tree on its way up. Skinny, and deliberately not breakable yet.
const YOUNG_TREE := 117
## Worked wood on a handle. Turns ground into something you can plant in.
const HOE := 118
## A meal made of what you grew. One dish for now -- later, which plants went
## into it is what will separate a good meal from a filling one.
const COOKED_CROP := 119
## Ground bone, spread on a growing plant to push it one stage on. The first
## thing Bone has ever been for -- and the first time hunting feeds farming
## rather than the two lines running past each other.
const BONEMEAL := 120
## Soft stock: the second line of materials, next to metal. Fibre is cut from
## the crops that were never worth eating, Leather is what Hide becomes, and
## both meet at Cloth -- so a bed, a bag or a coat costs a field and a hunt
## rather than another ingot.
const FIBRE := 121
const CLOTH := 122
const LEATHER := 123
## Built in the world out of eighths, like the Campfire, rather than crafted as
## an item. Its job is your respawn point: somewhere you chose, instead of the
## one spot on the home world every death sends you back to.
const BED := 124
## Water you can carry. Two ids rather than one with a flag, so a glance at the
## bar tells you whether it is full -- and so a full one stacks separately from
## the empties, which is the whole point of carrying several.
##
## What it is FOR is farming: tilled soil has to be near water (see
## Player.TILL_RANGE), which without this means every field is on a shoreline.
const BUCKET := 125
const WATER_BUCKET := 126
## The first three tools, and the only ones that exist before you have smelted
## anything. Each is better than a hand at ONE kind of material and no better
## anywhere else, so carrying all three is a real early-game decision about what
## you are going out to do. The Drill supersedes the lot: it is every class at
## once, which is what makes it the last tool you need rather than a fourth one.
const PICK := 127
const AXE := 128
const SPADE := 129
## Rock on a wooden grip: the first thing you can fight with that beats a fist,
## made at the same bench as the tools and from the same two materials.
const SWORD := 140

## A small wooden boat. Not a block: you set it down on water and it becomes a
## thing that floats (see boat.gd). Well clear of the cosmetics, which run from
## Cosmetics.FIRST_ID upward, and well under ID_MASK.
const BOAT := 200

## The last crew's journal. Not a tool and not a block: a thing you read, and
## the only place this game ever says anything about who was here before you.
const JOURNAL := 201

## Hull plate that came down with the wreck and did not survive it: split
## through, buckled, held together by habit. It is only ever found lying in the
## wreckage, never made. Work at it and it comes apart in your hands -- by hand
## if need be, slowly -- and leaves nothing worth keeping, which is what makes
## it the lid you lift rather than the metal you take. Past the cosmetics, which
## run from Cosmetics.FIRST_ID, and well under ID_MASK.
const CRACKED_METAL := 202

# --- smithing -------------------------------------------------------------------
#
# Refined ore comes out of the smelter as an INGOT. Put one on an ANVIL and
# strike it with a HAMMER, and it is beaten through a Bar and a Sheet into
# Hull Plate -- take it off at whichever of those you want. Keep hitting past
# plate and it cracks, and then it is SCRAP, which only the smelter can turn
# back into an ingot. How many strikes each stage takes is the ore's Hardness;
# how many plates one ingot gives is its Density (see smith_stages).
#
# Bars, sheets and scrap each remember the ingot they were beaten from (in
# their `mat`), so they carry its stats and remelt back into it.
const HAMMER := 203    # carpenter's bench: wood and rock. Strikes, does not mine.
const ANVIL := 204     # carpenter's bench: ingots. Holds one workpiece on top.
const BAR := 205
const SHEET := 206
const SCRAP := 207
## What the anvil's last stage gives: a flat plate, as a PART -- the thing a
## generator, a heater or a power bay is built from. It is not hull. Hull is a
## ship block, pressed out of four plates at the Press (see PRESS_RECIPES).
## How many plates one ingot gives is the ore's Density (plate_yield).
const PLATE := 208

# The Warp Drive's four parts, one from each planet family's signature ore (see
# FAMILY_SIGNATURE). Each asks for stock of an ore good enough at ONE property
# that no ordinary ore reaches it -- so each part is a trip to its own world.
const WARP_COIL := 209          # bars of a conductor (Energy) wound round with wire
const IGNITION_CHARGE := 210    # ingots of a fierce fuel (Combustion) in a sheet casing
const COOLANT_JACKET := 211     # a reactive sheet (Reactivity), glass and ice
const CONTAINMENT_SHELL := 212  # plates of a very dense metal (Density)

# --- containers -----------------------------------------------------------------
#
# Three of them, and the difference between them is the whole point. A wooden
# chest is a box: it holds what it holds, and two of them side by side are two
# boxes, not a bigger one. A Wide Chest is the same idea built properly, for
# when one box is not enough and you do not yet have metal to spare.
#
# A Cargo Module is the sci-fi answer, and it is the only one that JOINS: set
# them against each other and the bank opens as one store. On its own it barely
# beats a chest. Four of them together beat everything, which is what you are
# paying plate, wire and a circuit for.
const CHEST_WIDE := 213    # carpenter's bench: two chests' worth, one lid
const CARGO_MODULE := 214  # press + fabricator stock: banks with its neighbours
## How good the ore has to be. Signature ores roll 88-100; ordinary ores stop
## at ORDINARY_PROP_CAP.
const WARP_GRADE := {"e": 80, "c": 85, "r": 80, "d": 85}
const WARP_PARTS := [WARP_COIL, IGNITION_CHARGE, COOLANT_JACKET, CONTAINMENT_SHELL]

const SWORD_DAMAGE := 6.0

## How many uses each tool has in it before it breaks: a block broken, a patch
## tilled, a hit landed, a shot fired. Anything not listed never wears out.
const DURABILITY := {
	PICK: 150, AXE: 150, SPADE: 150, HOE: 120, SWORD: 130, HAMMER: 400,
	DRILL: 1500, WEAPON: 500, PULSE_PISTOL: 400,
}


static func max_durability(id: int) -> int:
	return int(DURABILITY.get(id, 0))


## How many of an item one slot holds. Things that wear out are one to a slot,
## since each carries its own wear.
## Whether two stacks are the same thing and may merge: the same item, from
## the same world, of the same ore, with the same stats. What something is made
## of decides how good it is, so two ores' worth never pool into one stack
## that quietly takes the stats of whichever came first.
static func same_stack(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("id", -1)) == int(b.get("id", -2)) \
		and str(a.get("src", "")) == str(b.get("src", "")) \
		and str((a.get("mat", {}) as Dictionary).get("name", "")) \
			== str((b.get("mat", {}) as Dictionary).get("name", "")) \
		and (a.get("props", {}) as Dictionary) == (b.get("props", {}) as Dictionary)


## A placed block's TAG: everything the item it was placed from knew about
## itself -- its ore stats at the top level (so a ship reads "e" and "d" straight
## off it), and its material and home world under "_mat" and "_src". Empty for
## plain blocks. Planets keep one per cell and ships one per block, so what
## comes back out when it is mined is exactly what went in.
static func make_tag(props: Dictionary, mat: Dictionary, src: String) -> Dictionary:
	var t: Dictionary = props.duplicate(true) if props != null else {}
	if mat != null and not mat.is_empty():
		t["_mat"] = mat.duplicate(true)
	if src != "":
		t["_src"] = src
	return t


## The item a tag describes: {"props", "mat", "src"}.
static func untag(t: Dictionary) -> Dictionary:
	var props := {}
	for k in t:
		if not str(k).begins_with("_"):
			props[k] = t[k]
	return {"props": props, "mat": (t.get("_mat", {}) as Dictionary).duplicate(true),
		"src": str(t.get("_src", ""))}


static func stack_cap(id: int, normal: int) -> int:
	# A battery is one to a slot for the same reason a tool is: each carries its
	# own state. Stacking them pooled two different charges into one slot and
	# the difference simply vanished.
	if id == BATTERY:
		return 1
	return 1 if DURABILITY.has(id) else normal

## What each tool is for, and how much better than bare hands it is at it.
## `reach` is added to how far you can touch the world -- a tool is a thing on
## the end of your arm, and it is the cheapest way to make one feel like one.
const TOOLS := {
	PICK:  {"class": "rock", "power": 2.4, "reach": 0.8, "label": "Pick"},
	AXE:   {"class": "wood", "power": 2.4, "reach": 0.8, "label": "Axe"},
	SPADE: {"class": "soil", "power": 2.4, "reach": 0.6, "label": "Spade"},
}
## How far a Drill reaches, on top of the base. It is the end of the tool line,
## so it is also the longest arm.
const DRILL_REACH := 1.6


## Which kind of material a block is, for deciding whether a tool helps with it.
## Empty means "nothing helps": glass, metal, crafted things -- a hand is as good
## as anything else on those, and gating them would only be busywork.
static func material_class(id: int) -> String:
	# Through the shape as well as through the stacking: a plank stair is wood,
	# and an axe should know that.
	var b := base_material_of(bottom_of(id))
	if b in STONE_IDS or is_ore(b) or b == CRYSTAL:
		return "rock"
	if is_wood(b) or b in PLANK_IDS or is_leaf(b):
		return "wood"
	if b == DIRT or b == GRASS or b == REGOLITH or b == SNOW or b == ICE or b == TILLED:
		return "soil"
	return ""


## Is this something bare hands simply cannot break?
##
## ORE, and only ore. Rock itself stays hand-workable, slowly, and that is not a
## softening -- it is the only way the line closes. A Pick costs wood and rock;
## if rock needed a Pick you would need a Pick to make a Pick, and a new world
## would be unplayable from the first swing. So hands get you wood, soil and
## rock; rock and wood get you the tools; the tools get you ore; ore gets you
## the Drill, which gets you everything.
##
## Bare hands are still slow at rock -- two and a quarter seconds against a
## Pick's under one -- so the tool is worth making long before it is required.
## Things bare hands cannot take apart at all, however long you hold the button.
##
## Ore, because a seam is not something you pull out with your fingers -- and
## metal plate, which is the same argument. A hull is a welded sheet: you get it
## off with a pick, and until you have one the ship you woke up in stays the
## shape it is rather than being quietly dismantled a plate at a time.
static func needs_tool(id: int) -> bool:
	var b := bottom_of(id)
	return is_ore(b) or b == METAL or b == METAL_SLAB or b == METAL_STAIR 		or b == ALLOY or b == COCKPIT or b == THRUSTER or b == LIFE_SUPPORT 		or b == WARP_DRIVE
const PLANK_IDS := [PLANK, PLANK_PALE, PLANK_DARK]
const PLANK_OF := {WOOD: PLANK, WOOD_PALE: PLANK_PALE, WOOD_DARK: PLANK_DARK}
const PART_DIM := 2                    # sub-cells per axis
const PART_COUNT := PART_DIM * PART_DIM * PART_DIM

static func part_index(sx: int, sy: int, sz: int) -> int:
	return sx + sy * PART_DIM + sz * PART_DIM * PART_DIM

## Can this item be placed as an eighth rather than a full cube? Building
## materials can, so a leg can be wood and a panel metal; loose gear cannot.
static func is_partable(id: int) -> bool:
	return id == ALLOY or id == CIRCUIT or (id in PLACEABLE and not is_station(id))

## How much hunger each food restores. Raw meat is deliberately poor value: it
## keeps you going, but cooking it is worth roughly four times as much, which is
## what makes a campfire worth building the moment you start hunting.
const FOOD_VALUE := {
	RAW_MEAT: 9.0,
	COOKED_MEAT: 38.0,
	# A crop is an INGREDIENT, not a snack. Meat you can gnaw raw and regret;
	# a handful of grain is not a meal until somebody cooks it, so the only way
	# a field feeds you is through a fire.
	COOKED_CROP: 30.0,
}

static func is_food(raw: int) -> bool:
	return FOOD_VALUE.has(bottom_of(raw))


static func food_value(raw: int) -> float:
	return float(FOOD_VALUE.get(bottom_of(raw), 0.0))


## What a station costs to put down, in the order they should be offered. This
## is the whole of station building now: you hold the station ring open, pick
## one, and these come out of your pockets when it lands.
##
## Early things ask for what you can pick up with your hands; the late ones ask
## for everything the line before them made, which is what keeps the order of
## the list the order you build in.
const STATION_BUILDS := [
	{"kind": CAMPFIRE, "reqs": [{"any": WOOD_IDS, "n": 4, "label": "Wood"},
		{"any": STONE_IDS, "n": 4, "label": "Rock"}]},
	{"kind": CARPENTER, "reqs": [{"any": WOOD_IDS, "n": 8, "label": "Wood"}]},
	{"kind": CHEST, "reqs": [{"any": WOOD_IDS, "n": 8, "label": "Wood"}]},
	{"kind": CHEST_WIDE, "reqs": [{"any": WOOD_IDS, "n": 18, "label": "Wood"}]},
	# Plate for the shell, wire for the rails it joins along, and one circuit
	# for the thing that makes a row of them read as one store. Deliberately
	# past the Fabricator: it is a chest, and it should not arrive before metal.
	{"kind": CARGO_MODULE, "reqs": [{"id": PLATE, "n": 5}, {"id": WIRE, "n": 3},
		{"id": CIRCUIT, "n": 1}]},
	{"kind": BED, "reqs": [{"any": WOOD_IDS, "n": 6, "label": "Wood"},
		{"any": [CLOTH, LEATHER], "n": 4, "label": "Cloth or Leather"}]},
	{"kind": SHAPER, "reqs": [{"any": WOOD_IDS, "n": 8, "label": "Wood"},
		{"any": STONE_IDS, "n": 6, "label": "Rock"}]},
	{"kind": SMELTER, "reqs": [{"any": STONE_IDS, "n": 12, "label": "Rock"},
		{"any": WOOD_IDS, "n": 4, "label": "Wood"}]},
	{"kind": GENERATOR, "reqs": [{"id": PLATE, "n": 10}, {"id": WIRE, "n": 4}]},
	{"kind": POWER_BAY, "reqs": [{"id": PLATE, "n": 12}, {"id": BATTERY, "n": 1}]},
	{"kind": HEATER, "reqs": [{"any": STONE_IDS, "n": 10, "label": "Rock"},
		{"id": PLATE, "n": 6}]},
	{"kind": COOLER, "reqs": [{"id": GLASS, "n": 6}, {"id": PLATE, "n": 10}]},
	{"kind": OXYGEN_PLANT, "reqs": [{"id": GLASS, "n": 6}, {"id": PLATE, "n": 8}]},
	{"kind": CLIMATE_UNIT, "reqs": [{"id": PLATE, "n": 8}, {"id": CIRCUIT, "n": 2}]},
	# The Press is metal and nothing else: plates for the frame and the bed,
	# bars for the uprights and the ram. It is where circuitry comes FROM now,
	# so it cannot ask for any.
	{"kind": FABRICATOR, "reqs": [{"id": PLATE, "n": 4}, {"id": BAR, "n": 2}]},
	{"kind": SHIPWORKS, "reqs": [{"id": PLATE, "n": 20}, {"id": ALLOY, "n": 6}]},
]


## The station ring's first level. Each category is a family of stations, so
## the ring stays readable however many there are: better smelters, bigger
## benches and the like join their family rather than crowding the ring.
## "icon" is the station whose picture stands for the whole family.
const STATION_CATEGORIES := [
	{"name": "Camp", "icon": CAMPFIRE, "kinds": [CAMPFIRE, BED]},
	{"name": "Containers", "icon": CHEST, "kinds": [CHEST, CHEST_WIDE, CARGO_MODULE]},
	{"name": "Crafters", "icon": CARPENTER, "kinds": [CARPENTER, SHAPER, FABRICATOR, SHIPWORKS]},
	{"name": "Smelters", "icon": SMELTER, "kinds": [SMELTER]},
	{"name": "Power", "icon": GENERATOR, "kinds": [GENERATOR, POWER_BAY]},
	{"name": "Climate", "icon": OXYGEN_PLANT, "kinds": [OXYGEN_PLANT, HEATER, COOLER, CLIMATE_UNIT]},
]


## The ring's categories with each station's build entry filled in. A station
## that was added to STATION_BUILDS but never given a family still shows up,
## under "Other", rather than silently becoming unbuildable.
static func station_categories() -> Array:
	var out: Array = []
	var placed := {}
	for c in STATION_CATEGORIES:
		var builds: Array = []
		for k in c["kinds"]:
			for b in STATION_BUILDS:
				if int(b["kind"]) == int(k):
					builds.append(b)
					placed[int(k)] = true
		if not builds.is_empty():
			out.append({"name": c["name"], "icon": int(c["icon"]), "builds": builds})
	var rest: Array = []
	for b in STATION_BUILDS:
		if not placed.has(int(b["kind"])):
			rest.append(b)
	if not rest.is_empty():
		out.append({"name": "Other", "icon": int(rest[0]["kind"]), "builds": rest})
	return out


## What one station costs, or [] if it is not something you can put down.
static func station_cost(kind: int) -> Array:
	for b in STATION_BUILDS:
		if int(b["kind"]) == kind:
			return b["reqs"]
	return []


static func is_station_build(kind: int) -> bool:
	return not station_cost(kind).is_empty()


## Every recipe in the game, flattened into one list the Recipe Book can show.
##
## Each entry carries a STABLE key, so unlocking recipes as you progress is a
## matter of remembering keys rather than reshaping this list.
static func all_recipes() -> Array:
	var out: Array = []
	for r in HAND_RECIPES:
		out.append({"key": "hand:%d" % int(r["out"]), "src": "By hand",
			"cat": str(r.get("cat", "")), "out": int(r["out"]),
			"n": int(r.get("n", 1)), "reqs": r.get("reqs", []),
			"cost": 0, "extra": {}, "diagram": ""})
	for st in STATION_CRAFTS:
		for r in STATION_CRAFTS[st]:
			out.append({"key": "%d:%d" % [int(st), int(r["out"])], "station": int(st),
				"src": name_of(int(st)), "cat": "Stations", "out": int(r["out"]),
				"n": int(r.get("n", 1)), "reqs": r.get("reqs", []),
				"cost": int(r.get("cost", 0)), "extra": r.get("extra", {}),
				"diagram": ""})
	# The anvil: what each stage of beating an ingot gives.
	for sh in [[BAR, 1], [SHEET, 1], [PLATE, 4]]:
		out.append({"key": "anvil:%d" % int(sh[0]), "src": "Anvil (strike with a hammer)",
			"cat": "Metalwork", "out": int(sh[0]), "n": int(sh[1]),
			"reqs": [{"refined": true, "n": 1}], "cost": 0, "extra": {}, "diagram": ""})
	# The press: parts laid on the bed, and the lever pulled.
	for pr in PRESS_RECIPES:
		var preqs: Array = []
		for part in pr["parts"]:
			if typeof(part[0]) == TYPE_STRING:
				preqs.append({"refined": true, "n": int(part[1])})
			else:
				preqs.append({"id": int(part[0]), "n": int(part[1])})
		out.append({"key": "press:%d" % int(pr["out"]), "src": "Press (lay parts, pull lever)",
			"cat": "Metalwork", "out": int(pr["out"]), "n": int(pr.get("n", 1)),
			"reqs": preqs, "cost": 0, "extra": {}, "diagram": ""})
	# Stations: put down whole from the station ring (hold C), paid for out of
	# your pockets. Listed here so the book still answers "what does a Smelter
	# take", which is the only question anyone asked of the old patterns.
	for b in STATION_BUILDS:
		out.append({"key": "build:%d" % int(b["kind"]), "src": "Station ring (hold C)",
			"cat": "Machines", "out": int(b["kind"]), "n": 1, "reqs": b["reqs"],
			"cost": 0, "extra": {}, "diagram": ""})
	return out


## The materials line for a recipe-book entry.
## One requirement, in words.
##
## Shared by the reqs list and the `extra` slot because they are the same shape
## -- which the `extra` reader used to assume meant a plain id, so the first
## recipe whose extra offered a CHOICE of materials crashed the Recipe Book on
## open. Anything that formats a requirement goes through here now.
## Is this part of the land rather than something built? Ground, stone, ice,
## ore, logs, leaves, water and plants -- and any slab or stair cut from them.
## A ship never takes these aboard, so one built sitting on the ground lifts
## off clean and leaves the ground behind.
static func is_natural(id: int) -> bool:
	var b := bottom_of(id)
	if b == AIR:
		return false
	var m := base_material_of(b)
	if m in [ROCK, DIRT, GRASS, REGOLITH, ICE, SNOW, CRYSTAL, CORE, WATER, PATH, TALL_GRASS]:
		return true
	if m in WOOD_IDS or m in LEAF_IDS or is_ore(m):
		return true
	return m == CROP or m == SAPLING


## Does one stack of `id` (with these ore properties) count towards requirement
## `r`? The one test every station, the ring and the book share, so a recipe
## that asks for "a sheet of Reactivity 80" means the same thing everywhere.
static func req_matches(r: Dictionary, id: int, props: Dictionary) -> bool:
	var kind_ok: bool = (r.has("id") and id == int(r["id"])) \
		or (r.has("any") and id in (r["any"] as Array)) \
		or (r.has("refined") and is_refined(id))
	if not kind_ok:
		return false
	if r.has("prop"):
		return int(props.get(str(r["prop"]), 0)) >= int(r["min"])
	return true


static func req_text(r: Dictionary) -> String:
	if r.has("label") and r.has("prop"):
		return "%d %s" % [int(r["n"]), r["label"]]
	if r.has("refined"):
		return "%d Ingot%s" % [int(r["n"]), "" if int(r["n"]) == 1 else "s"]
	if r.has("any"):
		return "%d %s" % [int(r["n"]), r.get("label", "items")]
	return "%d %s" % [int(r["n"]), name_of(int(r["id"]))]


static func recipe_needs(rec: Dictionary) -> String:
	var parts := PackedStringArray()
	for r in rec.get("reqs", []):
		parts.append(req_text(r))
	if int(rec.get("cost", 0)) > 0:
		# Paid in the station's own stock, which is not always ingots.
		var c := int(rec["cost"])
		match primary_material_for(int(rec.get("station", SMELTER))):
			"alloy":
				parts.append("%d %s" % [c, name_of(ALLOY)])
			"circuit":
				parts.append("%d %s" % [c, name_of(CIRCUIT)])
			_:
				parts.append("%d Ingot%s" % [c, "" if c == 1 else "s"])
	var ex: Dictionary = rec.get("extra", {})
	if not ex.is_empty():
		parts.append(req_text(ex))
	if parts.is_empty():
		return "nothing"
	return ",  ".join(parts)


## Categories for the recipe book. A flat list stops being usable long before the
## recipe count gets interesting -- these let the panel filter, and a new recipe
## only has to declare which drawer it lives in.
const CRAFT_CATS := ["All", "Stations", "Light", "Building", "Materials"]

# NOTHING is made by hand any more. Everything is made at a station, and every
# station is put down whole from the station ring, which is why the inventory
# no longer carries a crafting column.
const HAND_RECIPES := []

# Which material TYPE a station builds from (see Blocks.id_matches_material).
# The Smelter combines refined ore + a base resource into intermediates; the two
# gear/ship stations then build from an INTERMEDIATE, not raw refined material,
# so refining ore isn't the answer to every recipe.
static func primary_material_for(kind: int) -> String:
	match kind:
		FABRICATOR:
			return "circuit"
		SHIPWORKS:
			return "alloy"
		SMELTER:
			return "refined"
		_:
			return "any"

static func id_matches_material(id: int, mtype: String) -> bool:
	match mtype:
		"refined":
			return is_refined(id)
		"circuit":
			return id == CIRCUIT
		"alloy":
			return id == ALLOY
		_:
			return is_refined(id) or id == ALLOY or id == CIRCUIT

static func is_intermediate(id: int) -> bool:
	return id in INTERMEDIATE_IDS


## The strike counts at which a workpiece of this material becomes a Bar, a
## Sheet and Hull Plate: [bar, sheet, plate]. A soft ore flattens in a couple of
## blows a stage; a hard one fights you for twice that.
static func smith_stages(props: Dictionary) -> Array:
	var h: float = clampf(float(props.get("h", 40)) / 100.0, 0.0, 1.0)
	var f: float = lerpf(0.75, 1.6, h)
	var bar: int = maxi(1, int(round(2.0 * f)))
	var sheet: int = maxi(bar + 1, int(round(4.0 * f)))
	var plate: int = maxi(sheet + 1, int(round(6.0 * f)))
	return [bar, sheet, plate]


## What a workpiece with `hits` strikes in it is: "ingot", "bar", "sheet",
## "plate", "cracking" (one past plate -- a warning), or "scrap".
static func smith_shape(hits: int, props: Dictionary) -> String:
	var st := smith_stages(props)
	if hits < int(st[0]):
		return "ingot"
	if hits < int(st[1]):
		return "bar"
	if hits < int(st[2]):
		return "sheet"
	if hits == int(st[2]):
		return "plate"
	if hits == int(st[2]) + 1:
		return "cracking"
	return "scrap"


## Where a piece already beaten to `id` starts when it goes back on the anvil.
static func smith_hits_of(id: int, props: Dictionary) -> int:
	var st := smith_stages(props)
	if id == BAR:
		return int(st[0])
	if id == SHEET:
		return int(st[1])
	return 0


# --- the press ------------------------------------------------------------------
#
# The Press has a bed with four spots and a ram. You lay parts on the bed and
# pull the lever; if what is on the bed is exactly one of these, the ram comes
# down and it becomes that. Nothing else happens on it -- it is where metal
# PARTS are made, some of which are things in their own right (hull, a bucket,
# a drill) and some of which go on to other benches.
#
# `parts` is [[what, how many], ...]; "ingot" means any ingot. The FIRST entry
# is where the result takes its material from -- a drill is as good as its
# bar, a battery holds what its ingot can.
const PRESS_SPOTS := 4
const PRESS_RECIPES := [
	{"label": "Metal Hull", "out": METAL, "n": 1, "parts": [[PLATE, 4]]},
	# The base's nervous system: how much comes off one bar is the bar's
	# Reactivity (wire_yield), so a conductive ore still goes further.
	{"label": "Wire", "out": WIRE, "n": 8, "yield_from_material": true, "parts": [[BAR, 1]]},
	{"label": "Battery", "out": BATTERY, "n": 1, "parts": [["ingot", 1], [SHEET, 2]]},
	{"label": "Machine Core", "out": MACHINE_CORE, "n": 1, "parts": [[BAR, 2], [PLATE, 2]]},
	{"label": "Circuitry x2", "out": CIRCUIT, "n": 2, "parts": [[SHEET, 1], [WIRE, 2]]},
	{"label": "Glow Lamp x2", "out": GLOW_LAMP, "n": 2, "parts": [[SHEET, 1], [CRYSTAL, 1]]},
	{"label": "Bucket", "out": BUCKET, "n": 1, "parts": [[SHEET, 2]]},
	# The gear the Fabricator used to make, as parts: a drill is a bar driven
	# by circuitry, a pistol is circuitry in a sheet casing, a blade is two
	# bars edged with plate.
	{"label": "Drill", "out": DRILL, "n": 1, "parts": [[BAR, 1], [CIRCUIT, 3]]},
	{"label": "Pulse Pistol", "out": PULSE_PISTOL, "n": 1, "parts": [[SHEET, 1], [CIRCUIT, 3]]},
	{"label": "Melee Weapon", "out": WEAPON, "n": 1, "parts": [[BAR, 2], [PLATE, 1]]},
]


## Does `id` count as `what` from a press recipe?
static func press_part_is(id: int, what) -> bool:
	if typeof(what) == TYPE_STRING:
		return is_refined(id)
	return id == int(what)


## Can this go on the press bed at all?
static func press_takes(id: int) -> bool:
	for r in PRESS_RECIPES:
		for part in r["parts"]:
			if press_part_is(id, part[0]):
				return true
	return false


## The recipe exactly matching these ids on the bed, or {} if none does.
static func press_match(ids: Array) -> Dictionary:
	for r in PRESS_RECIPES:
		var left: Array = ids.duplicate()
		var ok := true
		for part in r["parts"]:
			for i in int(part[1]):
				var found := -1
				for j in left.size():
					if press_part_is(int(left[j]), part[0]):
						found = j
						break
				if found < 0:
					ok = false
					break
				left.remove_at(found)
			if not ok:
				break
		if ok and left.is_empty():
			return r
	return {}


## A press recipe's parts in words: "4 Plate", "1 Ingot, 2 Sheet".
static func press_parts_text(r: Dictionary) -> String:
	var bits := PackedStringArray()
	for part in r["parts"]:
		var what: String = "Ingot" if typeof(part[0]) == TYPE_STRING else name_of(int(part[0]))
		bits.append("%d %s" % [int(part[1]), what])
	return ", ".join(bits)


## Will a crafting bench take `id` into its storage? The benches were strict
## about their PRIMARY material only, which shut out everything else their own
## recipes asked for -- the Fabricator refused the bar its Wire is made from.
## A bench takes its primary material and anything any of its recipes names.
static func station_accepts(kind: int, id: int) -> bool:
	if id_matches_material(id, primary_material_for(kind)):
		return true
	for craft in STATION_CRAFTS.get(kind, []):
		var reqs: Array = (craft as Dictionary).get("reqs", []).duplicate()
		if craft.has("extra"):
			reqs.append(craft["extra"])
		for r in reqs:
			var rd: Dictionary = r
			if rd.has("id") and int(rd["id"]) == id:
				return true
			if rd.has("any") and id in rd["any"]:
				return true
			if rd.has("refined") and is_refined(id):
				return true
	return false

static func is_smelter_kind(kind: int) -> bool:
	return kind == SMELTER

# Each craft consumes either `cost` units of the station's primary material (see
# primary_material_for/id_matches_material above), optionally plus an `extra`
# plain-resource requirement, OR (if it has no meaningful "material with stats")
# a plain `reqs` list like a hand recipe -- checked against the STATION's own
# storage, not the player's inventory. Split by station so recipes read as one
# cohesive idea per bench instead of one giant grab-bag:
#   Smelter/Forge  -- combine refined ore + Metal into intermediates
#   Fabricator     -- personal gear, built from Circuitry
#   Shipworks      -- hull & propulsion, built from Alloy Plating
#   Carpenter      -- structural blocks, built from plain Wood/Rock/Metal
const STATION_CRAFTS := {
	CAMPFIRE: [
		{"label": "Cooked Meat", "out": COOKED_MEAT, "n": 1, "reqs": [{"id": RAW_MEAT, "n": 1}]},
		{"label": "Cooked Vegetables", "out": COOKED_CROP, "n": 1,
			"reqs": [{"id": CROP, "n": 2}]},
	],
	SMELTER: [
		# Hull plate is not made here any more: it is beaten out of an ingot on
		# an anvil (see the smithing section). The smelter's job is the fire --
		# ore into ingots, and scrap back into them.
		{"label": "Alloy Plating x2", "out": ALLOY, "n": 2, "cost": 2, "extra": {"id": PLATE, "n": 3}},
		# Sand, melted. Regolith is the only sand there is -- the loose surface
		# of the dust, ash, rust and crystal-desert worlds -- so glass is a
		# reason to go to one of those.
		{"label": "Glass", "out": GLASS, "n": 1, "reqs": [{"id": REGOLITH, "n": 1}]},
	],
	# The Fabricator is the Press now, and presses rather than crafts: see
	# PRESS_RECIPES. It has no buttons.
	# Ship systems. None of these is "so much alloy": each is built from the
	# things it is actually made of, gathered along different lines -- the
	# press, the anvil, the smelter, the ground -- so each one is a small
	# project of its own. The Warp Drive is the big one: its four parts each
	# need a signature ore that only one family of world holds.
	SHIPWORKS: [
		# A burn chamber: it wants an ore that burns.
		{"label": "Thruster", "out": THRUSTER, "n": 1, "reqs": [
			{"id": MACHINE_CORE, "n": 1}, {"id": ALLOY, "n": 2}, {"id": WIRE, "n": 2},
			{"refined": true, "prop": "c", "min": FUEL_GRADE, "n": 1,
				"label": "Fuel-grade ingot (Combustion %d+)" % FUEL_GRADE}]},
		# Tanks of glass, and a scrubber bed packed with living leaves to turn
		# stale air back into good -- things any world with plants has, since a
		# wreck does not always keep its own.
		{"label": "Life Support", "out": LIFE_SUPPORT, "n": 1, "reqs": [
			{"id": MACHINE_CORE, "n": 1}, {"id": GLASS, "n": 4}, {"id": CIRCUIT, "n": 2},
			{"any": LEAF_IDS, "n": 8, "label": "Leaves"}]},
		{"label": "Warp Coil", "out": WARP_COIL, "n": 1, "reqs": [
			{"id": BAR, "prop": "e", "min": WARP_GRADE["e"], "n": 2,
				"label": "Bar (Energy %d+, living worlds)" % WARP_GRADE["e"]},
			{"id": WIRE, "n": 4}]},
		{"label": "Ignition Charge", "out": IGNITION_CHARGE, "n": 1, "reqs": [
			{"refined": true, "prop": "c", "min": WARP_GRADE["c"], "n": 2,
				"label": "Ingot (Combustion %d+, dust worlds)" % WARP_GRADE["c"]},
			{"id": SHEET, "n": 1}]},
		{"label": "Coolant Jacket", "out": COOLANT_JACKET, "n": 1, "reqs": [
			{"id": SHEET, "prop": "r", "min": WARP_GRADE["r"], "n": 1,
				"label": "Sheet (Reactivity %d+, frozen worlds)" % WARP_GRADE["r"]},
			{"id": GLASS, "n": 2}, {"id": ICE, "n": 4}]},
		{"label": "Containment Shell", "out": CONTAINMENT_SHELL, "n": 1, "reqs": [
			{"id": PLATE, "prop": "d", "min": WARP_GRADE["d"], "n": 4,
				"label": "Plate (Density %d+, scorched worlds)" % WARP_GRADE["d"]}]},
		{"label": "Warp Drive", "out": WARP_DRIVE, "n": 1, "reqs": [
			{"id": WARP_COIL, "n": 1}, {"id": IGNITION_CHARGE, "n": 1},
			{"id": COOLANT_JACKET, "n": 1}, {"id": CONTAINMENT_SHELL, "n": 1},
			{"id": MACHINE_CORE, "n": 2}, {"id": CIRCUIT, "n": 6}, {"id": CRYSTAL, "n": 4}]},
	],
	# The bootstrap bench. Everything on it asks for plain gathered material:
	# this is the bench you reach with nothing but what you picked up off the
	# ground.
	CARPENTER: [
		# Deliberately cheap and made from the most common material there is: a
		# light source gates cave exploration and surviving the first night, so
		# putting it behind rare drops would just make the early game dark.
		{"label": "Hoe", "out": HOE, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 3, "label": "Wood"}]},
		# The three that come before anything is smelted. The Pick is the one
		# that opens the game -- nothing else gets you rock -- so it is made of
		# the two things you can gather with your hands, and the other two cost
		# the same so no order of making them is wrong.
		{"label": "Pick", "out": PICK, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 2, "label": "Wood"},
				{"any": STONE_IDS, "n": 3, "label": "Rock"}]},
		{"label": "Axe", "out": AXE, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 2, "label": "Wood"},
				{"any": STONE_IDS, "n": 3, "label": "Rock"}]},
		{"label": "Spade", "out": SPADE, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 2, "label": "Wood"},
				{"any": STONE_IDS, "n": 2, "label": "Rock"}]},
		{"label": "Stone Sword", "out": SWORD, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 1, "label": "Wood"},
				{"any": STONE_IDS, "n": 3, "label": "Rock"}]},
		# Metal, at the bench you can reach with nothing -- so it costs a trip
		# to a smelter and no more than that. A field has to be near water, and
		# a bucket is what stops that meaning "on a beach".
		# Smithing. The hammer is the same wood and rock as the other first
		# tools, so it is waiting for you the moment you have an ingot; the
		# anvil is three ingots, so the first metal you smelt becomes the thing
		# you work the rest of it on.
		{"label": "Hammer", "out": HAMMER, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 2, "label": "Wood"},
				{"any": STONE_IDS, "n": 3, "label": "Rock"}]},
		{"label": "Anvil", "out": ANVIL, "n": 1,
			"reqs": [{"refined": true, "n": 3}]},
		# Cheap and early on purpose. It exists so that a lake stops being a
		# wall on your first afternoon, and a boat you cannot afford until you
		# have a smelter would be a boat nobody ever builds.
		{"label": "Wooden Boat", "out": BOAT, "n": 1,
			"reqs": [{"any": WOOD_IDS, "n": 10, "label": "Wood"}]},
		{"label": "Torch x4", "out": TORCH, "n": 4,
			"reqs": [{"any": WOOD_IDS, "n": 1, "label": "Wood"}]},
		# Burns the ore itself: how bright and how far comes from that ore's
		# Combustion, so which ore you feed it actually matters.
		{"label": "Ember Torch x6", "out": EMBER_TORCH, "n": 6, "carry_props": true,
			"reqs": [{"refined": true, "n": 1}, {"any": WOOD_IDS, "n": 1, "label": "Wood"}]},
		# Three from one bone, because the point is to make a field worth
		# tending rather than to ration it. Bone comes off the big creatures
		# only, so the supply is already gated by what you can bring down.
		{"label": "Bone Meal x3", "out": BONEMEAL, "n": 3,
			"reqs": [{"id": BONE, "n": 1}]},
		# Soft stock. Cloth is the cheaper of the two to reach -- a field is
		# renewable and a herd is not -- and Leather is the one you get without
		# having farmed at all, so whichever way you played first, something
		# soft is available.
		{"label": "Cloth", "out": CLOTH, "n": 1,
			"reqs": [{"id": FIBRE, "n": 4}]},
		{"label": "Leather", "out": LEATHER, "n": 1,
			"reqs": [{"id": HIDE, "n": 2}]},
		# Moved off the Fabricator, where it was three of Circuitry -- an odd
		# recipe for a garment whose entire job is insulation, and the reason
		# the hazard worlds asked for another ingot rather than for a farm.
		#
		# It still takes refined material, because that is where the GRADE comes
		# from: suit_resist reads the ore's Density, so which ore you line it
		# with is the difference between 30% and 90% protection. What changed is
		# that the padding is now real -- cloth or leather, either one, so a
		# farmer and a hunter can both make one.
		{"label": "Insulated Suit", "out": SUIT, "n": 1, "cost": 2,
			"extra": {"any": [CLOTH, LEATHER], "n": 3, "label": "Cloth or Leather"}},
		# Wood, and only wood. It used to want two Hull Plate as well, which put
		# the one early building block you actually want -- something to close
		# your first shelter with -- behind a smelter, on the far side of the
		# whole tool line. Logs OR planks: which shape of wood you happen to be
		# carrying is not a thing to be strict about, and somebody who has
		# already sawn their timber should not have to fell another tree.
		#
		# The label matters as much as the ids. Without one this read as
		# "6 items", which tells you nothing about what to go and get.
		{"label": "Door", "out": DOOR, "n": 1,
			"reqs": [{"any": WOOD_IDS + PLANK_IDS, "n": 6, "label": "Wood or Planks"}]},
	],
}

# Everything the player can place (scroll-wheel cycles this list). Ores are now raw
# materials for crafting, not placeable blocks.
const PLACEABLE := [ROCK, DIRT, GRASS, REGOLITH, ICE, SNOW, CRYSTAL, METAL,
	WOOD, WOOD_PALE, WOOD_DARK,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	COCKPIT, THRUSTER, LIFE_SUPPORT, GLASS, DOOR, INTERFACE, WARP_DRIVE,
	ROCK_SLAB, DIRT_SLAB, GRASS_SLAB, REGOLITH_SLAB, ICE_SLAB, SNOW_SLAB,
	CRYSTAL_SLAB, METAL_SLAB, WOOD_SLAB, GLASS_SLAB,
	ROCK_STAIR, DIRT_STAIR, GRASS_STAIR, REGOLITH_STAIR, ICE_STAIR, SNOW_STAIR,
	CRYSTAL_STAIR, METAL_STAIR, WOOD_STAIR, GLASS_STAIR,
	TORCH, GLOW_LAMP, EMBER_TORCH, MACHINE_CORE, WIRE,
	PLANK, PLANK_PALE, PLANK_DARK,
	PLANK_SLAB, PLANK_PALE_SLAB, PLANK_DARK_SLAB,
	PLANK_STAIR, PLANK_PALE_STAIR, PLANK_DARK_STAIR,
	WOOD_PALE_SLAB, WOOD_DARK_SLAB, WOOD_PALE_STAIR, WOOD_DARK_STAIR,
	# is_partable gates eighth-placement on this list, and a bed is soft on top.
	CLOTH, LEATHER]

const NAMES := {
	TALL_GRASS: "Tall Grass",
	SEEDS: "Seeds",
	SAPLING: "Sapling",
	TILLED: "Tilled Soil",
	CROP: "Crop",
	YOUNG_TREE: "Young Tree",
	HOE: "Hoe",
	BUCKET: "Bucket",
	WATER_BUCKET: "Water Bucket",
	PICK: "Pick",
	AXE: "Axe",
	SPADE: "Spade",
	SWORD: "Stone Sword",
	COOKED_CROP: "Cooked Vegetables",
	BONEMEAL: "Bone Meal",
	FIBRE: "Plant Fibre",
	CLOTH: "Cloth",
	LEATHER: "Leather",
	BED: "Bed",
	RAW_MEAT: "Raw Meat",
	COOKED_MEAT: "Cooked Meat",
	HIDE: "Hide",
	BONE: "Bone",
	CAMPFIRE: "Campfire",
	AIR: "Air",
	ROCK: "Rock",
	DIRT: "Dirt",
	GRASS: "Grass",
	REGOLITH: "Regolith",
	ICE: "Ice",
	IRON_ORE: "Iron Ore",
	CRYSTAL: "Crystal",
	CORE: "Molten Core",
	SNOW: "Snow",
	METAL: "Metal Hull",
	CRACKED_METAL: "Cracked Plate",
	COCKPIT: "Cockpit",
	THRUSTER: "Thruster",
	WOOD: "Wood",
	WOOD_PALE: "Pale Wood",
	WOOD_DARK: "Dark Wood",
	LEAF_0: "Green Leaves",
	LEAF_1: "Lime Leaves",
	LEAF_2: "Deep Green Leaves",
	LEAF_3: "Olive Leaves",
	LEAF_4: "Autumn Leaves",
	LEAF_5: "Rust Leaves",
	LEAF_6: "Golden Leaves",
	LEAF_7: "Teal Leaves",
	LEAF_8: "Violet Leaves",
	LEAF_9: "Azure Leaves",
	LEAF_10: "Pink Leaves",
	LEAF_11: "Mint Leaves",
	COPPER_ORE: "Copper Ore",
	GOLD_ORE: "Gold Ore",
	TITANIUM_ORE: "Titanium Ore",
	SILICON_ORE: "Silicon Ore",
	URANIUM_ORE: "Uranium Ore",
	WATER: "Water",
	SMELTER: "Smelter",
	FABRICATOR: "Press",
	SHIPWORKS: "Shipworks",
	CHEST: "Wooden Chest",
	CARPENTER: "Carpenter's Bench",
	SHAPER: "Block Shaper",
	MACHINE_CORE: "Machine Core",
	WARP_COIL: "Warp Coil", IGNITION_CHARGE: "Ignition Charge",
	COOLANT_JACKET: "Coolant Jacket", CONTAINMENT_SHELL: "Containment Shell",
	BOAT: "Wooden Boat",
	JOURNAL: "Salvaged Journal",
	GENERATOR: "Generator",
	CHEST_WIDE: "Wide Chest",
	CARGO_MODULE: "Cargo Module",
	OXYGEN_PLANT: "Oxygen Plant",
	HEATER: "Heater",
	COOLER: "Cooler",
	WIRE: "Power Conduit",
	BATTERY: "Battery",
	POWER_BAY: "Power Bay",
	PARTS: "Parts",
	WRENCH: "Wrench",
	PLANK: "Planks",
	PLANK_PALE: "Pale Planks",
	PLANK_DARK: "Dark Planks",
	TORCH: "Torch",
	EMBER_TORCH: "Ember Torch",
	GLOW_LAMP: "Glow Lamp",
	FORGE: "Forge",
	CLIMATE_UNIT: "Climate Unit",
	LIFE_SUPPORT: "Life Support",
	GLASS: "Glass",
	DOOR: "Door",
	DOOR_OPEN: "Open Door",
	ALLOY: "Alloy Plating",
	CIRCUIT: "Circuitry",
	INTERFACE: "Interface Core",
	ROOF_SLAB: "Roof Slab",
	PATH: "Path",
	WARP_DRIVE: "Warp Drive",
	ORE_0: "Ore", ORE_1: "Ore", ORE_2: "Ore", ORE_3: "Ore",
	REFINED_0: "Ingot", REFINED_1: "Ingot",
	REFINED_2: "Ingot", REFINED_3: "Ingot",
	HAMMER: "Hammer", ANVIL: "Anvil", BAR: "Bar", SHEET: "Sheet", SCRAP: "Scrap",
	PLATE: "Plate",
	DRILL: "Drill",
	O2_TANK: "O2 Tank",
	SUIT: "Insulated Suit",
	WEAPON: "Melee Weapon",
	PULSE_PISTOL: "Pulse Pistol",
}

# What each ore is (eventually) used for -- shown when you aim at it.
const USES := {
	HAMMER: "Strike a workpiece on an anvil",
	ANVIL: "Put an ingot on it, then strike it with a hammer",
	BAR: "A part: pressed into wire, machine cores and tools",
	SHEET: "A part: casings -- batteries, circuitry, lamps, buckets",
	PLATE: "A part: machines are built from it; four pressed together make hull",
	SCRAP: "Overworked. Remelt it at a smelter into an ingot",
	WARP_COIL: "A Warp Drive part. Wound from bars of a living world's best conductor",
	IGNITION_CHARGE: "A Warp Drive part. Packed with a dust world's fiercest fuel",
	COOLANT_JACKET: "A Warp Drive part. A frozen world's reactive metal, glass and ice",
	CONTAINMENT_SHELL: "A Warp Drive part. Plates of a scorched world's densest metal",
	CRACKED_METAL: "Crumbles if you work at it -- nothing worth keeping",
	IRON_ORE: "Hulls & tools",
	COPPER_ORE: "Wiring & thrusters",
	GOLD_ORE: "Electronics & trade",
	TITANIUM_ORE: "Advanced hull",
	SILICON_ORE: "Glass & circuits",
	URANIUM_ORE: "Reactor fuel",
	FIBRE: "Spin into Cloth at a Carpenter's Bench",
	CLOTH: "Soft stock — beds, suits",
	LEATHER: "Soft stock — beds, suits",
	HIDE: "Tan into Leather at a Carpenter's Bench",
	BONE: "Grind into Bone Meal at a Carpenter's Bench",
	BONEMEAL: "Right-click a growing plant to push it a stage on",
	CROP: "Cook at a Campfire",
	SEEDS: "Plant on tilled soil",
	SAPLING: "Plant on grass or dirt",
}


## What a harvest of this species is FOR, in a couple of words. A crop that
## looks like every other crop until you have grown one is a crop nobody
## plants on purpose.
static func crop_use_text(key: String) -> String:
	match str(crop_growth(key).get("use", "food")):
		"fibre":
			return "Fibre crop — harvest for Plant Fibre"
		_:
			return "Food crop — harvest for Crop"

# Seconds of continuous mining to break each block. Default 0.5 if unlisted.
const HARDNESS := {
	GRASS: 0.35, DIRT: 0.35, REGOLITH: 0.3, SNOW: 0.25,
	LEAF_0: 0.2, LEAF_1: 0.2, LEAF_2: 0.2, LEAF_3: 0.2, LEAF_4: 0.2, LEAF_5: 0.2,
	LEAF_6: 0.2, LEAF_7: 0.2, LEAF_8: 0.2, LEAF_9: 0.2, LEAF_10: 0.2, LEAF_11: 0.2,
	WOOD: 0.6, WOOD_PALE: 0.6, WOOD_DARK: 0.6,
	PLANK: 0.5, PLANK_PALE: 0.5, PLANK_DARK: 0.5,
	WIRE: 0.3,
	# Faster than leaves: grass is the one thing you brush aside constantly, and
	# anything you touch that often should not cost you a mining animation.
	TALL_GRASS: 0.05,
	CROP: 0.05,
	TILLED: 0.4,
	TORCH: 0.1, GLOW_LAMP: 0.3, EMBER_TORCH: 0.1, MACHINE_CORE: 1.2,
	ICE: 0.7, ROCK: 0.9, CRYSTAL: 1.2, CORE: 1.6,
	IRON_ORE: 1.3, COPPER_ORE: 1.3, GOLD_ORE: 1.6,
	TITANIUM_ORE: 1.9, SILICON_ORE: 1.2, URANIUM_ORE: 2.1,
	METAL: 0.25, COCKPIT: 0.25, THRUSTER: 0.25,  # ship parts break fast
	# Hand-workable, and slow at it -- about two seconds without a tool.
	CRACKED_METAL: 0.8,
	INTERFACE: 0.3,
}

const COLORS := {
	TALL_GRASS: Color(0.42, 0.66, 0.28),
	SEEDS: Color(0.78, 0.70, 0.34),
	SAPLING: Color(0.36, 0.58, 0.30),
	TILLED: Color(0.30, 0.21, 0.14),
	CROP: Color(0.46, 0.68, 0.30),
	YOUNG_TREE: Color(0.44, 0.33, 0.20),
	HOE: Color(0.72, 0.58, 0.34),
	BUCKET: Color(0.68, 0.70, 0.74),
	WATER_BUCKET: Color(0.34, 0.52, 0.78),
	PICK: Color(0.62, 0.62, 0.66),
	AXE: Color(0.70, 0.55, 0.36),
	SPADE: Color(0.56, 0.50, 0.42),
	SWORD: Color(0.60, 0.60, 0.63),
	COOKED_CROP: Color(0.78, 0.55, 0.24),
	RAW_MEAT: Color(0.72, 0.26, 0.28),
	COOKED_MEAT: Color(0.55, 0.34, 0.18),
	HIDE: Color(0.60, 0.45, 0.30),
	BONE: Color(0.88, 0.86, 0.76),
	BONEMEAL: Color(0.83, 0.87, 0.70),
	FIBRE: Color(0.76, 0.72, 0.48),
	CLOTH: Color(0.87, 0.84, 0.78),
	LEATHER: Color(0.55, 0.38, 0.24),
	BED: Color(0.72, 0.30, 0.34),
	CAMPFIRE: Color(0.86, 0.45, 0.16),
	ROCK: Color(0.44, 0.44, 0.50),
	DIRT: Color(0.40, 0.29, 0.20),
	GRASS: Color(0.34, 0.58, 0.30),
	REGOLITH: Color(0.78, 0.72, 0.55),
	ICE: Color(0.66, 0.84, 0.95),
	IRON_ORE: Color(0.58, 0.47, 0.40),
	CRYSTAL: Color(0.30, 0.86, 0.90),
	CORE: Color(0.92, 0.42, 0.16),
	SNOW: Color(0.94, 0.96, 1.00),
	METAL: Color(0.60, 0.62, 0.66),
	# Duller than sound plate, and gone a little toward rust.
	CRACKED_METAL: Color(0.50, 0.48, 0.46),
	HAMMER: Color(0.55, 0.50, 0.44),
	ANVIL: Color(0.30, 0.31, 0.34),
	BAR: Color(0.70, 0.68, 0.64),
	SHEET: Color(0.74, 0.74, 0.72),
	SCRAP: Color(0.42, 0.38, 0.34),
	PLATE: Color(0.66, 0.67, 0.70),
	COCKPIT: Color(0.35, 0.55, 0.90),
	THRUSTER: Color(0.85, 0.45, 0.20),
	WOOD: Color(0.42, 0.28, 0.16),
	WOOD_PALE: Color(0.60, 0.48, 0.34),
	WOOD_DARK: Color(0.26, 0.18, 0.12),
	LEAF_0: Color(0.22, 0.55, 0.22),
	LEAF_1: Color(0.55, 0.72, 0.22),
	LEAF_2: Color(0.14, 0.38, 0.18),
	LEAF_3: Color(0.45, 0.50, 0.20),
	LEAF_4: Color(0.82, 0.45, 0.12),
	LEAF_5: Color(0.68, 0.20, 0.16),
	LEAF_6: Color(0.85, 0.78, 0.25),
	LEAF_7: Color(0.15, 0.58, 0.52),
	LEAF_8: Color(0.50, 0.32, 0.68),
	LEAF_9: Color(0.32, 0.46, 0.78),
	LEAF_10: Color(0.85, 0.50, 0.72),
	LEAF_11: Color(0.60, 0.88, 0.68),
	COPPER_ORE: Color(0.72, 0.45, 0.30),
	GOLD_ORE: Color(0.85, 0.72, 0.25),
	TITANIUM_ORE: Color(0.72, 0.74, 0.80),
	SILICON_ORE: Color(0.52, 0.58, 0.64),
	URANIUM_ORE: Color(0.40, 0.78, 0.35),
	WATER: Color(0.20, 0.45, 0.85, 0.55),
	SMELTER: Color(0.34, 0.30, 0.32),
	FABRICATOR: Color(0.30, 0.40, 0.46),
	SHIPWORKS: Color(0.40, 0.42, 0.30),
	CHEST: Color(0.45, 0.31, 0.17),
	CARPENTER: Color(0.48, 0.34, 0.20),
	SHAPER: Color(0.52, 0.52, 0.56),
	MACHINE_CORE: Color(0.86, 0.52, 0.18),
	WARP_COIL: Color(0.35, 0.85, 1.0), IGNITION_CHARGE: Color(0.95, 0.42, 0.12),
	COOLANT_JACKET: Color(0.7, 0.9, 1.0), CONTAINMENT_SHELL: Color(0.45, 0.38, 0.34),
	BOAT: Color(0.58, 0.42, 0.26),
	JOURNAL: Color(0.52, 0.40, 0.30),
	GENERATOR: Color(0.62, 0.45, 0.28),
	CHEST_WIDE: Color(0.46, 0.31, 0.17),
	CARGO_MODULE: Color(0.42, 0.52, 0.58),
	OXYGEN_PLANT: Color(0.42, 0.68, 0.78),
	HEATER: Color(0.74, 0.40, 0.26),
	COOLER: Color(0.36, 0.62, 0.86),
	WIRE: Color(0.72, 0.56, 0.20),
	BATTERY: Color(0.45, 0.80, 0.55),
	POWER_BAY: Color(0.50, 0.70, 0.60),
	PARTS: Color(0.70, 0.70, 0.72),
	WRENCH: Color(0.72, 0.66, 0.30),
	PLANK: Color(0.60, 0.42, 0.24),
	PLANK_PALE: Color(0.78, 0.65, 0.46),
	PLANK_DARK: Color(0.38, 0.26, 0.17),
	TORCH: Color(1.0, 0.74, 0.40),
	EMBER_TORCH: Color(1.0, 0.62, 0.26),
	GLOW_LAMP: Color(0.95, 0.97, 1.0),
	FORGE: Color(0.55, 0.22, 0.16),
	CLIMATE_UNIT: Color(0.35, 0.62, 0.55),
	LIFE_SUPPORT: Color(0.30, 0.78, 0.68),
	GLASS: Color(0.62, 0.78, 0.88, 0.30),
	DOOR: Color(0.55, 0.5, 0.4),
	DOOR_OPEN: Color(0.55, 0.5, 0.4),
	ALLOY: Color(0.68, 0.70, 0.76),
	CIRCUIT: Color(0.35, 0.75, 0.45),
	INTERFACE: Color(0.75, 0.35, 0.85),
	ROOF_SLAB: Color(0.40, 0.28, 0.20),
	PATH: Color(0.58, 0.50, 0.38),
	WARP_DRIVE: Color(0.55, 0.30, 0.90),
	# generic fallbacks; real ore colors are planet-defined and travel with the item
	ORE_0: Color(0.7, 0.6, 0.4), ORE_1: Color(0.6, 0.7, 0.5),
	ORE_2: Color(0.5, 0.6, 0.7), ORE_3: Color(0.7, 0.5, 0.7),
	REFINED_0: Color(0.8, 0.72, 0.55), REFINED_1: Color(0.72, 0.8, 0.62),
	REFINED_2: Color(0.62, 0.72, 0.82), REFINED_3: Color(0.82, 0.62, 0.82),
	DRILL: Color(0.75, 0.76, 0.80),
	O2_TANK: Color(0.45, 0.7, 0.9),
	SUIT: Color(0.8, 0.7, 0.4),
	WEAPON: Color(0.75, 0.78, 0.82),
	PULSE_PISTOL: Color(0.3, 0.75, 0.85),
}

static func is_solid(id: int) -> bool:
	return id != AIR

static func hardness(raw: int) -> float:
	# A slab is the same material as its parent, and a stacked pair is mined as
	# one -- both take the base block's hardness.
	var id := base_material_of(bottom_of(raw))
	return HARDNESS.get(id, 0.5)

static func use_of(id: int) -> String:
	return USES.get(id, "")

## Leaves render with alpha cutouts and are deliberately NON-COLLIDABLE, so a
## canopy feels like foliage you brush through rather than a solid box.
## Plants you walk through: no collision, and they never hide the block behind.
static func is_plant(id: int) -> bool:
	var b := bottom_of(id)
	return b == TALL_GRASS or b == CROP


## Swept away by water rather than left standing in it: the things you walk
## through, crops included.
##
## Crops were left out of this at first on the theory that soil has to be near
## water to be worked at all, so drowning a field would be the game arguing with
## itself. It is not: you dig the water into the ground and till at the same
## level beside it, and then the water is never in the crop's cell. A plant
## standing in the middle of a stream is the thing that looks wrong.
##
## Kept as its own question rather than calling is_plant at each site: "does
## this stop the player" and "does this survive a flood" happen to have the same
## answer today and are not the same idea.
static func is_washable(id: int) -> bool:
	return is_plant(id)


# --- flora ---------------------------------------------------------------
#
# Every plant that can exist, and the planet classes it can live on (see
# Planet.planet_class). A world grows the species whose class it matches -- more
# than one, usually, and sometimes none at all, which is what makes a green
# planet worth walking around.
#
# Seeds are not an item per species: they are all SEEDS or SAPLING carrying the
# species in their props, the same way an ore carries which ore it is. Sixty
# plants would otherwise be sixty block ids for things that are never blocks.
# Two or three of each kind per class, so a world can grow more than one thing
# and two worlds of the same class are not the same world. With one grass and
# one tree to a class there was nothing for the roll to choose BETWEEN: every
# temperate planet grew the same grass, and every seed you ever found off tall
# grass was that grass.
#
# Each class also has at least one FIBRE species, so landing anywhere leaves you
# able to make cloth without first finding a better planet. The `name` here is
# only a fallback -- a world renames whatever grows on it (see
# Planet.flora_here), so these are what a species is called in the abstract.
const FLORA := [
	# class M -- temperate
	{"key": "meadow", "name": "Meadow Grass", "suffix": "grass", "kind": "grass", "classes": ["M"]},
	{"key": "ryegrass", "name": "Rye Grass", "suffix": "rye", "kind": "grass", "classes": ["M"]},
	{"key": "clover", "name": "Clover", "suffix": "clover", "kind": "bush", "classes": ["M"]},
	{"key": "briar", "name": "Briar", "suffix": "briar", "kind": "bush", "classes": ["M", "P"]},
	{"key": "broadleaf", "name": "Broadleaf", "suffix": "leaf", "kind": "tree", "classes": ["M"]},
	{"key": "silverbark", "name": "Silverbark", "suffix": "bark", "kind": "tree", "classes": ["M", "P"]},
	# class P -- frozen
	{"key": "frostgrass", "name": "Frost Grass", "suffix": "frost", "kind": "grass", "classes": ["P"]},
	{"key": "tundramoss", "name": "Tundra Moss", "suffix": "moss", "kind": "grass", "classes": ["P"]},
	{"key": "snowberry", "name": "Snowberry", "suffix": "berry", "kind": "bush", "classes": ["P"]},
	{"key": "rimeberry", "name": "Rime Berry", "suffix": "rime", "kind": "bush", "classes": ["P"]},
	{"key": "icepine", "name": "Ice Pine", "suffix": "pine", "kind": "tree", "classes": ["P"]},
	# class H -- arid
	{"key": "duneweed", "name": "Dune Weed", "suffix": "weed", "kind": "grass", "classes": ["H"]},
	{"key": "sandsedge", "name": "Sand Sedge", "suffix": "sedge", "kind": "grass", "classes": ["H", "Y"]},
	{"key": "thornbush", "name": "Thorn Bush", "suffix": "thorn", "kind": "bush", "classes": ["H", "Y"]},
	{"key": "ironroot", "name": "Ironroot", "suffix": "root", "kind": "tree", "classes": ["H", "Y"]},
	# class Y -- scorched
	{"key": "ashgrass", "name": "Ash Grass", "suffix": "ash", "kind": "grass", "classes": ["Y"]},
	{"key": "cinderweed", "name": "Cinder Weed", "suffix": "cinder", "kind": "grass", "classes": ["Y"]},
	# class O -- ocean
	{"key": "kelpvine", "name": "Kelp Vine", "suffix": "kelp", "kind": "grass", "classes": ["O"]},
	{"key": "reedgrass", "name": "Reed Grass", "suffix": "reed", "kind": "grass", "classes": ["O"]},
	{"key": "coralbush", "name": "Coral Bush", "suffix": "coral", "kind": "bush", "classes": ["O"]},
	{"key": "mangrove", "name": "Mangrove", "suffix": "mangrove", "kind": "tree", "classes": ["O"]},
	# nothing lives on a class D world. That is what makes it barren.
]


## How a crop grows, and what it gives you.
##
## Stages and time are per species on purpose: a plant you can turn round in a
## couple of minutes and one that takes a quarter of an hour are different
## decisions about what to put in your field, and that is the whole game of
## farming. Times are seconds for the WHOLE plant; each stage takes an equal
## share of it.
## `spread` is how often a harvest returns MORE than the one seed it always
## gives back, and `spread_n` is how many extra when it does. This is where a
## plant's temperament lives: some put out one of themselves and no more, and
## some go like potatoes -- one in, a handful out, but only now and then.
## `use` says what a harvest of this species yields: "food" gives the generic
## Crop, "fibre" gives Plant Fibre instead. It is a property of the species
## rather than a new plant, because nine crops that differ only in how fast they
## grow are nine crops doing one job.
##
## The three fibre species are the three the numbers already pointed at. Kelp
## Vine is the fastest grower and the worst food in the game at 2.5, so nothing
## is lost by making it cordage; Dune Weed has the lowest yield; Thornbush is
## the slowest of the steady ones. They also sit on different planet classes, so
## wherever you land, something makes rope.
const CROP_GROWTH := {
	# The steady ones. A row of these stays a row unless you work at it.
	"meadow":     {"stages": 3, "time": 150.0, "yield_n": 2, "food": 3.0,
		"spread": 0.10, "spread_n": 1},
	"frostgrass": {"stages": 4, "time": 260.0, "yield_n": 2, "food": 4.0,
		"spread": 0.08, "spread_n": 1},
	"duneweed":   {"stages": 3, "time": 200.0, "yield_n": 1, "use": "fibre", "food": 3.5,
		"spread": 0.12, "spread_n": 1},
	"thornbush":  {"stages": 4, "time": 280.0, "yield_n": 2, "use": "fibre", "food": 4.0,
		"spread": 0.10, "spread_n": 1},
	# Slow, but generous when it finally does.
	"ashgrass":   {"stages": 5, "time": 320.0, "yield_n": 2, "food": 5.0,
		"spread": 0.07, "spread_n": 3},
	# The runners. Worth planting for the seed as much as the food.
	"clover":     {"stages": 3, "time": 170.0, "yield_n": 2, "food": 3.0,
		"spread": 0.18, "spread_n": 2},
	"snowberry":  {"stages": 4, "time": 240.0, "yield_n": 3, "food": 4.5,
		"spread": 0.15, "spread_n": 2},
	"kelpvine":   {"stages": 2, "time": 120.0, "yield_n": 3, "use": "fibre", "food": 2.5,
		"spread": 0.22, "spread_n": 3},
	"coralbush":  {"stages": 3, "time": 190.0, "yield_n": 3, "food": 3.5,
		"spread": 0.20, "spread_n": 3},
	# The second and third species of each class. Every one of them is either a
	# better food or a fibre than the one beside it at something, so which you
	# plant is a choice rather than a coin toss.
	"ryegrass":   {"stages": 3, "time": 140.0, "yield_n": 2, "food": 3.2,
		"spread": 0.12, "spread_n": 1},
	"briar":      {"stages": 4, "time": 230.0, "yield_n": 2, "use": "fibre", "food": 2.0,
		"spread": 0.11, "spread_n": 2},
	"tundramoss": {"stages": 3, "time": 210.0, "yield_n": 2, "use": "fibre", "food": 2.0,
		"spread": 0.14, "spread_n": 2},
	"rimeberry":  {"stages": 4, "time": 250.0, "yield_n": 3, "food": 4.2,
		"spread": 0.13, "spread_n": 2},
	"sandsedge":  {"stages": 3, "time": 180.0, "yield_n": 2, "food": 3.0,
		"spread": 0.10, "spread_n": 1},
	"cinderweed": {"stages": 4, "time": 260.0, "yield_n": 2, "use": "fibre", "food": 2.0,
		"spread": 0.09, "spread_n": 1},
	"reedgrass":  {"stages": 2, "time": 140.0, "yield_n": 2, "food": 2.8,
		"spread": 0.20, "spread_n": 3},
}


## How many seeds one harvest of this plant hands back. Always at least the one
## it grew from -- a crop that ate its own seed would make farming a way to run
## out of plants.
static func seed_return(key: String) -> int:
	var g := crop_growth(key)
	if randf() >= float(g.get("spread", 0.1)):
		return 1
	return 1 + randi_range(1, int(g.get("spread_n", 1)))

## Everything a crop needs to know, with sane numbers for a species that has no
## entry of its own yet.
static func crop_growth(key: String) -> Dictionary:
	return CROP_GROWTH.get(key, {"stages": 3, "time": 180.0, "yield_n": 1, "food": 3.0})


## What a harvest of this species actually puts in your hands.
static func crop_yield(key: String) -> int:
	return FIBRE if str(crop_growth(key).get("use", "food")) == "fibre" else CROP


## How long a young tree stands before it becomes a tree, in seconds.
const SAPLING_TIME := 240.0

## How tall a crop stands at a given stage, as a multiple of a wild grass blade.
##
## A sprout is a quarter the height of the grass around it and the ripe plant is
## taller than any of it, so a field reads as a field from across it and you can
## see it come on without counting anything. The steps are even, so every stage
## is a visible step up rather than the last one doing all the growing.
const CROP_H_SPROUT := 0.26
const CROP_H_RIPE := 1.25

static func crop_height(stage: int, stages: int) -> float:
	var t := float(stage) / maxf(float(stages - 1), 1.0)
	return lerpf(CROP_H_SPROUT, CROP_H_RIPE, clampf(t, 0.0, 1.0))


## Colours a crop by how far along it is: green while it is coming, gold when it
## is ready. A field you can read across from the far side of it is worth more
## than a name you have to walk up to.
static func crop_color(ripe: bool) -> Color:
	return Color(0.86, 0.72, 0.24) if ripe else Color(0.46, 0.68, 0.30)


## Every species that could live on a world of this class.
static func flora_for_class(cls: String) -> Array:
	var out: Array = []
	for f in FLORA:
		if cls in (f["classes"] as Array):
			out.append(f)
	return out


static func flora_by_key(key: String) -> Dictionary:
	for f in FLORA:
		if str(f["key"]) == key:
			return f
	return {}


## How often clearing tall grass leaves a seed behind. Low enough that seeds are
## worth going out for, high enough that a field is a reliable way to get them.
const SEED_DROP_CHANCE := 0.12
## How often clearing leaves gives a sapling of that tree.
const SAPLING_DROP_CHANCE := 0.08
## Felling a whole tree does NOT roll that chance against all eighty of its
## leaves -- that handed over a fistful of saplings for one cut, when breaking
## leaves by hand gives you one if you are lucky. A felled tree gives this many,
## whatever size it was, and leaves that wither afterwards almost never give
## anything at all.
const FELL_SAPLING_WEIGHTS := [0, 1, 1, 1, 2]
const WITHER_SAPLING_CHANCE := 0.01
## And how often what drops is some OTHER plant that lives on this world instead
## of the one you just broke. This is the whole reason you can find a plant
## without hunting for the one bush that has it: everything green is a slow
## lottery ticket for everything else green nearby.
const CROSS_SEED_CHANCE := 0.25


## Whatever is packed above the id: a leaf somebody placed carries a flag
## there (see placed_leaf), and is still a leaf.
static func is_leaf(id: int) -> bool:
	return bottom_of(id) in LEAF_IDS


## A leaf somebody PLACED, as opposed to one a tree grew -- wild or from a
## sapling, which write the plain id. Only grown leaves wither without wood, or
## come down with a felled tree: a hedge has no trunk and was never meant to.
const LEAF_PLACED_SHIFT := 16

static func placed_leaf(id: int) -> int:
	return (id & ID_MASK) | (1 << LEAF_PLACED_SHIFT)

static func leaf_is_placed(v: int) -> bool:
	return is_leaf(v) and ((v >> LEAF_PLACED_SHIFT) & 1) == 1


static func is_wood(id: int) -> bool:
	return id in WOOD_IDS


static func is_ore(id: int) -> bool:
	return id in ORE_SLOT_IDS

static func is_refined(id: int) -> bool:
	return id in REFINED_SLOT_IDS

static func is_material(id: int) -> bool:
	return id in ORE_SLOT_IDS or id in REFINED_SLOT_IDS or id in INTERMEDIATE_IDS

static func is_station(id: int) -> bool:
	return id in STATION_IDS

## How many vertical inventory cells an item occupies. A suit is a bulky thing
## to haul around, and taking two cells makes carrying a spare a real decision
## rather than a free one.
static func item_cells_tall(id: int) -> int:
	return 2 if id == SUIT else 1


static func is_gear(id: int) -> bool:
	return id in TOOL_IDS

## Which way a door looks, which edge it swings on, and whether this cell is its
## upper half. Packed into the same spare bits stairs use for their facing: a
## block is only ever one kind of thing, so they are free.
const DOOR_HINGE_SHIFT := 18
const DOOR_TOP_SHIFT := 19


static func is_door(id: int) -> bool:
	var b := bottom_of(id)
	return b == DOOR or b == DOOR_OPEN


static func door_with(open: bool, facing: int, hinge: int, top: bool) -> int:
	return ((DOOR_OPEN if open else DOOR) & ID_MASK) 		| ((facing & FACING_MASK) << FACING_SHIFT) 		| ((hinge & 1) << DOOR_HINGE_SHIFT) 		| ((1 if top else 0) << DOOR_TOP_SHIFT)


static func door_facing_of(v: int) -> int:
	return (v >> FACING_SHIFT) & FACING_MASK


static func door_hinge_of(v: int) -> int:
	return (v >> DOOR_HINGE_SHIFT) & 1


static func door_is_top(v: int) -> bool:
	return ((v >> DOOR_TOP_SHIFT) & 1) == 1


## Swing it, keeping everything else about it. Rebuilding the bare id here threw
## away which way the door faced and which edge it was hinged on, so a door that
## had been opened once came back square to the world.
static func door_toggle_of(id: int) -> int:
	var flip := DOOR_OPEN if bottom_of(id) == DOOR else DOOR
	return (id & ~ID_MASK) | flip

# A drill's mining power from the material it's built from: harder + more energetic
# materials drill faster and reach higher ore tiers. Bare hands are 1.0.
static func drill_power(props: Dictionary) -> float:
	return 1.5 + float(props.get("h", 0)) / 100.0 + float(props.get("e", 0)) / 100.0 * 0.8

# Insulated Suit hazard-damage reduction (0..0.9) from its material's Density.
static func suit_resist(props: Dictionary) -> float:
	return 0.30 + float(props.get("d", 0)) / 100.0 * 0.60

# Melee weapon damage per hit from its material's Hardness + Energy. Bare hands
# hit for UNARMED_DAMAGE (see player.gd); any crafted weapon beats that.
static func weapon_damage(props: Dictionary) -> float:
	return 8.0 + float(props.get("h", 0)) / 100.0 * 16.0 + float(props.get("e", 0)) / 100.0 * 8.0

# Ranged weapon damage per shot -- an energy weapon, so it leans on Energy more
# than Hardness (the opposite weighting from the melee blade).
static func ranged_weapon_damage(props: Dictionary) -> float:
	return 6.0 + float(props.get("e", 0)) / 100.0 * 18.0 + float(props.get("h", 0)) / 100.0 * 4.0

# Per-shape combat stats, keyed by the weapon's block id. This is the one place
# new weapon shapes get added -- a new melee shape just needs hit_style/range/
# cooldown entries, a new ranged shape just needs hit_style "hitscan" or
# "projectile" (see player.gd's ranged-fire dispatch and Projectile). The
# per-shot/per-hit damage magnitude itself comes from a separate derived-stat
# function per id (weapon_damage/ranged_weapon_damage, computed once at craft
# time in station.gd -- see the "cmat" pattern there), matching "the shape
# decides the role, the material decides the stats" used everywhere else in
# this game's crafting.
const WEAPON_SHAPES := {
	WEAPON: {
		"category": "melee", "hit_style": "single", "range": 3.0,
		"light_cooldown": 0.35, "heavy_charge": 0.5, "heavy_mult": 2.2, "heavy_stagger": 1.0,
		"light_stagger": 0.35,
	},
	PULSE_PISTOL: {
		"category": "ranged", "hit_style": "projectile", "range": 30.0,
		"cooldown": 0.35, "projectile_speed": 40.0, "stagger": 0.4,
	},
}

# Highest ore tier a given mining power can break (via TIER_MIN_POWER).
static func max_tier_for_power(power: float) -> int:
	var t := 0
	for i in TIER_MIN_POWER.size():
		if power >= TIER_MIN_POWER[i]:
			t = i
	return t

static func is_placeable_block(id: int) -> bool:
	return id in PLACEABLE

# raw ore slot id -> its refined counterpart (same slot index)
static func refined_of(ore_id: int) -> int:
	var i := ORE_SLOT_IDS.find(ore_id)
	return REFINED_SLOT_IDS[i] if i >= 0 else AIR

## What a colour would be CALLED. Leaf blocks carry colour words in their names
## ("Mint Leaves"), but a planet retints them freely, so the fixed name and the
## thing on screen stop agreeing. Naming from the actual colour keeps the two
## honest wherever the world's palette is known.
static func hue_name(c: Color) -> String:
	if c.s < 0.12:
		return "Ashen" if c.v < 0.55 else "Bone"
	var bands := [
		[0.028, "Crimson"], [0.055, "Rust"], [0.09, "Amber"], [0.14, "Golden"],
		[0.19, "Olive"], [0.26, "Lime"], [0.36, "Green"], [0.43, "Mint"],
		[0.50, "Teal"], [0.55, "Cyan"], [0.62, "Azure"], [0.70, "Indigo"],
		[0.78, "Violet"], [0.86, "Magenta"], [0.94, "Rose"], [1.01, "Crimson"],
	]
	for b in bands:
		if c.h < float(b[0]):
			return str(b[1])
	return "Crimson"


static func color_of(raw: int) -> Color:
	if Cosmetics.is_cosmetic(raw):
		return Cosmetics.color_of(raw)
	# Stacked slabs are looked up by their LOWER half; the mesher draws each
	# half in its own colour, this is just for UI and single-colour uses.
	# Mask off any packed orientation/stacking bits: everything below keys off
	# the plain block id.
	var id := bottom_of(raw)
	# A slab is the same stuff as its parent block, so it never carries its own
	# palette entry -- one less thing to keep in sync per material.
	if SLAB_MATERIAL.has(id):
		return COLORS.get(SLAB_MATERIAL[id], Color.MAGENTA)
	if STAIR_MATERIAL.has(id):
		return COLORS.get(STAIR_MATERIAL[id], Color.MAGENTA)
	return COLORS.get(id, Color.MAGENTA)

## A material's name used as an ADJECTIVE, in front of a shape. Almost always
## just the material's own name -- but "Planks Slab" reads as a mistake where
## "Plank Slab" reads as a thing, and the material's own name has to stay plural
## because a plank is what four of them come off a log as.
const SHAPE_PREFIX := {PLANK: "Plank", PLANK_PALE: "Pale Plank", PLANK_DARK: "Dark Plank"}


static func shape_prefix(mat: int) -> String:
	return str(SHAPE_PREFIX.get(mat, NAMES.get(mat, "Unknown")))


static func name_of(raw: int) -> String:
	if Cosmetics.is_cosmetic(raw):
		return Cosmetics.name_of(raw)
	if is_stacked_slab(raw):
		return "%s + %s" % [name_of(bottom_of(raw)), name_of(top_slab_of(raw))]
	var id := bottom_of(raw)
	if SLAB_MATERIAL.has(id):
		return "%s Slab" % shape_prefix(int(SLAB_MATERIAL[id]))
	if STAIR_MATERIAL.has(id):
		var v := stair_variant_of(raw)
		var t := " Stairs" if v == STAIR_STRAIGHT else " %s Stairs" % stair_variant_name(v)
		if stair_flipped_of(raw):
			t += " (upside down)"
		return shape_prefix(int(STAIR_MATERIAL[id])) + t
	return NAMES.get(id, "Unknown")
