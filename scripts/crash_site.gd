class_name CrashSite
extends RefCounted
## The ship you woke up in, and the state you woke up in it.
##
## Every new world opens the same way: a small lander on its belly with holes in
## it, half its systems gone, and a computer in the nose that will tell you what
## it needs. What is BROKEN is rolled per world, so one wreck is missing a
## thruster and leaking through the roof while the next has its hull nearly
## whole and no power at all. Nothing here is scripted beyond that: the repairs
## are the ordinary game -- rock into a smelter, metal into plate, plate into
## the hole -- which is the point. Teaching by having something to fix beats
## teaching by telling.
##
## The plan is written once, as a shape; the damage is taken out of it; and what
## was taken is remembered on the ship (see Ship.wreck_missing) so the computer
## can list it and tick it off as it comes back.

## The hull: half-width across, half-depth fore and aft, and how tall inside.
const W := 2          # cells either side of the centre line
const L := 3          # cells fore and aft of the middle
const H := 3          # shell top; the cabin inside is two blocks tall


## Build the wreck and set it on the ground at `pos`, facing `fwd`.
static func build(world: WorldManager, pos: Vector3, up: Vector3, fwd: Vector3,
		rng: RandomNumberGenerator) -> Ship:
	var ship := world.spawn_ship(pos, up, fwd)
	ship.blocks.clear()
	var plan := _plan()
	for v in plan:
		ship.set_block(v, int(plan[v]))
	_wreck(ship, plan, rng)
	ship.landed = true
	ship.flying = false
	return ship


## What the ship looks like when it is whole: hull plate everywhere on the
## shell, a cockpit in the nose, a door in one side, and the systems inside.
static func _plan() -> Dictionary:
	var out := {}
	for x in range(-W, W + 1):
		for z in range(-L, L + 1):
			for y in range(0, H + 1):
				var on_shell := absi(x) == W or absi(z) == L or y == 0 or y == H
				if on_shell:
					out[Vector3i(x, y, z)] = Blocks.METAL
	# The nose: the console at eye level with a windscreen over and beside it,
	# so the first thing you see on waking is the world you came down on.
	out[Vector3i(0, 1, -L)] = Blocks.COCKPIT
	for x in [-1, 1]:
		out[Vector3i(x, 1, -L)] = Blocks.GLASS
	for x in range(-1, 2):
		out[Vector3i(x, 2, -L)] = Blocks.GLASS
	# A way in, on the right-hand side.
	out[Vector3i(W, 1, 1)] = Blocks.DOOR
	# The works, along the back wall inside.
	out[Vector3i(-1, 1, L - 1)] = Blocks.LIFE_SUPPORT
	out[Vector3i(1, 1, L - 1)] = Blocks.BATTERY
	out[Vector3i(0, 1, L - 1)] = Blocks.WIRE
	# Thrusters on the tail, outside the shell.
	out[Vector3i(-1, 1, L)] = Blocks.THRUSTER
	out[Vector3i(1, 1, L)] = Blocks.THRUSTER
	# A lamp inside, so the first thing you see is not the dark.
	out[Vector3i(0, H, 0)] = Blocks.GLOW_LAMP
	# The pilot's seat, facing the nose: something to sit on with a back behind
	# it. You wake standing at the controls in front of it, so both cells are
	# BEHIND where the player comes round -- a seat back through the head is
	# not the first thing anybody should see.
	out[Vector3i(0, 1, -L + 1)] = Blocks.METAL
	out[Vector3i(0, 2, -L + 2)] = Blocks.METAL
	return out


## Everything a wreck is missing, rolled fresh per world: holes punched through
## the shell, and some of the systems torn out altogether.
static func _wreck(ship: Ship, plan: Dictionary, rng: RandomNumberGenerator) -> void:
	var missing := {}
	# Holes: a run of hull cells knocked out, mostly around one impact point, so
	# it reads as a crash rather than as moth-eaten metal.
	var shell: Array = []
	for v in plan:
		if int(plan[v]) == Blocks.METAL:
			shell.append(v)
	shell.sort()     # deterministic order before the rolls below
	var holes := rng.randi_range(4, 9)
	var impact: Vector3i = shell[rng.randi() % shell.size()]
	var by_dist := shell.duplicate()
	by_dist.sort_custom(func(a, b):
		return (Vector3(a) - Vector3(impact)).length() < (Vector3(b) - Vector3(impact)).length())
	var keep := {Vector3i(0, 1, -L): true, Vector3i(0, 1, -L + 1): true,
		Vector3i(0, 2, -L + 2): true}
	for i in mini(holes, by_dist.size()):
		# Near the impact first, with the odd stray further out.
		var pick: Vector3i = by_dist[i] if rng.randf() < 0.75 else shell[rng.randi() % shell.size()]
		if keep.has(pick):
			continue
		missing[pick] = Blocks.METAL
	# Systems: the battery is always dead or gone -- that is what put you down --
	# and one or two of the rest went with it.
	var systems := [Vector3i(-1, 1, L - 1), Vector3i(1, 1, L - 1),
		Vector3i(-1, 1, L), Vector3i(1, 1, L), Vector3i(0, 1, L - 1)]
	# The seat and the cockpit itself always survive: you have to wake up
	# somewhere, and the computer has to be there to talk to you.
	var gone := rng.randi_range(1, 3)
	systems.shuffle()
	for i in mini(gone, systems.size()):
		var sv: Vector3i = systems[i]
		if plan.has(sv):
			missing[sv] = int(plan[sv])
	for v in missing:
		ship.set_block(v, Blocks.AIR)
	ship.wreck_missing = missing
	# Whatever survived is running on nothing: no charge, and the air long gone.
	ship.charge = 0.0
	ship.air = 0.0
