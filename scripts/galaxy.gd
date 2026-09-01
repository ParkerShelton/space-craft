class_name Galaxy
extends RefCounted

## A galaxy of star systems, generated from a single seed exactly like a
## planet's ores/fauna/settlements: pure data derived from the seed, not a big
## stored structure. Only the CURRENT system's planets ever actually get built
## (see main._enter_system) -- every other system just sits here as a cheap
## summary (name, civilization tier, seed) until the player warps there.
##
## Civilization tier decides whether a system has any intelligent life at all,
## and how much: from totally lifeless, through wildlife-only, up through a
## single primitive colony, to an advanced system with several colonized
## worlds. This is the foundation a future warp-travel UI and faction/trade/law
## layer will hang off of -- neither exists yet.

const CIV_NONE := 0       # lifeless: no fauna, no civilization
const CIV_FAUNA := 1      # wildlife but no intelligent life
const CIV_PRIMITIVE := 2  # exactly one settled world, capped at a modest tier
const CIV_ADVANCED := 3   # several colonized worlds, higher tech, bigger settlements
const CIV_NAMES := ["Uninhabited", "Wildlife", "Primitive Colony", "Advanced Empire"]

const SYSTEM_NAME_PRE := ["Al", "Bel", "Cor", "Dra", "Eri", "Fen", "Gal", "Hyx",
	"Io", "Jor", "Kel", "Lyr", "Mor", "Nyv", "Oph", "Pyx", "Quo", "Rho", "Sol", "Tau"]
const SYSTEM_NAME_SUF := ["ara", "ion", "eth", "ux", "aris", "or", "ine", "ys",
	"and", "ell", "ix", "oth", "una", "ez", "in"]

var galaxy_seed: int = 0
var systems: Array = []  # each: {name, seed, civ_tier, pos, planet_count}


func generate(seed_val: int, count: int = 24) -> void:
	galaxy_seed = seed_val
	systems.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i in count:
		var civ_roll := rng.randf()
		var civ_tier: int
		if civ_roll < 0.28:
			civ_tier = CIV_NONE
		elif civ_roll < 0.55:
			civ_tier = CIV_FAUNA
		elif civ_roll < 0.85:
			civ_tier = CIV_PRIMITIVE
		else:
			civ_tier = CIV_ADVANCED
		var planet_count := rng.randi_range(4, 6)
		# scattered in an arbitrary "galaxy space" -- not used for real travel
		# distances yet, just a placeholder shape for a future star map to plot
		var dir := Vector3(rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0)
		if dir.length() < 0.01:
			dir = Vector3.RIGHT
		var pos := dir.normalized() * rng.randf_range(100.0, 1000.0)
		systems.append({
			"name": _system_name(rng),
			"seed": seed_val + i * 104729,  # large prime offset -> unrelated per-system seeds
			"civ_tier": civ_tier,
			"pos": pos,
			"planet_count": planet_count,
		})


func _system_name(rng: RandomNumberGenerator) -> String:
	return SYSTEM_NAME_PRE[rng.randi() % SYSTEM_NAME_PRE.size()] \
		+ SYSTEM_NAME_SUF[rng.randi() % SYSTEM_NAME_SUF.size()]


## The system to start a new game in: the first system with at least a
## primitive colony, so a fresh game always has somewhere with intelligent life
## reasonably nearby -- falls back to system 0 if the roll never produced one.
func home_system_index() -> int:
	for i in systems.size():
		if int(systems[i]["civ_tier"]) >= CIV_PRIMITIVE:
			return i
	return 0


static func civ_name(tier: int) -> String:
	return CIV_NAMES[tier] if tier >= 0 and tier < CIV_NAMES.size() else "Unknown"
