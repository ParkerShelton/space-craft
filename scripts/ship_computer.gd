class_name ShipComputer
extends RefCounted
## The voice in the nose of the ship.
##
## While the ship is wrecked it is the only tutorial this game has: right-click
## the cockpit and it lists what is wrong in the order worth fixing, says what
## each repair is made of and where that comes from, and ticks things off as you
## do them. Nothing here teaches controls or tells you to press W -- it gives
## you a reason to go and find rock, and the rest follows.
##
## Once the ship flies it stops being a checklist and becomes what a ship's
## computer should be: how the ship is doing, where you have been, and where you
## could go.

## One line of the systems check: what it is, whether it is done, and -- if not
## -- what to do about it.
class Item:
	var name := ""
	var done := false
	var detail := ""
	var hint := ""

	func _init(n: String, ok: bool, d := "", h := "") -> void:
		name = n
		done = ok
		detail = d
		hint = h


## Everything the ship needs before it will fly, in the order to do it in.
static func checklist(ship: Ship) -> Array:
	var out: Array = []
	var st: Dictionary = ship.get_status()
	var missing: Dictionary = ship.wreck_missing
	# 1. The hull. A ship with holes in it holds no air, whatever else works.
	var holes := 0
	for v in missing:
		if int(missing[v]) == Blocks.METAL or int(missing[v]) == Blocks.GLASS:
			holes += 1
	out.append(Item.new("Hull sealed", holes == 0 and bool(st.get("sealed", false)),
		"%d plate%s missing" % [holes, "" if holes == 1 else "s"] if holes > 0 else "airtight",
		"Metal comes from rock: build a Campfire, then bank rock round it for a Smelter, and feed it rock."))
	# 2. Power. Without it nothing else in here does anything.
	var has_battery := _has(ship, Blocks.BATTERY)
	out.append(Item.new("Power cell", has_battery,
		"fitted" if has_battery else "torn out",
		"A Battery is made at a Fabricator, or found in the wrecks and outposts scattered about."))
	# 3. Air.
	var has_ls := bool(st.get("life_support", false))
	out.append(Item.new("Life support", has_ls,
		"fitted" if has_ls else "missing",
		"Life Support is built at a Shipworks -- or salvaged, which is faster."))
	# 4. Thrust.
	var thr := int(st.get("thrusters", 0))
	out.append(Item.new("Thrusters", thr >= 2,
		"%d of 2" % thr,
		"A Thruster is built at a Shipworks from metal and a refined material."))
	# 5. Everything above, and the tanks full.
	var pressurised: bool = bool(st.get("habitable", false)) and float(st.get("air", 0.0)) > 0.05
	out.append(Item.new("Cabin pressurised", pressurised,
		"%d%% air" % int(float(st.get("air", 0.0)) * 100.0),
		"Seal the hull and fit life support, then power it: the cabin fills itself."))
	return out


static func _has(ship: Ship, id: int) -> bool:
	for v in ship.blocks:
		if int(ship.blocks[v]) == id:
			return true
	return false


## Is every line ticked?
static func flightworthy(ship: Ship) -> bool:
	for it in checklist(ship):
		if not (it as Item).done:
			return false
	return true


## The one thing worth doing next, in a sentence. This is what the computer
## says when you ask it rather than reading the list yourself.
static func next_step(ship: Ship) -> String:
	for it in checklist(ship):
		var item: Item = it
		if not item.done:
			return "%s: %s. %s" % [item.name, item.detail, item.hint]
	return "All systems nominal. She will fly."


## What the computer says when the ship is whole -- how it is doing, in lines.
static func status_lines(ship: Ship) -> Array:
	var st: Dictionary = ship.get_status()
	var out: Array = []
	out.append("Hull: %s" % ("airtight" if bool(st.get("sealed", false)) else "breached"))
	out.append("Air: %d%%" % int(float(st.get("air", 0.0)) * 100.0))
	out.append("Power: %d%%" % int(float(st.get("charge", 0.0)) * 100.0))
	out.append("Thrusters: %d" % int(st.get("thrusters", 0)))
	out.append("Warp drive: %s" % ("fitted" if bool(st.get("warp_drive", false)) else "none"))
	return out
