class_name Player
extends CharacterBody3D

## Escape, with nothing else open. Main puts the game menu on screen; the player
## has no business knowing what that looks like.
signal menu_requested

## Hybrid controller.
##
## GROUND mode (gravity strong): the body smoothly stands up so its "up" points
## away from the planet center; you walk on the tangent plane and jump. Climb
## high enough that gravity fades and you...
## FLOAT mode (gravity weak / deep space): full 6-axis flight, no forced
## orientation -- WASD moves along your view, jump/crouch thrust up/down.
##
## The switch is purely a function of local gravity magnitude, so weak planets let
## you float even near the surface and strong ones "capture" you into walking.

const WALK_SPEED := 7.0
const JUMP_SPEED := 8.0
const FLY_SPEED := 16.0
const FLY_ACCEL := 6.0
const FLY_DAMP := 3.0
const MOUSE_SENS := 0.0025
## Eye height above the body's centre. The collision capsule is 1.8 tall, so its
## top is at 0.9 and the eye normally sits well inside it.
const EYE_HEIGHT := 0.7
## ...but "well inside" is not "always inside". Jumping into a ceiling closes
## that 0.2 of headroom in a single frame at jump speed, and the solver only
## pushes the capsule back out afterwards -- for the frame in between, the eye is
## in the block and you see through it. The eye is pulled down to keep this much
## clear of anything overhead, which costs one short raycast per frame.
const EYE_CLEARANCE := 0.25
## See _update_prospect: compensation for where the wrench glyph draws.
const WRENCH_NUDGE_Y := 4.0

# The placement preview, and how much of it you see.
#
# One alpha cannot serve both distances. A face across the room is a small patch
# of screen and needs to be solid enough to notice; the same face an arm's length
# away is a pane of colour across your whole view, and in a corridor it sits
# between you and the block you are trying to break. So it thins out as it comes
# closer: same preview, out of the way when it would otherwise be in your face.
const GHOST_COLOR := Color(0.6, 0.9, 1.0)
const GHOST_COLOR_FINE := Color(1.0, 0.78, 0.30)
const GHOST_ALPHA := 0.11
const GHOST_ALPHA_FINE := 0.16
## Distance to the previewed block, centre to eye, over which it fades up.
const GHOST_FADE_NEAR := 1.4
const GHOST_FADE_FAR := 3.4
## What is left of the alpha at point blank. Not zero: it still has to say WHERE
## the block would go, it just has no business being the brightest thing on
## screen while you are trying to see past it.
const GHOST_ALPHA_NEAR := 0.22
const ALIGN_SPEED := 2.5          # how fast we stand upright when captured (lower = smoother)
const FLIGHT_THRESHOLD := 3.0     # gravity (m/s^2) below which we float
const REACH := 6.0                # block interaction distance
const BARE_MINE_MULT := 2.5       # bare-hand mining is slow; a drill divides this
var mine_power := 1.0             # >1 once you craft a drill (Phase 2)

# --- survival ---
const MAX_HEALTH := 100.0
const MAX_OXYGEN := 100.0
const O2_DRAIN := 4.0             # oxygen/sec with no air (space / airless / underwater)
const O2_REFILL := 30.0           # oxygen/sec while breathing (in atmosphere or a ship)
const SUFFOCATE_DMG := 7.0        # health/sec once oxygen hits zero
const HEALTH_REGEN := 3.0         # health/sec while safe and oxygenated
# --- hunger -----------------------------------------------------------------
# Slow enough that food is an errand rather than a chore: a full meter lasts
# roughly twelve minutes of ordinary play, less if you are working hard.
const MAX_HUNGER := 100.0
const HUNGER_DRAIN := 0.07        # hunger/sec standing still
const HUNGER_EXERTION := 0.10     # extra hunger/sec while actually moving
const STARVE_DMG := 1.1           # health/sec at zero hunger -- slow, not sudden
const STARVE_SPEED_MULT := 0.62   # and you drag your feet once you are empty
const HUNGER_REGEN_MIN := 25.0    # below this you stop healing
var health := MAX_HEALTH
var oxygen := MAX_OXYGEN
var hunger := MAX_HUNGER
var _hazard_resist := 0.0     # 0..0.9 hazard-damage reduction from the best Suit carried

# --- melee combat ---
const UNARMED_DAMAGE := 3.0       # bare-hand punch; a crafted Weapon beats this
const MELEE_COOLDOWN := 0.5       # seconds between hits
const MELEE_RANGE := 3.0          # a bit shorter than block REACH -- combat is close-range
var _melee_damage := UNARMED_DAMAGE
var _attack_cd := 0.0
# Light (tap) vs heavy (hold past heavy_charge, then release) attack tracking.
# Shared LMB edge-tracking also drives ranged fire below -- only one of the two
# paths runs in a given frame (dispatch is by what's in your hand), so one
# flag is enough.
var _lmb_was_down := false
var _charging := false
var _charge_t := 0.0

# --- ranged combat ---
var _ranged_cd := 0.0

# --- held item view-model ---
const HAND_IDLE_ROT := Vector3(-0.15, 0.35, -0.12)
const HAND_IDLE_POS := Vector3(0.34, -0.28, -0.55)
const SWING_DURATION := 0.28
var _hand_pivot: Node3D
var _held_root: Node3D        # current item mesh, child of _hand_pivot
var _held_key := ""           # cache key; only rebuild the model when this changes
var _swing_t := 999.0         # counts up from 0 during a swing; >=SWING_DURATION = idle
var _bob_phase := 0.0         # walk-cycle position for the held-item bob
var _bob_amp := 0.0           # smoothed 0..1 "how much am I walking"

var world: WorldManager           # set by main.gd
var grounded := false

# --- inventory (slots; you can only place what you have) ---
const SLOTS := 32
const HOTBAR_SLOTS := 8
const STACK_MAX := 99
## Inventory cell metrics. The gap was 4px, which packed the rows tight enough
## that the grid read as one dense block rather than separate slots.
const INV_CELL := 56
const INV_CELL_GAP := 10
const INV_CELL_STEP := INV_CELL + INV_CELL_GAP
# each slot: {"id": int, "count": int, "props": Dictionary, "src": String}
# props/src are set for refined materials & crafted gear; plain blocks leave them empty.
var inv: Array = []
var active_slot := 0              # which slot we place from
var inv_open := false
## Set by Main while the game menu is up. The world keeps running -- nothing here
## pauses -- but this body stops taking orders from the keyboard, because walking
## off a cliff while reading a menu is nobody's idea of an option.
var menu_open := false
## Set while a text field has the keyboard (chat). The mouse stays captured so
## you can still look around; what stops is the body, which polls the keyboard
## directly and would otherwise walk you across the room as you typed.
var ui_typing := false
# dedicated 2-slot-tall equip slot: a Suit only protects you once it's WORN here,
# not just carried in the general grid (unlike the Drill, which stays
# passively equipped from anywhere). Same slot shape as an `inv` entry.
var suit_slot: Dictionary = {"id": Blocks.AIR, "count": 0, "props": {}, "src": "", "mat": {}}
# mining (hold left-click to break; harder blocks take longer)
var _mine_key := ""               # identifies the block currently being mined
var _mine_time := 0.0             # seconds spent mining the current block
## Briefly non-zero after placing something. Placing is instant, so without a
## short tail there would be nothing for other players to see.
var _place_flash := 0.0
var _mine_total := 1.0            # hardness of the current block
var _look_name := ""              # name/use of the block under the crosshair (HUD)
var piloting: Ship = null         # non-null while flying a ship
var aboard: Ship = null           # non-null while walking inside a ship in space
var eva := false                  # floating outside on a tether
var _eva_ship: Ship = null        # ship we're tethered to
var _eva_anchor_local := Vector3.ZERO  # tether attach point in ship-local space
var _tether: MeshInstance3D
var _iv_y := 0.0                  # interior vertical velocity (ship-local)
var _interior_floor := false
var _body_shape: CollisionShape3D
var _home_parent: Node            # where the player lives when not parented to a ship
const ARTIFICIAL_G := 9.0         # interior gravity toward the ship floor
const TETHER_LEN := 18.0          # max EVA tether distance

var _camera: Camera3D
var _ray: RayCast3D
var _outline: MeshInstance3D       # wireframe box around the block under the crosshair
var _stair_state := 0              # R cycles every stair rotation + shape
var _ghost: MeshInstance3D         # translucent preview of the block about to be placed
var _diff: MeshInstance3D          # what is wrong with a build the wrench refused
var _diff_t := 0.0
var _ghost_sig := ""
var _ghost_mat: StandardMaterial3D               # shape key, so the mesh is only rebuilt when it changes
var _ghost_dist := 99.0            # eye to previewed block, drives how faint it is
var _commission_panel: Control     # "make this a Smelter?" confirmation
var _prospect_name := ""           # what the crosshair is currently offering
var _prospect_key := Vector3i(9999, 9999, 9999)   # block the answer above is about
## Off hides the placement preview entirely. Some people would rather judge the
## placement from the crosshair and the block face than have anything drawn over
## the world at all.
var ghost_enabled := true
var _crack: MeshInstance3D         # progressive break-up drawn over the block being mined
var _crack_mat: ShaderMaterial
var _crack_sig := ""
var _pitch := 0.0
var _look := Vector2.ZERO          # accumulated mouse delta, consumed in physics

# UI
var _ui_layer: CanvasLayer
var _crosshair: Label
var _hotbar_label: Label
var _mode_label: Label
var _ship_label: Label
var _system_label: Label
var _starmap_panel: Panel
var _starmap_list: VBoxContainer
var _starmap_warp_btn: Button
var _starmap_rows: Array = []
var _starmap_selected := -1
var _target_label: Label
var _toast_label: Label            # transient "Saved"/"Loaded" confirmation
var _toast_time := 0.0
var _hp_fill: ColorRect            # health bar fill
var _o2_fill: ColorRect            # oxygen bar fill
var _food_fill: ColorRect          # hunger bar fill
var _hazard_label: Label           # "FREEZING"/"OVERHEATING" warning
var base_status: Dictionary = {}   # the sealed base you are standing in, {} outdoors
var underground := false           # below the terrain: no sky, no sky markers
var _await_ground := 0.0           # seconds left waiting for chunks under a spawn
# Fine mode places an EIGHTH of a block instead of a whole one, into the corner
# of the face you are looking at. Toggled rather than held: building a bench
# out of eighths is a lot of clicks to do with a finger on a modifier.
var fine_place := false
var _base_panel: Panel             # power/oxygen/temp readout, only while indoors
var _base_title: Label
var _base_fills: Array[ColorRect] = []
var _base_values: Array[Label] = []
var _inv_panel: Control            # full inventory overlay (toggled with E)
var _book_panel: Panel             # recipe book (toggled with B)
var _book_vbox: VBoxContainer
var _book_search: LineEdit
var _book_empty: Label
var _book_query := ""
var _book_src := "All"
var _book_src_btns: Array = []
var book_open := false

# Which recipes you have learned. Progression will gate this later -- unlocking
# is already a matter of remembering a stable key, so it needs no new plumbing.
# Until then `all_known` is on and the book shows everything.
var known_recipes: Dictionary = {}
var all_known := true


func knows_recipe(key: String) -> bool:
	return all_known or known_recipes.has(key)


## Learn a recipe. Returns true if it was actually new, so callers can announce
## it without having to check first.
func learn_recipe(key: String) -> bool:
	if known_recipes.has(key):
		return false
	known_recipes[key] = true
	if _book_panel != null and _book_panel.visible:
		_rebuild_book()
	return true
var _hotbar_cells: Array = []      # always-visible hotbar slot views
var _grid_cells: Array = []        # full-inventory slot buttons
var _equip_cell: Dictionary = {}   # the 2-slot-tall Suit equip slot view

# --- crafting stations ---
var _station_open: Station = null  # non-null while a station panel is open
var _station_panel: Panel
var _station_title: Label
var _station_cells: Array = []     # storage slot views (rebuilt per open; may span a chest group)
var _stor_container: Control       # holds the (absolutely-positioned) storage cells
var _stor_map: Array = []          # storage cell index -> {st: Station, slot: int}
var _pinv_cells: Array = []        # player-inventory slot views inside the station panel
var _pinv_label: Label             # "Your inventory" header (repositioned per station size)
var _pinv_grid: GridContainer      # the inventory grid inside the station panel
var _rx := 0                       # right-column x
var _station_store_label: Label    # "<station> contents" header above its storage
var _left_header: Label            # "Blueprints" / "Actions" header on the left column
var _refine_btn: Button            # Smelter action
var _craft_row: Control            # holds per-station craft buttons
var _craft_scroll: ScrollContainer # scrolls them when a bench has many
var _craft_buttons: Array = []     # current station's craft buttons
var _preview_label: Label          # live craft-stat preview (Fabricator/Shipworks)
var _job_label: Label              # "Refining… 60%" / "Crafting… 30%" while a job runs
var _markers: Array[Label] = []   # one navigation marker per planet


func _ready() -> void:
	# collision capsule
	_body_shape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	_body_shape.shape = cap
	add_child(_body_shape)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, EYE_HEIGHT, 0)  # eye height above body center
	_camera.far = 14000.0
	add_child(_camera)

	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0, 0, -REACH)
	_ray.collide_with_bodies = true
	_camera.add_child(_ray)

	# view-model: whatever you're actively holding (weapon/drill/block) shows in
	# your hand, so a melee weapon's bonus damage requires actually wielding it --
	# not just carrying one somewhere in the pack.
	_hand_pivot = Node3D.new()
	_hand_pivot.position = HAND_IDLE_POS
	_hand_pivot.rotation = HAND_IDLE_ROT
	_camera.add_child(_hand_pivot)

	# With axis-snapped gravity the ground is always flat, so keep the character
	# glued to it and don't let it slide.
	floor_max_angle = deg_to_rad(50)
	floor_stop_on_slope = true
	floor_snap_length = 0.5
	floor_constant_speed = true
	_home_parent = get_parent()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# wireframe outline that hugs the block under the crosshair
	_outline = MeshInstance3D.new()
	_outline.mesh = _make_outline_mesh()
	_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # don't shadow the block
	var om := StandardMaterial3D.new()
	om.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	om.albedo_color = Color(0, 0, 0, 0.9)
	om.no_depth_test = false
	_outline.material_override = om
	_outline.visible = false
	_ghost = MeshInstance3D.new()
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost_mat = StandardMaterial3D.new()
	var gm := _ghost_mat
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Faint on purpose. It is drawn with no depth test and with both faces of the
	# box showing, so the blend happens twice and any alpha reads as roughly
	# double what the number says -- it was closer to a solid block sitting over
	# the world than to a preview of one.
	gm.albedo_color = Color(GHOST_COLOR.r, GHOST_COLOR.g, GHOST_COLOR.b, GHOST_ALPHA)
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Draw over the world: a preview sunk inside terrain is worse than useless.
	gm.no_depth_test = true
	_ghost.material_override = gm
	# Blueprint diff: the cells a refused build got wrong, shown in place. A
	# count in a toast tells you there is a mistake; this tells you where.
	_diff = MeshInstance3D.new()
	_diff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_color = Color(1.0, 0.35, 0.3, 0.55)
	dm.no_depth_test = true
	_diff.material_override = dm
	_diff.visible = false
	_ghost.visible = false

	_crack = MeshInstance3D.new()
	_crack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_crack_mat = ShaderMaterial.new()
	_crack_mat.shader = load("res://shaders/block_crack.gdshader")
	_crack.material_override = _crack_mat
	_crack.visible = false
	if world != null:
		world.add_child(_outline)
		world.add_child(_ghost)
		world.add_child(_diff)
		world.add_child(_crack)
	else:
		get_parent().add_child(_outline)
		get_parent().add_child(_ghost)
		get_parent().add_child(_diff)
		get_parent().add_child(_crack)

	_init_inventory()
	_build_ui()
	_refresh_slots()


# 12-edge wireframe unit cube (slightly inflated) used as the targeting outline.
func _make_outline_mesh() -> ArrayMesh:
	var lo := -0.002
	var hi := 1.002
	var c := [
		Vector3(lo, lo, lo), Vector3(hi, lo, lo), Vector3(hi, hi, lo), Vector3(lo, hi, lo),
		Vector3(lo, lo, hi), Vector3(hi, lo, hi), Vector3(hi, hi, hi), Vector3(lo, hi, hi)]
	var edges := [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7]]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(c[e[0]])
		verts.append(c[e[1]])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	return mesh


# --- inventory ---------------------------------------------------------------

## Everything a player carries between sessions, as plain data.
##
## The same set the single-player save keeps, gathered in one place because on a
## server it has to travel over the wire as well as onto disk -- two callers
## picking their own subsets is how a player ends up with their blocks but not
## the recipes they learned to use them.
func make_profile() -> Dictionary:
	return {
		"inv": inv,
		"active_slot": active_slot,
		"suit_slot": suit_slot,
		"known_recipes": known_recipes,
		"all_known": all_known,
	}


func apply_profile(d: Dictionary) -> void:
	if d.is_empty():
		return
	if d.has("inv"):
		inv = d["inv"]
	if d.has("suit_slot"):
		suit_slot = d["suit_slot"]
	active_slot = int(d.get("active_slot", 0))
	known_recipes = d.get("known_recipes", {})
	all_known = bool(d.get("all_known", true))
	_refresh_slots()


func _init_inventory() -> void:
	inv.clear()
	for i in SLOTS:
		inv.append({"id": Blocks.AIR, "count": 0, "props": {}, "src": "", "mat": {}})
	# You start with NOTHING. Everything comes out of the world.


# Add n of an item; fills matching stacks first, then empty slots. Returns leftover.
# Items with different props/src (e.g. copper from different planets) don't stack.
# --- tall (multi-cell) inventory items -------------------------------------
# A suit occupies TWO vertical cells. The lower cell holds a "cover" marker
# pointing back at its owner rather than an item of its own, so exactly one
# slot is ever the real thing and everything else keys off that.

## Owner index if this inventory slot is the lower half of a tall item, else -1.
func _cover_owner(i: int) -> int:
	if i < 0 or i >= inv.size():
		return -1
	return int(inv[i].get("cover", -1))


func _slot_free(i: int) -> bool:
	return i >= 0 and i < inv.size() and int(inv[i].get("count", 0)) <= 0 		and _cover_owner(i) < 0


## Can a two-cell item sit here? It needs the cell directly below, which rules
## out the bottom row. `ignore` lets an item test its own current footprint.
func _can_place_tall(i: int, ignore := -1) -> bool:
	var below := i + HOTBAR_SLOTS
	if below >= inv.size():
		return false
	if not (_slot_free(i) or (ignore >= 0 and i == ignore)):
		return false
	# Guard the sentinel: with no item to ignore, _cover_owner returning -1 for
	# "not a cover" would otherwise match ignore's own -1 and wave through a
	# cell that is genuinely occupied.
	return _slot_free(below) or (ignore >= 0 and _cover_owner(below) == ignore)


func _set_cover(i: int) -> void:
	var below := i + HOTBAR_SLOTS
	if below < inv.size():
		inv[below]["cover"] = i


func _free_cover(i: int) -> void:
	var below := i + HOTBAR_SLOTS
	if below < inv.size() and _cover_owner(below) == i:
		inv[below].erase("cover")


## Keeps cover markers honest after a slot's contents change.
func _sync_cover(i: int) -> void:
	if i < 0 or i >= inv.size():
		return
	var tall := int(inv[i].get("count", 0)) > 0 		and Blocks.item_cells_tall(int(inv[i]["id"])) > 1
	if tall:
		_set_cover(i)
	else:
		_free_cover(i)


func _add_item(id: int, n: int, props: Dictionary = {}, src: String = "", mat: Dictionary = {}) -> int:
	if id == Blocks.AIR or n <= 0:
		return n
	for s in inv:
		if s["id"] == id and s.get("src", "") == src and s["count"] > 0 and s["count"] < STACK_MAX:
			var add: int = mini(n, STACK_MAX - s["count"])
			s["count"] += add
			n -= add
			if n <= 0:
				return 0
	var tall := Blocks.item_cells_tall(id) > 1
	for i in inv.size():
		var s: Dictionary = inv[i]
		if s["count"] != 0 or _cover_owner(i) >= 0:
			continue
		# A two-cell item also needs the cell beneath it, so it can't take the
		# bottom row or squeeze in above something.
		if tall and not _can_place_tall(i):
			continue
		s["id"] = id
		s["props"] = props
		s["src"] = src
		s["mat"] = mat
		var add: int = mini(n, STACK_MAX)
		s["count"] = add
		n -= add
		_sync_cover(i)
		if n <= 0:
			return 0
	return n  # inventory full; leftover dropped


## Public entry points for things outside the player that hand it items or
## messages -- creature drops, mainly (see Creature._grant_drops).
func grant_item(id: int, n: int, props: Dictionary = {}) -> int:
	return _add_item(id, n, props)


func notify(msg: String) -> void:
	_toast(msg)


func _count_item(id: int) -> int:
	var total := 0
	for s in inv:
		if s["id"] == id:
			total += s["count"]
	return total


func _remove_item(id: int, n: int) -> int:
	for s in inv:
		if s["id"] == id and s["count"] > 0:
			var take: int = mini(n, s["count"])
			s["count"] -= take
			n -= take
			if s["count"] == 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break
	return n


func _selected_id() -> int:
	# Change counts as carrying it: a slot holding five eighths of a rock can
	# still place four more eighths, and reading as empty would strand them.
	var s = inv[active_slot]
	return s["id"] if (int(s["count"]) > 0 or int(s.get("eighths", 0)) > 0) else Blocks.AIR


## What this player is visibly doing, so others can draw it (see Net.player_state).
## 0 = nothing, 1 = mining, 2 = placing.
func action_state() -> int:
	if _place_flash > 0.0:
		return 2
	if _mine_time > 0.0:
		return 1
	return 0


# --- eighths ------------------------------------------------------------------
#
# A block placed as an eighth costs an EIGHTH, not the whole block. The change
# it leaves rides in the slot itself as a remainder of 0 to 7, so a stack is
# really `count` blocks plus `eighths`/8 of another one -- no second item type,
# no separate currency, and it saves and travels with the inventory it is part
# of because it IS the inventory.

## Spend one eighth of the active stack. Breaks a whole block open when there is
## no change left, which is what leaves you holding seven.
func _consume_eighth() -> bool:
	var s = inv[active_slot]
	var left := int(s.get("eighths", 0))
	if left > 0:
		s["eighths"] = left - 1
	elif int(s["count"]) > 0:
		s["count"] = int(s["count"]) - 1
		s["eighths"] = 7
	else:
		return false
	# An empty stack with no change left is an empty slot, not a slot holding
	# nothing in particular.
	if int(s["count"]) <= 0 and int(s.get("eighths", 0)) <= 0:
		_clear_slot(s)
	_refresh_slots()
	return true


## Put one eighth back, wherever the rest of that material already is. Eight of
## them make a block again.
func _add_eighth(id: int) -> void:
	for i in inv.size():
		var s = inv[i]
		if int(s.get("id", Blocks.AIR)) != id:
			continue
		if int(s["count"]) <= 0 and int(s.get("eighths", 0)) <= 0:
			continue
		var e := int(s.get("eighths", 0)) + 1
		if e >= 8:
			e -= 8
			s["count"] = int(s["count"]) + 1
		s["eighths"] = e
		_refresh_slots()
		return
	# None of that material carried: start a stack holding nothing but change.
	for i in inv.size():
		var s2 = inv[i]
		if int(s2["count"]) > 0 or int(s2.get("eighths", 0)) > 0:
			continue
		s2["id"] = id
		s2["count"] = 0
		s2["eighths"] = 1
		s2["props"] = {}
		s2["src"] = ""
		s2["mat"] = {}
		_refresh_slots()
		return
	_toast("Inventory full")


func _consume_active() -> void:
	_place_flash = 0.3
	_swing_t = 0.0   # same quick hand arc as a melee swing, so placing is visible
	var s = inv[active_slot]
	if s["count"] > 0:
		s["count"] -= 1
		if s["count"] == 0:
			s["id"] = Blocks.AIR
	_refresh_slots()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look += event.relative
	elif event is InputEventMouseButton and event.pressed:
		if inv_open or book_open or _station_open != null or menu_open or ui_typing:
			return  # a panel is open: clicks go to the UI
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if piloting:
			return  # no building while flying
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# right-click: open a station, or open/close a door, otherwise place a block
			var st := _looked_at_station()
			if st != null and not eva:
				_open_station(st)
			elif _try_eat():
				pass
			elif _try_assemble_machine():
				pass
			elif _try_toggle_door():
				pass
			else:
				_edit_block(false)  # placing is instant; breaking is hold-to-mine
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle_slot(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle_slot(1)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _station_open != null:
				_close_station()
			elif book_open:
				_toggle_book()
			elif inv_open:
				_toggle_inventory()
			elif _starmap_panel != null and _starmap_panel.visible:
				_close_starmap()
			else:
				menu_requested.emit()
		elif event.keycode == KEY_F5:
			if world != null and world.save_game():
				_toast("Saved")
			else:
				_toast("Save failed")
		elif event.keycode == KEY_F9:
			# Reload only while on foot -- avoids tearing down ship/pilot state.
			if piloting != null or aboard != null or eva:
				_toast("Can't load while flying")
			elif world != null and world.has_save():
				world.load_game()
				_toast("Loaded")
			else:
				_toast("No save found")
		elif event.keycode == KEY_E:
			if piloting != null:
				pass  # E rolls the ship while piloting -- not the inventory
			elif _station_open != null:
				_close_station()
			else:
				_toggle_inventory()
		elif _station_open != null:
			return  # a station panel is open: swallow other keys
		elif event.keycode == KEY_F:
			_toggle_pilot()
		elif event.keycode == KEY_T:
			_toggle_eva()
		elif event.keycode == KEY_M:
			# warp requires actually piloting a ship built with a Warp Drive, in
			# space -- an exception to "only F/Esc/mouse-look work while flying"
			_try_open_starmap()
		elif piloting:
			return  # while flying, only F/M/Esc/mouse-look do anything
		elif event.keycode == KEY_R:
			# Step through EVERY stair state: the straight run turned through
			# four quarters, then the corner through four. Facing is part of the
			# cycle rather than read from the camera, so the ghost always shows
			# precisely what will be placed.
			_stair_state = (_stair_state + 1) % Blocks.STAIR_STATES
			_toast("Stairs: %s" % Blocks.stair_state_name(_stair_state))
		elif event.keycode == KEY_C:
			fine_place = not fine_place
			_apply_place_mode_ui()
			_toast("Fine placing: %s" % ("ON — eighth blocks" if fine_place else "off"))
		elif event.keycode == KEY_B:
			if not (_book_search != null and _book_search.has_focus()):
				_toggle_book()
		elif event.keycode == KEY_G:
			if aboard == null and not eva:
				_start_ship()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_8:
			active_slot = event.keycode - KEY_1
			_refresh_slots()


func _cycle_slot(dir: int) -> void:
	active_slot = (active_slot + dir + HOTBAR_SLOTS) % HOTBAR_SLOTS
	_refresh_slots()


## Fine placing changes what every click does, so it is shown where the eye
## already is -- on the crosshair and on the ghost -- not only in a corner label.
func _apply_place_mode_ui() -> void:
	if _crosshair != null:
		_crosshair.text = "+ 1/8" if fine_place else "+"
		_crosshair.modulate = Color(1.0, 0.78, 0.30) if fine_place else Color(1, 1, 1)
		_crosshair.position.y = 0.0
	_apply_ghost_alpha()


func _toggle_book() -> void:
	book_open = not book_open
	if _book_panel != null:
		_book_panel.visible = book_open
		if book_open:
			_rebuild_book()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if book_open else Input.MOUSE_MODE_CAPTURED


## The Recipe Book: everything you know how to make, in one place. The game
## teaches almost none of this anywhere else -- multiblock patterns especially
## were unguessable without it.
func _build_book_ui(layer: CanvasLayer) -> void:
	_book_panel = Panel.new()
	_book_panel.set_anchors_preset(Control.PRESET_CENTER)
	_book_panel.custom_minimum_size = Vector2(620, 560)
	_book_panel.size = _book_panel.custom_minimum_size
	_book_panel.position = -_book_panel.size * 0.5
	_book_panel.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.10, 0.96)
	sb.border_color = Color(0.40, 0.52, 0.62, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	_book_panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(_book_panel)

	var title := Label.new()
	title.position = Vector2(14, 10)
	title.text = "Recipe Book"
	title.add_theme_font_size_override("font_size", 18)
	_book_panel.add_child(title)
	var hint := Label.new()
	hint.position = Vector2(14, 34)
	hint.text = "B to close"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.5)
	_book_panel.add_child(hint)

	_book_search = LineEdit.new()
	_book_search.position = Vector2(320, 12)
	_book_search.custom_minimum_size = Vector2(286, 28)
	_book_search.size = _book_search.custom_minimum_size
	_book_search.placeholder_text = "Search"
	_book_search.text_changed.connect(func(t):
		_book_query = t.to_lower()
		_rebuild_book())
	_book_panel.add_child(_book_search)

	# One filter per place a recipe can be made, built from the data so a new
	# station or structure shows up here without touching this function.
	var srcs := ["All"]
	for r in Blocks.all_recipes():
		if not srcs.has(str(r["src"])):
			srcs.append(str(r["src"]))
	var fx := 14.0
	var fy := 56.0
	for srcname in srcs:
		var b := Button.new()
		b.toggle_mode = true
		b.text = srcname
		b.add_theme_font_size_override("font_size", 12)
		b.position = Vector2(fx, fy)
		b.button_pressed = srcname == _book_src
		b.pressed.connect(func():
			_book_src = srcname
			_rebuild_book())
		_book_panel.add_child(b)
		_book_src_btns.append({"btn": b, "src": srcname})
		fx += b.get_minimum_size().x + 34.0
		if fx > 470.0:
			fx = 14.0
			fy += 30.0

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(12, fy + 36.0)
	scroll.custom_minimum_size = Vector2(596, 560.0 - fy - 48.0)
	scroll.size = scroll.custom_minimum_size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_book_panel.add_child(scroll)
	_book_vbox = VBoxContainer.new()
	_book_vbox.custom_minimum_size = Vector2(580, 0)
	scroll.add_child(_book_vbox)
	_book_empty = Label.new()
	_book_empty.position = Vector2(16, fy + 44.0)
	_book_empty.add_theme_font_size_override("font_size", 13)
	_book_empty.modulate = Color(1, 1, 1, 0.6)
	_book_panel.add_child(_book_empty)


func _rebuild_book() -> void:
	if _book_vbox == null:
		return
	for c in _book_vbox.get_children():
		c.queue_free()
	for e in _book_src_btns:
		e["btn"].button_pressed = e["src"] == _book_src
	var shown := 0
	for rec in Blocks.all_recipes():
		if not knows_recipe(str(rec["key"])):
			continue
		if _book_src != "All" and str(rec["src"]) != _book_src:
			continue
		var name := Blocks.name_of(int(rec["out"]))
		var needs := Blocks.recipe_needs(rec)
		if _book_query != "" and not (name.to_lower().contains(_book_query)
				or needs.to_lower().contains(_book_query)
				or str(rec["src"]).to_lower().contains(_book_query)):
			continue
		shown += 1
		var row := PanelContainer.new()
		var rsb := StyleBoxFlat.new()
		rsb.bg_color = Color(1, 1, 1, 0.04)
		rsb.set_corner_radius_all(4)
		rsb.content_margin_left = 10
		rsb.content_margin_right = 10
		rsb.content_margin_top = 7
		rsb.content_margin_bottom = 7
		row.add_theme_stylebox_override("panel", rsb)
		var vb := VBoxContainer.new()
		row.add_child(vb)
		var head := Label.new()
		var qty := "" if int(rec["n"]) == 1 else " x%d" % int(rec["n"])
		head.text = "%s%s" % [name, qty]
		head.add_theme_font_size_override("font_size", 15)
		head.modulate = Color(0.88, 0.94, 1.0)
		vb.add_child(head)
		var where := Label.new()
		where.text = str(rec["src"])
		where.add_theme_font_size_override("font_size", 11)
		where.modulate = Color(0.62, 0.80, 0.95)
		vb.add_child(where)
		# A multiblock has no ingredient list -- it is the pattern -- so the
		# materials line would just say so at length.
		var mats := Label.new()
		mats.visible = str(rec["diagram"]) == ""
		mats.text = needs
		mats.add_theme_font_size_override("font_size", 12)
		mats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		mats.custom_minimum_size = Vector2(548, 0)
		mats.modulate = Color(1, 1, 1, 0.75)
		vb.add_child(mats)
		if str(rec["diagram"]) != "":
			# Multiblocks are the reason this screen exists: the pattern is
			# shown in full, monospaced, so it can actually be copied.
			var dg := Label.new()
			dg.text = str(rec["diagram"])
			dg.add_theme_font_size_override("font_size", 12)
			dg.add_theme_color_override("font_color", Color(0.98, 0.86, 0.58))
			vb.add_child(dg)
		_book_vbox.add_child(row)
	_book_empty.text = "" if shown > 0 else "Nothing matches that."
	_book_empty.visible = shown == 0


func _toggle_inventory() -> void:
	inv_open = not inv_open
	if _inv_panel != null:
		_inv_panel.visible = inv_open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if inv_open else Input.MOUSE_MODE_CAPTURED
	_refresh_slots()


# --- star map / warp travel -----------------------------------------------------

func _build_starmap_ui(layer: CanvasLayer) -> void:
	_starmap_panel = Panel.new()
	_starmap_panel.set_anchors_preset(Control.PRESET_CENTER)
	_starmap_panel.custom_minimum_size = Vector2(360, 420)
	_starmap_panel.size = _starmap_panel.custom_minimum_size
	_starmap_panel.position = -_starmap_panel.size * 0.5
	_starmap_panel.visible = false
	layer.add_child(_starmap_panel)

	var title := Label.new()
	title.text = "Star Map"
	title.position = Vector2(14, 8)
	_starmap_panel.add_child(title)
	var hint := Label.new()
	hint.text = "Select a system, then Warp (on foot only)"
	hint.modulate = Color(1, 1, 1, 0.6)
	hint.position = Vector2(14, 30)
	_starmap_panel.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(12, 56)
	scroll.custom_minimum_size = Vector2(336, 316)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_starmap_panel.add_child(scroll)
	_starmap_list = VBoxContainer.new()
	_starmap_list.add_theme_constant_override("separation", 4)
	_starmap_list.custom_minimum_size = Vector2(320, 0)
	scroll.add_child(_starmap_list)

	_starmap_warp_btn = Button.new()
	_starmap_warp_btn.text = "Warp"
	_starmap_warp_btn.position = Vector2(12, 380)
	_starmap_warp_btn.custom_minimum_size = Vector2(336, 32)
	_starmap_warp_btn.pressed.connect(_on_warp_pressed)
	_starmap_panel.add_child(_starmap_warp_btn)


# Warp requires actually flying a ship built with a Warp Drive, out in space --
# not just standing on a planet. Toasts an explanation for whichever condition
# is missing instead of silently doing nothing.
func _try_open_starmap() -> void:
	if _starmap_panel == null or world == null or world.galaxy == null:
		return
	if _starmap_panel.visible:
		_close_starmap()
		return
	if piloting == null:
		_toast("Fly a ship with a Warp Drive to open the star map")
		return
	if not piloting.has_warp_drive():
		_toast("This ship has no Warp Drive")
		return
	if piloting.in_gravity:
		_toast("Must be in space to warp")
		return
	_refresh_starmap_rows()
	_starmap_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_starmap() -> void:
	if _starmap_panel != null:
		_starmap_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _refresh_starmap_rows() -> void:
	for r in _starmap_rows:
		r.queue_free()
	_starmap_rows.clear()
	_starmap_selected = world.current_system_index
	for i in world.galaxy.systems.size():
		var s: Dictionary = world.galaxy.systems[i]
		var b := Button.new()
		b.custom_minimum_size = Vector2(320, 32)
		b.toggle_mode = true
		b.button_pressed = i == _starmap_selected
		var cur := "   (current)" if i == world.current_system_index else ""
		b.text = "%s -- %s -- %d planets%s" % [
			s["name"], Galaxy.civ_name(s["civ_tier"]), int(s["planet_count"]), cur]
		b.pressed.connect(_on_starmap_row_pressed.bind(i))
		_starmap_list.add_child(b)
		_starmap_rows.append(b)


func _on_starmap_row_pressed(i: int) -> void:
	_starmap_selected = i
	for j in _starmap_rows.size():
		_starmap_rows[j].button_pressed = j == i


func _on_warp_pressed() -> void:
	if world == null or _starmap_selected < 0:
		return
	# re-check on click too -- the ship could have left space, lost its drive,
	# or you could've exited the cockpit while the map sat open
	if piloting == null or not is_instance_valid(piloting):
		_toast("Not piloting a ship")
		_close_starmap()
		return
	if not piloting.has_warp_drive():
		_toast("This ship has no Warp Drive")
		return
	if piloting.in_gravity:
		_toast("Must be in space to warp")
		return
	if _starmap_selected == world.current_system_index:
		_toast("Already in this system")
		return
	var sysdef := world.warp_to_system(_starmap_selected, piloting)
	_close_starmap()
	if sysdef.is_empty():
		_toast("Warp failed")
		return
	_toast("Warped to %s (%s)" % [sysdef["name"], Galaxy.civ_name(sysdef["civ_tier"])])
	if _system_label != null:
		_system_label.text = "%s system\n%s" % [sysdef["name"], Galaxy.civ_name(sysdef["civ_tier"])]


## Pull the eye down if there is something directly overhead.
##
## Cheaper and more exact than making the capsule taller: a taller capsule
## changes what gaps you fit through, which is a movement change nobody asked
## for, while this only moves the camera and only when a ceiling is actually
## there. It drops instantly (being late is the bug) and eases back up (so
## clearing a doorway does not snap the view).
func _update_eye_clearance(delta: float) -> void:
	if _camera == null:
		return
	if piloting != null:
		# Flying: the view belongs to the cockpit, and a hull panel a few
		# centimetres over your head is not a ceiling you are about to headbutt.
		_camera.position.y = move_toward(_camera.position.y, EYE_HEIGHT, delta * 3.0)
		return
	var want := EYE_HEIGHT
	var space := get_world_3d().direct_space_state
	if space != null:
		var up := global_transform.basis.y
		var q := PhysicsRayQueryParameters3D.create(global_position,
			global_position + up * (EYE_HEIGHT + EYE_CLEARANCE))
		q.exclude = [get_rid()]
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d: float = global_position.distance_to(hit["position"])
			want = clampf(d - EYE_CLEARANCE, 0.0, EYE_HEIGHT)
	if want < _camera.position.y:
		_camera.position.y = want
	else:
		_camera.position.y = move_toward(_camera.position.y, want, delta * 3.0)


func _physics_process(delta: float) -> void:
	_update_eye_clearance(delta)
	# The build diff fades on its own; it is a hint, not a mode.
	if _diff != null and _diff.visible:
		_diff_t -= delta
		if _diff_t <= 0.0:
			_diff.visible = false
	if _toast_time > 0.0:
		_toast_time -= delta
		if _toast_time <= 0.0 and _toast_label != null:
			_toast_label.visible = false
	# Freeze in place until the ground beneath a fresh spawn has actually
	# streamed in and been given collision. Falling through the world for the
	# first second after respawning is not a physics problem, it is an ordering
	# one -- the player arrives before the terrain does.
	if _await_ground > 0.0:
		_await_ground -= delta
		velocity = Vector3.ZERO
		if _ground_ready():
			_await_ground = 0.0
		else:
			_update_survival_ui()
			return
	_process_survival(delta)
	_check_ship_transitions()
	_update_swing(delta)
	if _station_open != null:
		if is_instance_valid(_station_open):
			_refresh_station_ui()  # live-update job progress + finished output
		else:
			_close_station()
	if eva:
		_eva_physics(delta)
		_process_mining(delta)
		_update_ui()
		return
	if piloting != null:
		if _outline != null:
			_outline.visible = false
		if _ghost != null:
			_ghost.visible = false
		if _crack != null:
			_crack.visible = false
		_pilot_physics(delta)
		_update_ui()
		return
	if aboard != null:
		if not is_instance_valid(aboard):
			aboard = null
		else:
			# Walk the interior in the ship's local frame (decoupled from how the
			# ship moves through space -- rock solid at any speed/orientation).
			grounded = true
			_walk_interior(delta, aboard)
			_process_mining(delta)
			_update_ui()
			return
	var g := world.gravity_at(global_position) if world else Vector3(0, -9.8, 0)
	var up := -g.normalized() if g.length() > 0.01 else Vector3.UP
	if _in_water(global_position + up * 0.5) or _in_water(global_position - up * 0.8):
		# align to the snapped axis (like walking) so you stay upright vs gravity
		var sup := -_snap_to_axis(g) if g.length() > 0.01 else Vector3.UP
		_swim(delta, sup)
	else:
		grounded = g.length() > FLIGHT_THRESHOLD
		if grounded:
			_walk(delta, -_snap_to_axis(g), g.length())
		else:
			_process_float(delta)
	_process_mining(delta)
	_update_ui()


# --- piloting -----------------------------------------------------------------

func _pilot_physics(delta: float) -> void:
	if not is_instance_valid(piloting):
		_exit_pilot()
		return
	var ascend := 0.0
	if not menu_open and not ui_typing and Input.is_physical_key_pressed(KEY_SPACE): ascend += 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT): ascend -= 1.0
	var roll := 0.0
	if Input.is_physical_key_pressed(KEY_Q): roll += 1.0
	if Input.is_physical_key_pressed(KEY_E): roll -= 1.0
	piloting.fly(delta, world, {
		"move": _move_input(),
		"ascend": ascend,
		"roll": roll,
		"look": _look,
	})
	_look = Vector2.ZERO
	# ride along so we exit next to the ship and HUD/gravity queries stay local
	global_position = piloting.global_position


func _toggle_pilot() -> void:
	if piloting != null:
		_exit_pilot()
		return
	if world == null:
		return
	var ship := aboard if aboard != null else world.nearest_ship(global_position)
	if ship == null:
		return
	var cockpit_world := ship.to_global(ship.cockpit_local() + Vector3(0.5, 0.5, 0.5))
	if global_position.distance_to(cockpit_world) > 4.0:
		return
	if not ship.get_status()["can_fly"]:
		return
	_enter_pilot(ship)


func _enter_pilot(ship: Ship) -> void:
	if aboard != null:
		_unboard()
	piloting = ship
	ship.flying = true
	ship.velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	_body_shape.disabled = true
	ship.enable_chase_camera()


func _exit_pilot() -> void:
	var ship := piloting
	piloting = null
	_body_shape.disabled = false
	_camera.make_current()
	velocity = Vector3.ZERO
	if not is_instance_valid(ship):
		return
	ship.flying = false
	ship.hide_landing_reticle()

	var g := world.gravity_at(ship.global_position) if world else Vector3.DOWN
	if g.length() < FLIGHT_THRESHOLD or ship.is_habitable():
		# In space, or any habitable ship: step out INTO the cabin (its sealed,
		# life-supported interior) rather than onto the hull -- so being inside is safe.
		_board(ship)
	else:
		# On/near a planet: park the ship and stand on it; planet gravity holds you.
		ship.velocity = Vector3.ZERO
		global_position = ship.global_position + ship.global_transform.basis * (ship.center_local() + Vector3(0, 2.0, 0))
		if g.length() > 0.01:
			look_at(global_position - global_transform.basis.z, -g.normalized())


# --- walking inside a ship (aboard) -------------------------------------------

func _board(ship: Ship, reposition := true) -> void:
	aboard = ship
	reparent(ship, true)          # child of the ship: local position rides along automatically
	# Level out (pitch/roll relative to the ship go to zero, since _walk_interior
	# only ever yaws around local Y) but keep facing whichever way you were
	# already looking, flattened onto the ship's own horizontal plane -- a bare
	# `rotation = Vector3.ZERO` here used to snap your view to the ship's own
	# forward axis on EVERY board, including just brushing against the hull.
	var ship_up := ship.global_transform.basis.y
	var fwd := -global_transform.basis.z
	var flat_fwd := fwd - ship_up * fwd.dot(ship_up)
	if flat_fwd.length() > 0.01:
		look_at(global_position + flat_fwd, ship_up)
	else:
		rotation = Vector3.ZERO
	if reposition:
		var stand := _find_interior_stand(ship, ship.cockpit_local())
		position = Vector3(stand) + Vector3(0.5, 1.0, 0.5)  # inside the ship, on the floor
	_pitch = 0.0
	_iv_y = 0.0
	velocity = Vector3.ZERO
	_body_shape.disabled = true   # interior movement is manual, not physics-swept


# Walk in / out through an open door: board when you step inside a ship's hull,
# unboard when you step back out. (Sealed ships block you until a door is open.)
func _check_ship_transitions() -> void:
	if piloting != null or eva:
		return
	if aboard != null:
		if not is_instance_valid(aboard) or not aboard.contains(global_position):
			_unboard()
	elif world != null:
		var s := world.nearest_ship(global_position)
		if s != null and s.contains(global_position):
			_board(s, false)


func _unboard() -> void:
	if aboard != null and get_parent() == aboard:
		reparent(_home_parent, true)
	aboard = null
	_body_shape.disabled = false
	velocity = Vector3.ZERO


# --- EVA (float outside on a tether) ------------------------------------------

func _toggle_eva() -> void:
	if eva:
		var ship := _eva_ship
		_end_eva()
		if is_instance_valid(ship):
			_board(ship)  # climb back inside
	elif aboard != null:
		_begin_eva()


func _begin_eva() -> void:
	var ship := aboard
	_eva_ship = ship
	_eva_anchor_local = ship.cockpit_local() + Vector3(0.5, 0.5, 0.5)  # tether roots at the cockpit
	aboard = null
	reparent(_home_parent, true)
	eva = true
	_body_shape.disabled = false
	# emerge just above the ship, out in open space
	global_position = ship.to_global(_eva_anchor_local + Vector3(0, 3.0, 0))
	velocity = Vector3.ZERO
	_ensure_tether()


func _end_eva() -> void:
	eva = false
	_eva_ship = null
	if _tether != null:
		_tether.visible = false


func _eva_physics(delta: float) -> void:
	if not is_instance_valid(_eva_ship):
		_end_eva()
		return
	_process_float(delta)  # full 6-axis flight, same as deep-space player movement
	# tether constraint: can't drift past TETHER_LEN from the (moving) anchor
	var anchor := _eva_ship.to_global(_eva_anchor_local)
	var vec := global_position - anchor
	var d := vec.length()
	if d > TETHER_LEN:
		var dir := vec / d
		global_position = anchor + dir * TETHER_LEN
		var outward := velocity.dot(dir)
		if outward > 0.0:
			velocity -= dir * outward
	_update_tether(anchor)


func _ensure_tether() -> void:
	if _tether == null:
		_tether = MeshInstance3D.new()
		_tether.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.85, 0.3)
		_tether.material_override = mat
		_home_parent.add_child(_tether)
	_tether.visible = true


func _update_tether(anchor: Vector3) -> void:
	var m := _tether.mesh as ImmediateMesh
	m.clear_surfaces()
	m.surface_begin(Mesh.PRIMITIVE_LINES)
	m.surface_add_vertex(anchor)
	m.surface_add_vertex(global_position)
	m.surface_end()


# Find a standable interior cell near the cockpit: an air cell with headroom and a
# solid floor directly below. Falls back to just above the cockpit (flat builds).
func _find_interior_stand(ship: Ship, cockpit: Vector3) -> Vector3i:
	var cc := Vector3i(roundi(cockpit.x), roundi(cockpit.y), roundi(cockpit.z))
	var best := cc + Vector3i(0, 1, 0)  # fallback: on top of the cockpit
	var best_d := 1.0e9
	for dx in range(-3, 4):
		for dy in range(-1, 3):
			for dz in range(-3, 4):
				var c := cc + Vector3i(dx, dy, dz)
				if _is_standable(ship, c):
					var d := Vector2(dx, dz).length() + absf(dy) * 0.5
					if d < best_d:
						best_d = d
						best = c
	return best


func _is_standable(ship: Ship, c: Vector3i) -> bool:
	return (not ship.blocks.has(c)) \
		and (not ship.blocks.has(c + Vector3i(0, 1, 0))) \
		and ship.blocks.has(c + Vector3i(0, -1, 0))


## Manual voxel character controller in the ship's local frame.
func _walk_interior(delta: float, ship: Ship) -> void:
	rotation.y -= _look.x * MOUSE_SENS       # yaw around the ship's up
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var input := _move_input()
	var yaw := rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var wish := right * input.x + fwd * input.y
	if wish.length() > 0.001:
		wish = wish.normalized()
	var disp := wish * WALK_SPEED * (STARVE_SPEED_MULT if hunger <= 0.0 else 1.0) * delta

	if _interior_floor and Input.is_physical_key_pressed(KEY_SPACE):
		_iv_y = JUMP_SPEED
	_iv_y -= ARTIFICIAL_G * delta

	var pos := position
	# horizontal, per-axis so you slide along walls
	var tx := pos
	tx.x += disp.x
	if not _interior_blocked(ship, tx):
		pos.x = tx.x
	var tz := pos
	tz.z += disp.z
	if not _interior_blocked(ship, tz):
		pos.z = tz.z
	# vertical + floor
	pos.y += _iv_y * delta
	var ft := _interior_floor_top(ship, pos)
	_interior_floor = false
	if pos.y - 0.9 <= ft:
		pos.y = ft + 0.9
		if _iv_y < 0.0:
			_iv_y = 0.0
		_interior_floor = true
	position = pos

	# safety: if you walked off an open edge and fell away, snap back to the cockpit
	if position.y < -60.0:
		position = ship.cockpit_local() + Vector3(0.5, 2.0, 0.5)
		_iv_y = 0.0


# Highest solid block top at or below the player's feet (ship-local Y).
# A ship cell is solid unless it's empty or an open doorway.
func _ship_solid(ship: Ship, cell: Vector3i) -> bool:
	return ship.blocks.has(cell) and ship.blocks[cell] != Blocks.DOOR_OPEN


func _interior_floor_top(ship: Ship, pos: Vector3) -> float:
	var cx := floori(pos.x)
	var cz := floori(pos.z)
	var start := floori(pos.y - 0.9 + 0.02)
	for y in range(start, start - 128, -1):
		if _ship_solid(ship, Vector3i(cx, y, cz)):
			return float(y + 1)
	return -1.0e9


# Is a wall block occupying the player's body column at this local position?
func _interior_blocked(ship: Ship, pos: Vector3) -> bool:
	var cx := floori(pos.x)
	var cz := floori(pos.z)
	var feet := pos.y - 0.9
	for h in [0.25, 1.0, 1.6]:
		if _ship_solid(ship, Vector3i(cx, floori(feet + h), cz)):
			return true
	return false


# --- GROUND -------------------------------------------------------------------

## Walk on a surface whose local "up" is given, under gravity magnitude `gmag`.
## Used both for planets (up = -snapped gravity) and for standing inside a ship
## in space (up = ship's up, gmag = artificial gravity).
# Smoothly rotate the body so its local +Y aligns with `up` (stand upright).
func _align_up(up: Vector3, delta: float) -> void:
	var body_up := global_transform.basis.y
	var dot := clampf(body_up.dot(up), -1.0, 1.0)
	if dot < -0.9999:
		# nearly upside-down: nudge with a perpendicular axis to avoid a degenerate quat
		global_transform.basis = Basis(global_transform.basis.x, PI) * global_transform.basis
	elif dot < 0.9999:
		var full := Quaternion(body_up, up)
		var step := Quaternion.IDENTITY.slerp(full, clampf(delta * ALIGN_SPEED, 0.0, 1.0))
		global_transform.basis = Basis(step) * global_transform.basis
	global_transform.basis = global_transform.basis.orthonormalized()


func _walk(delta: float, up: Vector3, gmag: float) -> void:
	_align_up(up, delta)

	# Yaw around local up; pitch the camera.
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	# Movement on the tangent plane.
	var input := _move_input()
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	var wish := right * input.x + fwd * input.y
	wish = wish - up * wish.dot(up)
	if wish.length() > 0.001:
		wish = wish.normalized()

	# Split velocity into tangent (horizontal) and along-up (vertical) parts.
	var v_up := velocity.dot(up)
	# Starving drags: you keep moving, just not well.
	var horiz := wish * WALK_SPEED * (STARVE_SPEED_MULT if hunger <= 0.0 else 1.0)

	v_up += -gmag * delta  # gravity pulls along -up (the snapped down axis)

	if is_on_floor():
		if v_up < 0.0:
			v_up = 0.0
		if not menu_open and not ui_typing and Input.is_physical_key_pressed(KEY_SPACE):
			v_up = JUMP_SPEED
	# No thrust once your feet leave the ground: a jump is a jump. There is no
	# jetpack in the game yet, and being able to hold jump and climb was standing
	# in for one -- if you are down a hole, the way out is to build your way out.

	velocity = horiz + up * v_up
	up_direction = up
	move_and_slide()
	_auto_step_up(up, horiz, delta)


## Walk up a half-height ledge (slabs, and later stairs) without jumping.
##
## CharacterBody3D has no built-in step handling, so a 0.5-high slab stops you
## dead the same way a wall does. This looks for exactly that case -- blocked at
## foot height, but clear one step higher -- and lifts the body onto the ledge,
## which is what makes slabs feel like stairs instead of obstacles.
const STEP_HEIGHT := 0.6      # a slab is 0.5; the margin covers uneven ground
const STEP_PROBE := 0.3       # how far ahead to test for the obstruction

func _auto_step_up(up: Vector3, horiz: Vector3, delta: float) -> void:
	if not is_on_floor() or horiz.length() < 0.05:
		return
	var dir := horiz.normalized() * STEP_PROBE
	var xf := global_transform
	# Nothing in the way? Then there is nothing to step onto.
	if not test_move(xf, dir):
		return
	# Blocked down here but clear a step up means a ledge, not a wall.
	var raised := xf
	raised.origin += up * STEP_HEIGHT
	if test_move(raised, dir):
		return
	# Rise only as far as the ledge actually needs: probe down from the raised
	# position so a 0.5 slab lifts 0.5, not the full STEP_HEIGHT (which would
	# read as a hop). floor snapping settles any remainder.
	var ahead := raised
	ahead.origin += dir
	var drop := KinematicCollision3D.new()
	var lift := STEP_HEIGHT
	if test_move(ahead, -up * STEP_HEIGHT, drop):
		lift = maxf(STEP_HEIGHT - drop.get_travel().length(), 0.0)
	global_position += up * lift


# --- SURVIVAL -----------------------------------------------------------------

# You breathe inside a ship (cockpit or interior) or within an atmospheric planet's
# air. Space, airless worlds, high altitude and being underwater all cut off your air.
# True when you're kept alive by a ship: driving a habitable one, OR physically
# standing inside any habitable ship's sealed, life-supported interior. An open or
# unpowered ship does NOT shelter you.
func _in_safe_ship() -> bool:
	if piloting != null and is_instance_valid(piloting):
		return piloting.is_habitable()  # in the cockpit, driving
	if aboard != null and is_instance_valid(aboard) and aboard.is_inside_pressurized(global_position):
		return true
	if world != null:
		var s := world.nearest_ship(global_position)
		if s != null and s.is_inside_pressurized(global_position):
			return true
	return false


## The base the player is standing in, or {} outdoors. Refreshed once per
## survival tick so everything downstream reads one consistent snapshot.
func _update_base(delta: float) -> void:
	base_status = {}
	if world == null or piloting != null or aboard != null or eva:
		return
	var p := world.nearest_planet(global_position)
	if p == null or p.altitude(global_position) > 300.0:
		return
	base_status = p.update_base(p.world_to_voxel(global_position + Vector3(0, 0.2, 0)), delta)
	if not bool(base_status.get("sealed", false)):
		base_status = {}


## Is the base you are in actually keeping you alive? A sealed room only counts
## once its Life Support has put real air in it.
func base_breathable() -> bool:
	return float(base_status.get("o2", 0.0)) >= 0.15


func base_safe_temp() -> bool:
	var t := float(base_status.get("temp", -999.0))
	return t > 0.0 and t < 45.0


func _has_air() -> bool:
	if _in_safe_ship():
		return true  # sealed ship with life support
	var up := global_transform.basis.y
	if _in_water(global_position + up * 0.7):
		return false  # head underwater
	if base_breathable():
		return true   # your own sealed, life-supported base
	if world == null:
		return false
	var p := world.nearest_planet(global_position)
	return p != null and p.has_atmosphere and p.altitude(global_position) < p.atmo_height


const HAZARD_RANGE := 300.0   # exposed to a planet's hazard when within this altitude
const CLIMATE_RADIUS := 14.0  # a placed Climate Unit shelters everything within this range

# A base's answer to a ship's Life Support -- a planted Climate Unit fully negates
# hazard damage nearby, no suit required. Deliberately a DIFFERENT mechanic than
# the ship's sealed-hull check (there's no cheap way to flood-fill "is this voxel
# structure enclosed" for arbitrary player-built terrain), so it's proximity-based
# instead: build a base around one rather than needing a fully sealed room.
func _near_climate_unit() -> bool:
	if world == null:
		return false
	for st in world._stations:
		if is_instance_valid(st) and st.kind == Blocks.CLIMATE_UNIT \
				and st.global_position.distance_to(global_position) <= CLIMATE_RADIUS:
			return true
	return false


# Damage/sec from the current planet's climate when unprotected (0 if none, in
# space, sheltered in a ship, or near a planted Climate Unit).
func _hazard_dps() -> float:
	if _in_safe_ship() or _near_climate_unit() or world == null:
		return 0.0
	if base_safe_temp():
		return 0.0   # indoors, and the room is being held at a survivable temperature
	var p := world.nearest_planet(global_position)
	if p == null or p.hazard_dps <= 0.0:
		return 0.0
	if p.altitude(global_position) > HAZARD_RANGE:
		return 0.0
	return p.hazard_dps * (1.0 - _hazard_resist)  # an insulated suit reduces this


func _current_hazard() -> String:
	if _in_safe_ship() or _near_climate_unit() or world == null:
		return ""
	if base_safe_temp():
		return ""
	var p := world.nearest_planet(global_position)
	if p == null or p.hazard_dps <= 0.0 or p.altitude(global_position) > HAZARD_RANGE:
		return ""
	return p.hazard


func _life_support_text(ship: Ship) -> String:
	var st := ship.get_status()
	if not st["life_support"]:
		return "NO LIFE SUPPORT (craft one)"
	if not st["sealed"]:
		return "CABIN NOT SEALED"
	var air := float(st["air"])
	var chg := float(st["charge"])
	if air <= 0.0:
		return "AIR TANK EMPTY — refill at a base"
	var tanks := "Air %d%%  Power %d%%" % [int(air * 100.0), int(chg * 100.0)]
	if air < 0.25 or chg < 0.25:
		return "LOW — " + tanks
	return "Life support: " + tanks


func _process_survival(delta: float) -> void:
	_update_base(delta)
	# A ship only burns its tanks while you are actually living in it.
	var ride: Ship = piloting if piloting != null else aboard
	if ride != null and is_instance_valid(ride):
		ride.consume_life_support(delta)
	var air := _has_air()
	var hz := _hazard_dps()
	if air:
		oxygen = minf(oxygen + O2_REFILL * delta, _max_oxygen())
	else:
		oxygen = maxf(oxygen - O2_DRAIN * delta, 0.0)
	# Hunger drains all the time and faster while you are moving. It never stops
	# you playing outright: an empty stomach costs you health slowly and slows
	# you down, so running out is a problem you can still walk away from.
	_place_flash = maxf(_place_flash - delta, 0.0)
	var exerting := velocity.length() > 0.5
	hunger = maxf(hunger - (HUNGER_DRAIN + (HUNGER_EXERTION if exerting else 0.0)) * delta, 0.0)
	if hunger <= 0.0:
		health = maxf(health - STARVE_DMG * delta, 0.0)
	if oxygen <= 0.0:
		health = maxf(health - SUFFOCATE_DMG * delta, 0.0)
	if hz > 0.0:
		health = maxf(health - hz * delta, 0.0)
	elif air and oxygen > 0.0 and health < MAX_HEALTH and hunger >= HUNGER_REGEN_MIN:
		health = minf(health + HEALTH_REGEN * delta, MAX_HEALTH)
	if health <= 0.0:
		_respawn()
	_update_survival_ui()


## Damage from an external source (e.g. a hostile creature's bite). Suppressed
## while a habitable ship shelters you.
func take_damage(amount: float) -> void:
	if _in_safe_ship():
		return
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		_respawn()


## Is there real, collidable terrain under the player yet? Checked against the
## chunk's collision shape rather than the voxel data, because the voxels exist
## long before anything you can stand on does.
func _ground_ready() -> bool:
	if world == null:
		return true
	var p := world.nearest_planet(global_position)
	if p == null:
		return true
	var up := (global_position - p.global_position).normalized()
	for d in 4:
		var v := p.world_to_voxel(global_position - up * (1.0 + float(d)))
		var ch = p.loaded_chunks.get(p.chunk_of(v))
		if ch == null or not is_instance_valid(ch):
			continue
		if ch._collision != null and ch._collision.shape != null:
			return true
	return false


func _respawn() -> void:
	if eva:
		_end_eva()
	if piloting != null:
		_exit_pilot()
	if aboard != null:
		_unboard()
	if _home_parent != null and get_parent() != _home_parent:
		reparent(_home_parent, true)
	health = MAX_HEALTH
	oxygen = MAX_OXYGEN
	hunger = MAX_HUNGER
	velocity = Vector3.ZERO
	if world != null and not world.planets.is_empty():
		global_position = world.planets[0].find_spawn_point(Vector3.UP)
	# Hold still until there is ground. Chunks stream in asynchronously, so for
	# the first moments after a respawn there is nothing under you and gravity
	# drops you straight through the world.
	_await_ground = 6.0
	_toast("You blacked out — respawned at home")


# --- SWIMMING -----------------------------------------------------------------

const SWIM_SPEED := 6.0        # horizontal / dive-climb speed in water
const SWIM_ACCEL := 4.0        # how quickly velocity eases (water is draggy)
const SWIM_BUOY := 2.2         # gentle rise toward the surface when not diving

func _in_water(wp: Vector3) -> bool:
	if world == null:
		return false
	var p := world.nearest_planet(wp)
	if p == null or p.water_style != p.WATER_LIQUID:
		return false
	return p.get_id(p.world_to_voxel(wp)) == Blocks.WATER


# Buoyant, draggy movement: swim relative to the camera, hold Space to rise / Shift
# to dive, and float gently up to the surface when you let go.
func _swim(delta: float, up: Vector3) -> void:
	grounded = false
	_align_up(up, delta)
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var cam := _camera.global_transform.basis
	var input := _move_input()
	var wish := (-cam.z) * input.y + cam.x * input.x  # swim toward where you look
	var desired := Vector3.ZERO
	if wish.length() > 0.01:
		desired = wish.normalized() * SWIM_SPEED
	var vy := 0.0
	if not menu_open and not ui_typing and Input.is_physical_key_pressed(KEY_SPACE): vy += 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT): vy -= 1.0
	if vy != 0.0:
		desired += up * vy * SWIM_SPEED
	elif _in_water(global_position + up * 0.5):
		desired += up * SWIM_BUOY  # submerged & idle: bob up to the surface

	velocity = velocity.lerp(desired, clampf(delta * SWIM_ACCEL, 0.0, 1.0))
	up_direction = up
	move_and_slide()


# --- FLOAT --------------------------------------------------------------------

func _process_float(delta: float) -> void:
	# Free look: yaw around body up, pitch the camera. No forced orientation.
	if _look.x != 0.0:
		rotate(global_transform.basis.y, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var input := _move_input()
	var cam := _camera.global_transform.basis
	var fwd := -cam.z
	var right := cam.x
	var up := cam.y
	var vertical := 0.0
	if not menu_open and not ui_typing and Input.is_physical_key_pressed(KEY_SPACE):
		vertical += 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT):
		vertical -= 1.0

	var wish := (fwd * input.y + right * input.x + up * vertical)
	if wish.length() > 1.0:
		wish = wish.normalized()

	if wish.length() > 0.01:
		velocity = velocity.lerp(wish * FLY_SPEED, clampf(delta * FLY_ACCEL, 0.0, 1.0))
	else:
		velocity = velocity.lerp(Vector3.ZERO, clampf(delta * FLY_DAMP, 0.0, 1.0))

	up_direction = up
	move_and_slide()


## Nearest of the six cardinal directions to `v`, as a unit vector.
func _snap_to_axis(v: Vector3) -> Vector3:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


func _move_input() -> Vector2:
	if menu_open or ui_typing:
		return Vector2.ZERO
	var x := 0.0
	var y := 0.0
	if Input.is_physical_key_pressed(KEY_W): y += 1.0
	if Input.is_physical_key_pressed(KEY_S): y -= 1.0
	if Input.is_physical_key_pressed(KEY_D): x += 1.0
	if Input.is_physical_key_pressed(KEY_A): x -= 1.0
	return Vector2(x, y)


# --- voxel targeting ----------------------------------------------------------
# The physics ray tells us WHICH object we're aiming at + a surface point; a short
# DDA march through that object's voxel grid then finds the exact block (and the
# empty cell in front for placing). This is far more accurate than deriving the
# cell from the collision normal (which is unreliable with double-sided collision).

func _raycast_voxel() -> Dictionary:
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		# Nothing SOLID under the crosshair -- but non-collidable blocks (leaves,
		# open doors) are still real blocks you should be able to target. Against
		# open sky there is no collider at all, which used to mean a canopy could
		# only be aimed at where solid ground happened to line up behind it.
		# March the voxel grid anyway, on whatever body the player is at.
		return _dda_no_collider()
	var collider := _ray.get_collider()
	var hit := _ray.get_collision_point()
	var origin := _camera.global_position
	var dir := hit - origin
	if dir.length() < 0.0001:
		dir = -_camera.global_transform.basis.z
	dir = dir.normalized()
	if collider is Chunk:
		return _dda((collider as Chunk).planet, origin, dir, hit, "planet")
	if collider is Ship:
		return _dda(collider, origin, dir, hit, "ship")
	if collider is Station:
		return {"kind": "station", "obj": collider, "hit": false}
	if collider is Creature:
		return {"kind": "creature", "obj": collider, "hit": false}
	return {}


## Fallback for when the physics ray finds nothing: march the voxel grid of the
## body the player is on, so non-collidable blocks can still be aimed at.
func _dda_no_collider() -> Dictionary:
	if world == null or _camera == null:
		return {}
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	if aboard != null:
		return _dda(aboard, origin, dir, origin + dir, "ship", REACH)
	var planet := world.nearest_planet(origin)
	if planet == null:
		return {}
	return _dda(planet, origin, dir, origin + dir, "planet", REACH)


func _dda(obj: Object, origin_w: Vector3, dir_w: Vector3, hit_w: Vector3, kind: String,
		max_dist := 0.0) -> Dictionary:
	# march in the object's local voxel space (planets are axis-aligned; ships rotate)
	var ld: Vector3 = (obj.global_transform.basis.inverse() * dir_w).normalized()
	# march from the camera (not the surface hit) so an open door -- which has no
	# collider -- doesn't block finding whatever's actually being aimed at, on a
	# ship OR a planet base
	var start: Vector3 = obj.to_local(origin_w)
	var steps := 24
	var v := Vector3i(floori(start.x), floori(start.y), floori(start.z))
	var step := Vector3i(1 if ld.x >= 0.0 else -1, 1 if ld.y >= 0.0 else -1, 1 if ld.z >= 0.0 else -1)
	var tmax := Vector3(_tmax(start.x, ld.x), _tmax(start.y, ld.y), _tmax(start.z, ld.z))
	var tdelta := Vector3(_tdelta(ld.x), _tdelta(ld.y), _tdelta(ld.z))
	var normal := Vector3i.ZERO
	var prev := v
	# Distance marched so far. Only used by the no-collider fallback, where
	# nothing else bounds the march to REACH the way the physics ray does.
	var travelled := 0.0
	for i in steps:
		if max_dist > 0.0 and travelled > max_dist:
			break
		var id: int = obj.get_id(v)
		if id != Blocks.AIR and id != Blocks.WATER:
			# Partial-height blocks only fill part of their cell, so marching
			# whole cubes reports a hit (and an entry FACE) that doesn't match
			# what you can see. Aiming just over a slab's top surface used to
			# register as entering the cube's SIDE, which put the next slab
			# beside it instead of on top. Test the real box instead.
			var boxes := _shape_boxes_at(obj, v, id, kind)
			if boxes.is_empty():
				return {"hit": true, "kind": kind, "obj": obj, "voxel": v,
					"place": prev, "normal": normal, "id": id,
					"point": start + ld * travelled}
			# A shape can be several boxes (a stair's two steps, a conduit's
			# arms). Take the one the ray reaches FIRST, or its entry face is
			# whichever box happened to be listed first.
			var best_t := INF
			var best_n := Vector3i.ZERO
			for b in boxes:
				var bx := _ray_box(start, ld, b[0], b[1])
				if bx["hit"] and float(bx["t"]) < best_t:
					best_t = float(bx["t"])
					best_n = bx["normal"]
			if best_t < INF:
				return {"hit": true, "kind": kind, "obj": obj, "voxel": v,
					"place": v + best_n, "normal": best_n, "id": id,
					"point": start + ld * best_t}
			# Ray passed through the empty part of the cell -- keep marching.
		prev = v
		travelled = minf(tmax.x, minf(tmax.y, tmax.z))
		if tmax.x <= tmax.y and tmax.x <= tmax.z:
			v.x += step.x
			tmax.x += tdelta.x
			normal = Vector3i(-step.x, 0, 0)
		elif tmax.y <= tmax.z:
			v.y += step.y
			tmax.y += tdelta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			v.z += step.z
			tmax.z += tdelta.z
			normal = Vector3i(0, 0, -step.z)
	return {}


## The solid box of a partial-height block, in the object's local space.
## Returns {} for anything that fills its whole cell (so the caller keeps the
## cheap whole-cube path).
## The real solid parts of a cell, in the object's local space -- empty for a
## plain full cube, which takes the cheap path instead.
##
## This comes from Chunk.shape_boxes, the same definition the mesher and the
## outline use, so what you can aim at is exactly what you can see. Conduit is
## why this had to stop being a single box: a wire cell is mostly empty air, and
## treating it as a cube meant you could never aim past one to wire the next
## face of the same block.
func _shape_boxes_at(obj: Object, v: Vector3i, id: int, kind: String) -> Array:
	if kind != "planet":
		return []
	# A stacked pair fills the cell between them, so it behaves as a full block.
	if Blocks.is_stacked_slab(id):
		return []
	var low := Blocks.bottom_of(id)
	if low == Blocks.PARTS:
		# Each filled eighth is its own target, so you aim at, and mine, one
		# part at a time rather than the cell holding them.
		var cell := (obj as Planet).parts_at(v)
		var pb: Array = []
		for si in Blocks.PART_COUNT:
			if si >= cell.size() or cell[si] == Blocks.AIR:
				continue
			var o := Vector3(si % Blocks.PART_DIM,
				(si / Blocks.PART_DIM) % Blocks.PART_DIM,
				si / (Blocks.PART_DIM * Blocks.PART_DIM)) * 0.5
			pb.append([Vector3(v) + o, Vector3(v) + o + Vector3(0.5, 0.5, 0.5)])
		return pb
	if not (Blocks.is_slab(low) or low == Blocks.ROOF_SLAB
			or Blocks.is_stair(low) or low == Blocks.WIRE):
		return []
	var up: Vector3 = (obj as Planet)._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	var out: Array = []
	for b in Chunk.shape_boxes(id, up):
		out.append([Vector3(v) + (b[0] as Vector3), Vector3(v) + (b[1] as Vector3)])
	return out


## Slab-method ray/AABB test. Returns {hit, normal}, where normal points back
## along the face the ray entered through -- the same convention the DDA uses,
## so `voxel + normal` is the cell a new block should go into.
func _ray_box(o: Vector3, d: Vector3, lo: Vector3, hi: Vector3) -> Dictionary:
	var tmin := -INF
	var tmax := INF
	var axis := 0
	for i in 3:
		var di: float = d[i]
		var l: float = lo[i]
		var h: float = hi[i]
		if absf(di) < 1e-9:
			if o[i] < l or o[i] > h:
				return {"hit": false, "normal": Vector3i.ZERO, "t": INF}
			continue
		var t1: float = (l - o[i]) / di
		var t2: float = (h - o[i]) / di
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		if t1 > tmin:
			tmin = t1
			axis = i
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return {"hit": false, "normal": Vector3i.ZERO, "t": INF}
	if tmax < 0.0:
		return {"hit": false, "normal": Vector3i.ZERO, "t": INF}
	var n := [0, 0, 0]
	n[axis] = -1 if d[axis] > 0.0 else 1
	return {"hit": true, "normal": Vector3i(n[0], n[1], n[2]), "t": maxf(tmin, 0.0)}


func _tmax(s: float, d: float) -> float:
	if absf(d) < 1e-9:
		return INF
	var cell := floorf(s)
	return (cell + 1.0 - s) / d if d > 0.0 else (s - cell) / -d


func _tdelta(d: float) -> float:
	return INF if absf(d) < 1e-9 else absf(1.0 / d)


func _update_outline(tgt: Dictionary) -> void:
	if _outline == null:
		return
	var show: bool = not tgt.is_empty() and tgt.get("hit", false) \
		and not inv_open and _station_open == null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not show:
		_outline.visible = false
		if _ghost != null:
			_ghost.visible = false
		if _crack != null:
			_crack.visible = false
		return
	var obj = tgt["obj"]
	var v: Vector3i = tgt["voxel"]
	var b: Basis = obj.global_transform.basis
	var origin: Vector3 = obj.to_global(Vector3(v))
	# The outline hugs what is actually THERE, not the cell it sits in.
	#
	# A full cube drawn around a torch or a single eighth says you are pointing
	# at a block, when what you would break is a stick on a wall. The box comes
	# from the same shape table the mesher builds from, so the two cannot
	# disagree; a shape made of several boxes (a stair) is outlined by their
	# union, which is the cell it genuinely fills.
	var raw: int = obj.get_id(v)
	var lo := Vector3.ZERO
	var hi := Vector3.ONE
	if obj is Planet:
		var pl := obj as Planet
		var up: Vector3 = pl._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
		if Blocks.bottom_of(raw) == Blocks.PARTS:
			# One eighth, and specifically the one under the crosshair.
			var sv := _sub_hit(tgt)
			var o: Vector3i = sv - Vector3i(floori(sv.x / 2.0), floori(sv.y / 2.0),
				floori(sv.z / 2.0)) * 2
			lo = Vector3(o) * 0.5
			hi = lo + Vector3(0.5, 0.5, 0.5)
		elif Blocks.is_light(Blocks.bottom_of(raw)) 				and Blocks.bottom_of(raw) != Blocks.GLOW_LAMP:
			# A torch is a post on a wall, not a cube.
			var tb: Array = Chunk.torch_box(up)
			lo = tb[0]
			hi = tb[1]
		else:
			var boxes: Array = Chunk.shape_boxes(raw, up)
			if not boxes.is_empty():
				lo = boxes[0][0]
				hi = boxes[0][1]
				for bx in boxes:
					lo = Vector3(minf(lo.x, (bx[0] as Vector3).x),
						minf(lo.y, (bx[0] as Vector3).y), minf(lo.z, (bx[0] as Vector3).z))
					hi = Vector3(maxf(hi.x, (bx[1] as Vector3).x),
						maxf(hi.y, (bx[1] as Vector3).y), maxf(hi.z, (bx[1] as Vector3).z))
	var span := hi - lo
	if span.x > 0.001 and span.y > 0.001 and span.z > 0.001:
		b = b.scaled(span)
		origin = obj.to_global(Vector3(v) + lo)
	_outline.global_transform = Transform3D(b, origin)
	_outline.visible = true
	_update_ghost(tgt)
	_update_prospect(tgt)


## Translucent preview of the block about to be placed, in its ACTUAL shape --
## a slab shows as half a cell, a stair shows its step and which way it climbs.
## That is what makes choosing a stair's rotation and corner meaningful before
## committing: you can see the result and turn or press R until it looks right.
func _update_ghost(tgt: Dictionary) -> void:
	if _ghost == null:
		return
	if not ghost_enabled:
		_ghost.visible = false
		return
	var place_id := _selected_id()
	if place_id == Blocks.AIR or not (Blocks.is_placeable_block(place_id)
			or (fine_place and Blocks.is_partable(place_id))):
		_ghost.visible = false
		return
	var plan := _placement_plan(tgt, place_id)
	if plan.is_empty():
		_ghost.visible = false
		return
	var obj = tgt["obj"]
	var v: Vector3i = plan["voxel"]
	var value: int = plan["value"]
	var up := Vector3.UP
	if obj is Planet:
		up = (obj as Planet)._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	var boxes: Array
	var sig: String
	if plan.has("part"):
		# Show the exact eighth about to be filled. Without this the preview is
		# a whole cube and there is no way to tell which corner you are aiming
		# at until after you have placed it.
		var si := int(plan["part"])
		var o := Vector3(si % Blocks.PART_DIM,
			(si / Blocks.PART_DIM) % Blocks.PART_DIM,
			si / (Blocks.PART_DIM * Blocks.PART_DIM)) * 0.5
		boxes = [[o, o + Vector3(0.5, 0.5, 0.5)]]
		sig = "part%d|%d" % [si, value]
	else:
		boxes = Chunk.shape_boxes(value, up)
		# Rebuilding the mesh every frame would be wasteful; the shape only
		# changes when the block, its orientation, or the face you're on changes.
		sig = "%d|%s|%s" % [value, up, boxes.size()]
	if sig != _ghost_sig:
		_ghost_sig = sig
		_ghost.mesh = _make_ghost_mesh(boxes)
	_ghost.global_transform = Transform3D(obj.global_transform.basis, obj.to_global(Vector3(v)))
	_ghost.visible = true
	if _camera != null:
		_ghost_dist = _camera.global_position.distance_to(
			obj.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)))
		_apply_ghost_alpha()


## Colour the preview for the mode you are in, thinned by how close it is.
func _apply_ghost_alpha() -> void:
	if _ghost_mat == null:
		return
	var t := clampf((_ghost_dist - GHOST_FADE_NEAR)
		/ (GHOST_FADE_FAR - GHOST_FADE_NEAR), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)   # ease, so it does not visibly step as you walk
	var col := GHOST_COLOR_FINE if fine_place else GHOST_COLOR
	var a := (GHOST_ALPHA_FINE if fine_place else GHOST_ALPHA) 		* lerpf(GHOST_ALPHA_NEAR, 1.0, t)
	_ghost_mat.albedo_color = Color(col.r, col.g, col.b, a)


## Draws the break-up overlay on the block being mined, in that block's real
## shape, and hides it when nothing is being mined.
func _update_crack(obj: Object, v: Vector3i, raw: int, progress: float) -> void:
	if _crack == null:
		return
	if progress <= 0.001:
		_crack.visible = false
		return
	var up := Vector3.UP
	if obj is Planet:
		up = (obj as Planet)._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	var boxes := Chunk.shape_boxes(raw, up)
	var sig := "%d|%s" % [raw, up]
	if sig != _crack_sig:
		_crack_sig = sig
		# Actually inflate it. The comment here used to claim this and the code
		# did not do it, so the shell sat exactly coplanar with the block face
		# and the two fought for depth -- which is the streaky mess that shows
		# up over and around a block being mined.
		var proud: Array = []
		for b in boxes:
			proud.append([(b[0] as Vector3) - Vector3.ONE * 0.006,
				(b[1] as Vector3) + Vector3.ONE * 0.006])
		_crack.mesh = _make_ghost_mesh(proud)
	_crack_mat.set_shader_parameter("progress", clampf(progress, 0.0, 1.0))
	# The overlay draws in the block's own space, so every block would otherwise
	# crack identically. One number per voxel gives each its own break.
	var hsh: int = (v.x * 73856093) ^ (v.y * 19349663) ^ (v.z * 83492791)
	_crack_mat.set_shader_parameter("block_seed", float(absi(hsh) % 4096) / 4096.0)
	_crack.global_transform = Transform3D(obj.global_transform.basis, obj.to_global(Vector3(v)))
	_crack.visible = true


## A short burst of block-coloured debris where a block just broke, so it pops
## rather than silently vanishing.
func _break_burst(where: Vector3, col: Color) -> void:
	var ps := CPUParticles3D.new()
	# CPU rather than GPU particles: this project runs the GL Compatibility
	# renderer, where CPU particles are the dependable option.
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.12
	ps.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ps.material_override = mat
	ps.amount = 14
	ps.lifetime = 0.55
	ps.one_shot = true
	ps.explosiveness = 1.0
	ps.direction = Vector3.UP
	ps.spread = 75.0
	ps.initial_velocity_min = 1.5
	ps.initial_velocity_max = 3.5
	ps.gravity = Vector3.DOWN * 9.0
	ps.scale_amount_min = 0.6
	ps.scale_amount_max = 1.3
	var parent: Node = world if world != null else get_parent()
	parent.add_child(ps)
	ps.global_position = where
	ps.emitting = true
	# Clean itself up once the last particle has died.
	get_tree().create_timer(ps.lifetime + 0.3).timeout.connect(ps.queue_free)


func _make_ghost_mesh(boxes: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for bx in boxes:
		var lo: Vector3 = bx[0]
		var hi: Vector3 = bx[1]
		# nudge outward so the preview never z-fights the block behind it
		lo -= Vector3.ONE * 0.004
		hi += Vector3.ONE * 0.004
		for fi in 6:
			var q := Chunk._box_face(lo, hi, fi)
			# Normals matter here: the crack shader picks which two world axes
			# to grid by from the face normal, and without one it only resolved
			# correctly on the faces whose normal happened to default sensibly.
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			st.add_vertex(q[0]); st.add_vertex(q[1]); st.add_vertex(q[2])
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[3])
	return st.commit()


# --- block placing (right-click) ----------------------------------------------
# Breaking is handled by hold-to-mine in _process_mining.

func _edit_block(_break_it: bool) -> void:
	# Anything you build or mine can change what the block you are looking at
	# would become -- laying the last eighth of a campfire, banking one more rock
	# against a fire -- and the cursor is answered once per block, so that answer
	# has to be thrown away when the world under it moves.
	_prospect_key = Vector3i(9999, 9999, 9999)
	var place_id := _selected_id()
	if place_id == Blocks.AIR:
		return  # nothing selected / none left in this slot
	if Blocks.is_station(place_id):
		_place_station(place_id)
		return
	# Parts are placeable even when the item is not a BLOCK: Circuitry and Alloy
	# only exist as eighths, so gating them on is_placeable_block meant fine mode
	# could never place the very things it was built for.
	if not Blocks.is_placeable_block(place_id) and not (
			fine_place and Blocks.is_partable(place_id)):
		if place_id == Blocks.SUIT:
			_toast("Drag the Suit into its equip slot (Inventory) to wear it")
		elif Blocks.is_gear(place_id):
			_toast("%s is worn gear — it works automatically while carried" % Blocks.name_of(place_id))
		else:
			_toast("Can't place that")
		return
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		return
	var obj = tgt["obj"]
	var pv: Vector3i = tgt["place"]
	# Where this lands and what it becomes -- shared with the placement ghost so
	# the preview can't disagree with the result.
	var plan := _placement_plan(tgt, place_id)
	if plan.is_empty():
		return
	if plan.has("part") and tgt["kind"] == "planet":
		world.edit_part(obj as Planet, plan["voxel"], int(plan["part"]), int(plan["value"]))
		_consume_eighth()
		return
	# Slab-onto-slab lands in the cell you're POINTING AT, not the one beyond
	# it, so it takes an early exit before the normal adjacent-cell path.
	if tgt["kind"] == "planet" and plan["voxel"] != pv:
		world.edit_block(obj as Planet, plan["voxel"], plan["value"])
		_consume_active()
		return
	var placed_value: int = plan["value"]
	if tgt["kind"] == "planet":
		if obj.to_global(Vector3(pv) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			if place_id == Blocks.DOOR:
				# planet doors are two stacked voxels (see Planet.toggle_door) so
				# right-clicking either half always opens/closes the whole doorway
				var axis: Vector3i = Vector3i((obj as Planet)._axis_of(Vector3(pv) + Vector3(0.5, 0.5, 0.5)))
				if axis == Vector3i.ZERO:
					axis = Vector3i(0, 1, 0)
				world.edit_block(obj as Planet, pv, place_id)
				world.edit_block(obj as Planet, pv + axis, place_id)
			else:
				world.edit_block(obj as Planet, pv, placed_value)
			_consume_active()

	elif tgt["kind"] == "ship":
		if obj.to_global(Vector3(pv) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			# crafted ship blocks carry their material stats onto the ship
			obj.set_block(pv, place_id, inv[active_slot].get("props", {}))
			_consume_active()


## Paint the cells a refused build got wrong, in place, for a few seconds.
func _show_build_diff(planet: Planet, wrong: Array) -> void:
	if _diff == null:
		return
	if wrong.is_empty():
		_diff.visible = false
		return
	var boxes: Array = []
	for w in wrong:
		var sv: Vector3i = w[0]
		var lo := Vector3(sv) * 0.5
		# Cells that should be EMPTY are drawn full-size so "something is in the
		# way here" reads differently from "something is missing here".
		var pad := 0.5 if str(w[1]) == "." else 0.46
		boxes.append([lo + Vector3.ONE * ((0.5 - pad) * 0.5), lo + Vector3.ONE * pad])
	_diff.mesh = _make_ghost_mesh(boxes)
	_diff.global_transform = Transform3D(planet.global_transform.basis,
		planet.global_position)
	_diff.visible = true
	_diff_t = 6.0


## The sub-cell the crosshair is on, and the one a part would go into, both in
## GLOBAL eighth coordinates (voxel * 2 + sub). Working in that space makes
## "the next eighth over" one addition whether it lands in this voxel or the
## neighbouring one -- which is what lets you build a leg upward against
## itself, not just against full blocks.
func _sub_hit(tgt: Dictionary) -> Vector3i:
	var pt: Vector3 = tgt.get("point", Vector3.ZERO)
	var n: Vector3i = tgt.get("normal", Vector3i.ZERO)
	var inside := pt - Vector3(n) * 0.002   # nudge off the face, into the solid
	return Vector3i(floori(inside.x * 2.0), floori(inside.y * 2.0), floori(inside.z * 2.0))


## Split a global eighth coordinate back into its voxel and sub-cell index.
func _sub_split(sv: Vector3i) -> Array:
	var v := Vector3i(floori(sv.x / 2.0), floori(sv.y / 2.0), floori(sv.z / 2.0))
	var o := sv - v * 2
	return [v, Blocks.part_index(o.x, o.y, o.z)]


## Where a block would land and what value it would take. Both the ghost and
## the real placement go through this, so the preview cannot disagree with what
## actually gets built. Returns {} if it wouldn't place.
func _placement_plan(tgt: Dictionary, place_id: int) -> Dictionary:
	if tgt.is_empty() or not tgt.get("hit", false):
		return {}
	var obj = tgt["obj"]
	var pv: Vector3i = tgt["place"]
	if tgt.get("kind", "") != "planet":
		return {"voxel": pv, "value": place_id}
	# A slab landing on a slab fills the same cell's upper half instead of
	# opening a new cell above it.
	if Blocks.is_slab(place_id):
		var hit_v: Vector3i = tgt["voxel"]
		var combined: int = Blocks.stack_result(obj.get_id(hit_v), place_id)
		if combined != Blocks.AIR and pv != hit_v:
			var up_axis := Vector3i((obj as Planet)._axis_of(Vector3(hit_v) + Vector3(0.5, 0.5, 0.5)))
			if pv == hit_v + up_axis:
				return {"voxel": hit_v, "value": combined}
	if Blocks.is_stair(place_id):
		return {"voxel": pv, "value": Blocks.make_stair(place_id,
			Blocks.stair_state_facing(_stair_state),
			Blocks.stair_state_variant(_stair_state))}
	if fine_place and Blocks.is_partable(place_id):
		var target := _sub_hit(tgt) + (tgt.get("normal", Vector3i.ZERO) as Vector3i)
		var sp := _sub_split(target)
		var tv: Vector3i = sp[0]
		var si: int = sp[1]
		var occ: int = (obj as Planet).get_id(tv)
		if occ != Blocks.AIR and occ != Blocks.PARTS:
			return {}   # a full block already fills that cell
		if (obj as Planet).part_at(tv, si) != Blocks.AIR:
			return {}   # that eighth is taken
		return {"voxel": tv, "part": si, "value": place_id}
	if place_id == Blocks.WIRE:
		# Conduit is surface-mounted: it clings to the face you clicked, so it
		# runs across floors, up walls and along ceilings. The face it hugs is
		# the opposite of the one you placed against.
		var wn: Vector3i = tgt.get("normal", Vector3i(0, 1, 0))
		var fi := Chunk._WFACE.find(-wn)
		if fi < 0:
			fi = 3   # no usable face: lie it on the floor
		# If this cell is already wired on another face, ADD to it rather than
		# refusing: that is how a run turns from the floor onto the wall without
		# spending a second block.
		var here: int = obj.get_id(pv)
		if Blocks.bottom_of(here) == Blocks.WIRE:
			if (Blocks.wire_faces_of(here) & (1 << fi)) != 0:
				return {}   # that face already has cable on it
			return {"voxel": pv, "value": Blocks.wire_add_face(here, fi)}
		return {"voxel": pv, "value": Blocks.wire_with_faces(1 << fi)}
	if place_id == Blocks.EMBER_TORCH:
		# A placed voxel is a bare int and can't carry item properties, so the
		# brightness step is baked in here from the ore it was crafted with.
		var pr: Dictionary = inv[active_slot].get("props", {}) if active_slot < inv.size() else {}
		return {"voxel": pv, "value": Blocks.make_torch(place_id, Blocks.torch_tier_for(pr))}
	if Blocks.is_wood(place_id):
		# A log lies along the face you placed it against, the way stacking logs
		# up a wall lays them sideways rather than standing them all upright.
		var n: Vector3i = tgt.get("normal", Vector3i(0, 1, 0))
		var axis := Blocks.AXIS_Y
		if absi(n.x) >= absi(n.y) and absi(n.x) >= absi(n.z):
			axis = Blocks.AXIS_X
		elif absi(n.z) >= absi(n.y):
			axis = Blocks.AXIS_Z
		return {"voxel": pv, "value": Blocks.make_log(place_id, axis)}
	return {"voxel": pv, "value": place_id}


const _CUBE26_OFFSETS := [
	Vector3i(-1, -1, -1), Vector3i(0, -1, -1), Vector3i(1, -1, -1),
	Vector3i(-1, 0, -1), Vector3i(0, 0, -1), Vector3i(1, 0, -1),
	Vector3i(-1, 1, -1), Vector3i(0, 1, -1), Vector3i(1, 1, -1),
	Vector3i(-1, -1, 0), Vector3i(0, -1, 0), Vector3i(1, -1, 0),
	Vector3i(-1, 0, 0), Vector3i(1, 0, 0),
	Vector3i(-1, 1, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(-1, -1, 1), Vector3i(0, -1, 1), Vector3i(1, -1, 1),
	Vector3i(-1, 0, 1), Vector3i(0, 0, 1), Vector3i(1, 0, 1),
	Vector3i(-1, 1, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]

## Placing an Interface block checks whether it's now the center of a recognized
## 3x3x3 shell (Blocks.MULTIBLOCK_RECIPES) -- if so, the whole cube collapses into
## the resulting station. Planets only for now (a ship's small voxel grid rarely
## has room for a spare 3x3x3, and it complicates orientation); revisit if wanted.
## Assembling a built machine is an explicit act: you right-click its Machine
## Core once the structure is finished. Checking every pattern in four rotations
## on every block placement would be both wasteful and silent -- this way it
## costs nothing until asked, and it can say exactly what is still missing.
## Eat whatever food is in the active slot. Sits ahead of block placement in the
## right-click chain, so holding meat feeds you rather than trying to build with
## it -- food is not a placeable block, so there is nothing to shadow.
func _try_eat() -> bool:
	var active := _active_item()
	if active.is_empty():
		return false
	var id := int(active.get("id", Blocks.AIR))
	if not Blocks.is_food(id):
		return false
	if hunger >= MAX_HUNGER - 0.5:
		_toast("Not hungry")
		return true
	var gain := Blocks.food_value(id)
	hunger = minf(hunger + gain, MAX_HUNGER)
	_remove_item(id, 1)
	_toast("Ate %s  (+%d food)" % [Blocks.name_of(id), int(round(gain))])
	_update_survival_ui()
	_refresh_slots()
	return true


## Turn the crosshair into a wrench when what you are looking at could be
## commissioned, and name it beside the crosshair.
##
## With the Wrench item gone this is the ONLY thing that tells you a build is
## finished -- there is nothing in your hand to notice it for you -- so it runs
## off the same raycast the placement ghost already does.
func _update_prospect(tgt: Dictionary = {}) -> void:
	if _crosshair == null:
		return
	# Asked once per BLOCK looked at, not once per frame. Turning on the spot
	# crosses a lot of blocks, but standing still crosses none, and it is the
	# standing-still case that was paying for a raycast and a pattern search
	# sixty times a second.
	var key: Vector3i = tgt.get("voxel", Vector3i(9999, 9999, 9999)) if not tgt.is_empty() 		else Vector3i(9999, 9999, 9999)
	if key == _prospect_key and not tgt.is_empty():
		return
	_prospect_key = key
	var p := station_prospect(tgt)
	var on := not p.is_empty()
	var mark := "wrench" if on else ("fine" if fine_place else "plain")
	if mark == _prospect_name:
		return
	_prospect_name = mark
	if on:
		# The crosshair BECOMES the wrench and says nothing else. What it would
		# make is named in the confirmation, where there is room for it and where
		# it matters -- a caption stuck to the middle of the screen is just
		# something else to read past while you are looking at the world.
		_crosshair.text = "⚒"
		_crosshair.modulate = Color(1, 1, 1)
		# The wrench glyph's ink sits high in its line box -- measured 4px above
		# where "+" draws at this size -- so the label is nudged down by exactly
		# that, or the cursor jumps as it changes.
		_crosshair.position.y = WRENCH_NUDGE_Y
	else:
		_crosshair.text = "+ 1/8" if fine_place else "+"
		_crosshair.modulate = Color(1.0, 0.78, 0.30) if fine_place else Color(1, 1, 1)


## The confirmation. Nothing changes until it is answered, and it names what you
## are about to make -- there is no tool in your hand to tell you any more, and a
## pile of rock round a fire could reasonably be several things.
func _open_commission(prospect: Dictionary) -> void:
	if _commission_panel != null:
		return
	var opts: Array = prospect["options"]
	# Centred by a container that fills the screen, not by setting a position on
	# something that has not been laid out yet: a panel's size is zero until the
	# frame after it is added, so centring it by hand put it in the top-left
	# corner with half of it off the edge.
	_commission_panel = Control.new()
	_commission_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_commission_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_commission_panel.add_child(center)
	var box := PanelContainer.new()
	center.add_child(box)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	box.add_child(vb)
	var head := Label.new()
	head.text = ("Commission this build as:" if opts.size() > 1
		else "Make this a %s?" % str(opts[0]["name"]))
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 18)
	vb.add_child(head)
	for o in opts:
		var b := Button.new()
		# One option is a yes/no question, and the thing being made is already
		# named above it; several is a menu, and then each has to say which.
		b.text = "Confirm" if opts.size() == 1 else str(o["name"])
		b.custom_minimum_size = Vector2(240, 38)
		b.pressed.connect(_confirm_commission.bind(prospect, int(o["to"])))
		vb.add_child(b)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(240, 32)
	cancel.pressed.connect(_close_commission)
	vb.add_child(cancel)
	_ui_layer.add_child(_commission_panel)
	menu_open = true      # the world runs on; this body just stops taking orders
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_commission() -> void:
	if _commission_panel != null:
		_commission_panel.queue_free()
		_commission_panel = null
	menu_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _confirm_commission(prospect: Dictionary, to: int) -> void:
	var planet: Planet = prospect["planet"]
	var v: Vector3i = prospect["voxel"]
	_close_commission()
	var res: Dictionary
	if str(prospect["mode"]) == "grow":
		res = world.grow(planet, v, to)
	else:
		res = world.assemble(planet, v, bool(prospect.get("parts", true)))
	if res.get("ok", false):
		_toast("%s commissioned" % res.get("name", "Station"))
		var st := planet.machine_station_at(v)
		if st != null:
			_open_station(st)
	else:
		_toast(str(res.get("reason", "Cannot commission that")))


## What right-clicking the block you are looking at would COMMISSION, if
## anything: a finished pattern waiting to be brought to life, or a station with
## enough material packed around it to become something bigger.
##
## Cheap enough to run whenever the target changes, which is what lets the
## crosshair turn into a wrench the moment you look at one -- there is no tool to
## carry any more, so the cursor is the only thing that can tell you.
func station_prospect(tgt: Dictionary = {}) -> Dictionary:
	if tgt.is_empty():
		tgt = _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false) or tgt.get("kind", "") != "planet":
		return {}
	var planet := tgt["obj"] as Planet
	var v: Vector3i = tgt["voxel"]
	var anchor = planet.machine_anchor_at(v)
	if anchor != null:
		var opts: Array = planet.station_growth_options(anchor)
		if not opts.is_empty():
			return {"mode": "grow", "planet": planet, "voxel": anchor, "options": opts}
		return {}
	# Nothing but a cell of EIGHTHS can be a pattern, so anything else is
	# answered by one comparison. This is the whole cost of the check on the
	# terrain you actually spend your time looking at: without it, every frame
	# ran the full matcher -- four patterns by four rotations by every offset --
	# against whatever rock happened to be under the crosshair.
	if int(tgt.get("id", Blocks.AIR)) & Blocks.ID_MASK != Blocks.PARTS:
		return {}
	var dry := planet.assemble_parts(v, -1, true)
	if dry.get("ok", false):
		return {"mode": "build", "planet": planet, "voxel": v, "parts": true,
			"options": [{"to": int(dry["result"]), "name": str(dry["name"])}]}
	return {}


## Right-click on something commissionable. Opens a station you already have,
## or puts up the confirmation naming what you are about to make.
func _try_assemble_machine() -> bool:
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false) or tgt.get("kind", "") != "planet":
		return false
	var planet := tgt["obj"] as Planet
	var v: Vector3i = tgt["voxel"]
	var is_core := int(tgt.get("id", Blocks.AIR)) == Blocks.MACHINE_CORE
	var existing := planet.machine_station_at(v)
	# ANY block of a working machine opens it: the structure is the machine, so
	# clicking its wall should do what clicking the core does. While it is
	# damaged only the core opens -- the other blocks go back to being blocks so
	# you can right-click to put the missing one back.
	#
	# Growing it comes FIRST, though: once there is rock banked around your fire,
	# right-clicking it means "make this a smelter", and you can still open the
	# fire from the confirmation or by cancelling it.
	var prospect := station_prospect()
	if not prospect.is_empty():
		_open_commission(prospect)
		return true
	if existing != null and (is_core or planet.machine_online_at(v)):
		if not planet.machine_online_at(v):
			_toast("%s is damaged -- replace the missing block" % existing.title())
		_open_station(existing)
		return true
	return false

func _place_station(id: int) -> void:
	if world == null:
		return
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		return
	var obj = tgt["obj"]
	var pv: Vector3i = tgt["place"]
	if tgt["kind"] == "planet":
		var corner: Vector3 = obj.to_global(Vector3(pv))
		if corner.distance_to(global_position) < 1.1:
			return  # don't place inside yourself
		if id == Blocks.CHEST and _chest_cluster_size_at(world, Vector3i(corner.round())) > MAX_CHEST_GROUP:
			_toast("Chest cluster is full (max %d)" % MAX_CHEST_GROUP)
			return
		var g := world.gravity_at(corner)
		var up := (-g).normalized() if g.length() > 0.01 else Vector3.UP
		world.spawn_station(id, corner, up, -global_transform.basis.z)
		_consume_active()
		_toast(Blocks.name_of(id) + " placed")
	elif tgt["kind"] == "ship":
		if id == Blocks.CHEST and _chest_cluster_size_at(obj, pv) > MAX_CHEST_GROUP:
			_toast("Chest cluster is full (max %d)" % MAX_CHEST_GROUP)
			return
		world.spawn_station_on_ship(id, obj, pv)
		_consume_active()
		_toast(Blocks.name_of(id) + " mounted on ship")
	else:
		_toast("Aim at the ground or a ship")


# Hold left-click to break the targeted block; harder blocks take longer. Broken
# blocks are added to the inventory. Also sets `_look_name` for the HUD.
func _process_mining(delta: float) -> void:
	_look_name = ""
	if _attack_cd > 0.0:
		_attack_cd -= delta
	if _ranged_cd > 0.0:
		_ranged_cd -= delta
	var lmb_down := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var lmb_pressed := lmb_down and not _lmb_was_down
	var lmb_released := not lmb_down and _lmb_was_down
	_lmb_was_down = lmb_down
	# A ranged weapon fires wherever you're looking, not just when a creature is
	# under the crosshair (like a real gun) -- so it's dispatched before the
	# raycast-target branches below, and consumes the click either way.
	if _process_ranged_fire(lmb_pressed):
		_update_outline({})
		return
	var tgt := _raycast_voxel()
	_update_outline(tgt)
	if tgt.get("kind", "") == "station":
		_process_station_mining(delta, tgt["obj"])
		return
	if tgt.get("kind", "") == "creature":
		_process_attack(tgt["obj"], delta, lmb_down, lmb_pressed, lmb_released)
		return
	if tgt.is_empty() or not tgt.get("hit", false):
		_mine_key = ""
		_mine_time = 0.0
		return

	var kind: String = tgt["kind"]
	var obj = tgt["obj"]
	var v: Vector3i = tgt["voxel"]
	var id: int = tgt["id"]
	var planet: Planet = obj if kind == "planet" else null
	var ship: Ship = obj if kind == "ship" else null
	var key := "%s%d:%d,%d,%d" % [kind, obj.get_instance_id(), v.x, v.y, v.z]

	# Ore is a procedural, unidentified material until refined; everything else
	# shows its name + use.
	var is_ore := planet != null and Blocks.is_ore(id)
	var od: Dictionary = planet.ore_def(id) if is_ore else {}
	if is_ore:
		_look_name = od.get("name", "Ore") + " Ore  (unidentified)"
	else:
		var use := Blocks.use_of(id)
		# Named by the planet, so a retinted leaf reports the colour it IS.
		var nm := planet.name_of(id) if planet != null else Blocks.name_of(id)
		_look_name = nm + ("  (" + use + ")" if use != "" else "")
	# Every block of an assembled machine reports the MACHINE, so a hand-built
	# structure reads as one object instead of the bricks it is made of. Only
	# while it is intact -- damage it and the blocks go back to being blocks,
	# which is also how you spot that it has stopped working.
	if planet != null:
		var mach := planet.machine_name_at(v)
		if mach != "":
			_look_name = mach + "  (right-click to open)"

	# High-tier ore is too hard for weak tools -- that gate is itself the tier hint.
	var hardness := Blocks.hardness(id)
	if is_ore:
		hardness = planet.ore_hardness(id)
		if mine_power < planet.ore_min_power(id):
			_look_name = od.get("name", "Ore") + " Ore  — too hard, needs a stronger drill"
			_mine_key = ""
			_mine_time = 0.0
			return

	var holding := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not holding:
		_mine_key = ""
		_mine_time = 0.0
		if _crack != null:
			_crack.visible = false
		return
	if key != _mine_key:
		_mine_key = key
		_mine_time = 0.0
		# Foliage is torn away, not mined: the bare-hand penalty exists to make
		# you want a drill for stone, and applying it to leaves just makes
		# clearing a canopy a chore.
		var bare := 1.0 if Blocks.is_leaf(Blocks.bottom_of(id)) else BARE_MINE_MULT
		_mine_total = hardness * bare / mine_power
	_mine_time += delta
	_update_crack(obj, v, id, _mine_time / maxf(_mine_total, 0.001))
	if _mine_time >= _mine_total:
		if planet != null and Blocks.bottom_of(id) == Blocks.PARTS:
			# One eighth at a time: the cell only turns back to air when the
			# last part in it is gone.
			var sp := _sub_split(_sub_hit(tgt))
			var pid := planet.part_at(sp[0], int(sp[1]))
			if pid != Blocks.AIR:
				world.edit_part(planet, sp[0], int(sp[1]), Blocks.AIR)
				_add_eighth(pid)
			_mine_key = ""
			_mine_time = 0.0
			if _crack != null:
				_crack.visible = false
			return
		if planet != null:
			world.edit_block(planet, v, Blocks.AIR)
			planet.flow_water(v)  # let adjacent water pour into the gap
			if is_ore:
				_add_item(id, 1, od["props"], planet.planet_name,
					{"name": od["name"], "color": od["color"], "tier": od["tier"]})
			elif Blocks.is_stacked_slab(id):
				# Two slabs share this voxel. Hand back BOTH of them: the packed
				# value is a storage detail, and putting it in the inventory
				# produced an item named "A + B" that could never be placed.
				_add_item(Blocks.bottom_of(id), 1)
				_add_item(Blocks.top_slab_of(id), 1)
			elif Blocks.bottom_of(id) == Blocks.WIRE:
				# One cell can carry a run on several faces; hand back one length
				# of cable per face, not one for the lot.
				var runs := 0
				var fm := Blocks.wire_faces_of(id)
				for f in 6:
					if (fm & (1 << f)) != 0:
						runs += 1
				_add_item(Blocks.WIRE, maxi(runs, 1))
			else:
				# Strip any packed orientation before it becomes an item: a
				# rotated stair or an axis-aligned log would otherwise come back
				# as a packed value that can't be placed again.
				_add_item(Blocks.bottom_of(id), 1)
		elif ship != null:
			ship.set_block(v, Blocks.AIR)
			_add_item(Blocks.bottom_of(id), 1)
		_break_burst(obj.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)),
			Blocks.color_of(id))
		if _crack != null:
			_crack.visible = false
		_refresh_slots()
		_mine_key = ""
		_mine_time = 0.0


# Hold left-click on a placed station/chest to pick it up (and its contents).
func _process_station_mining(delta: float, st: Station) -> void:
	if not is_instance_valid(st):
		_mine_key = ""
		_mine_time = 0.0
		return
	_look_name = st.title() + "  (hold to pick up)"
	var holding := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not holding:
		_mine_key = ""
		_mine_time = 0.0
		if _crack != null:
			_crack.visible = false
		return
	var key := "st%d" % st.get_instance_id()
	if key != _mine_key:
		_mine_key = key
		_mine_time = 0.0
		_mine_total = 0.6
	_mine_time += delta
	if _mine_time >= _mine_total:
		_pick_up_station(st)
		_mine_key = ""
		_mine_time = 0.0


## Currently active hotbar slot, or {} if empty/out of range.
func _active_item() -> Dictionary:
	return inv[active_slot] if active_slot >= 0 and active_slot < inv.size() else {}


## True once a held heavy melee swing has actually crossed the charge
## threshold -- i.e. "this will land as a heavy hit if released right now."
## A real, already-visible tell (the player is visibly holding the swing),
## which is what lets an enemy's block reaction feel earned rather than
## psychic. Read by Creature via world.player (duck-typed, like take_damage).
func is_heavy_telegraphed() -> bool:
	var shape: Dictionary = Blocks.WEAPON_SHAPES.get(Blocks.WEAPON, {})
	return _charging and _charge_t >= float(shape.get("heavy_charge", 0.5))


## Melee combat: tap for a fast light hit, or hold past the weapon's heavy-
## charge threshold and release for a slower, harder, stagger-heavy hit. Bare
## hands work (UNARMED_DAMAGE, using the Weapon shape's timing/range); a
## crafted Weapon hits harder via _melee_damage (see _update_mine_power).
func _process_attack(creature: Creature, delta: float, lmb_down: bool, lmb_pressed: bool, lmb_released: bool) -> void:
	var shape: Dictionary = Blocks.WEAPON_SHAPES.get(Blocks.WEAPON, {})
	if not is_instance_valid(creature):
		_charging = false
		return
	var dist := global_position.distance_to(creature.global_position)
	var cname: String = creature.species.get("name", "Creature")
	var rng: float = float(shape.get("range", MELEE_RANGE))
	if dist > rng:
		_look_name = cname + "  (too far to hit)"
		_charging = false
		return
	if lmb_pressed and _attack_cd <= 0.0:
		_charging = true
		_charge_t = 0.0
	if _charging and lmb_down:
		_charge_t += delta
	var heavy_charge: float = float(shape.get("heavy_charge", 0.5))
	if lmb_released and _charging:
		_charging = false
		if _attack_cd <= 0.0:
			var heavy := _charge_t >= heavy_charge
			var mult: float = float(shape.get("heavy_mult", 1.0)) if heavy else 1.0
			var stagger: float = float(shape.get("heavy_stagger" if heavy else "light_stagger", 0.0))
			_attack_cd = float(shape.get("light_cooldown", MELEE_COOLDOWN))
			_swing_t = 0.0
			var died := creature.take_hit(_melee_damage * mult, stagger)
			if died:
				_toast("Killed " + cname)
	if _attack_cd > 0.0:
		_look_name = "%s  (recovering)" % cname
	elif _charging:
		_look_name = "%s  (%.0f dmg, %s)" % [cname,
			_melee_damage * (float(shape.get("heavy_mult", 1.0)) if _charge_t >= heavy_charge else 1.0),
			"HEAVY ready, release!" if _charge_t >= heavy_charge else "charging..."]
	else:
		_look_name = "%s  (%.0f dmg, click for light / hold+release for heavy)" % [cname, _melee_damage]


## Ranged combat: fires along the camera's forward ray regardless of what's
## under the crosshair -- returns true if the active item is a ranged weapon
## at all (so the caller skips block/creature targeting for this frame),
## whether or not a shot was actually fired this frame (still on cooldown,
## slot empty, etc).
func _process_ranged_fire(lmb_pressed: bool) -> bool:
	var active := _active_item()
	var id: int = int(active.get("id", -1))
	if int(active.get("count", 0)) <= 0:
		return false
	var shape: Dictionary = Blocks.WEAPON_SHAPES.get(id, {})
	if shape.get("category", "") != "ranged":
		return false
	var dmg: float = float(active.get("mat", {}).get("damage", 5.0))
	if _ranged_cd > 0.0:
		_look_name = "%s  (recharging)" % Blocks.name_of(id)
	else:
		_look_name = "%s  (%.0f dmg, click to fire)" % [Blocks.name_of(id), dmg]
	if lmb_pressed and _ranged_cd <= 0.0:
		_fire_ranged_weapon(shape, dmg)
		_ranged_cd = float(shape.get("cooldown", 0.4))
		_swing_t = 0.0  # reuses the same recoil-ish hand-flick as melee
	return true


## Spawns a traveling Projectile along the camera's forward ray. Kept separate
## from hitscan on purpose -- a launcher/rifle later can add a "hitscan" shape
## branch here without touching this path.
func _fire_ranged_weapon(shape: Dictionary, dmg: float) -> void:
	var proj := Projectile.new()
	world.add_child(proj)
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	proj.launch(from, dir, float(shape.get("projectile_speed", 40.0)), dmg,
		float(shape.get("stagger", 0.0)), float(shape.get("range", 30.0)))


## Everything the hand in the corner of the screen does: it bobs when you walk,
## chops on a loop while you are mining, and flicks once when you swing or place.
##
## In first person the hand is the ONLY part of yourself you can see, so it is
## carrying the whole job of making an action feel like it happened -- hence a
## continuous motion for the continuous action (mining) rather than one flick at
## the moment the block finally breaks.
func _update_swing(delta: float) -> void:
	if _hand_pivot == null:
		return

	# --- walk bob ---------------------------------------------------------
	# Driven by actual speed rather than by the input keys, so it stops when you
	# walk into a wall and slows when you are wading or starving.
	var speed := velocity.length()
	var walking := speed > 0.5 and is_on_floor()
	_bob_amp = lerpf(_bob_amp, clampf(speed / WALK_SPEED, 0.0, 1.0) if walking else 0.0,
		clampf(delta * 8.0, 0.0, 1.0))
	# Phase advances with speed so steps land with the ground, not with the clock.
	_bob_phase += delta * (3.0 + speed * 0.9)
	# Twice the vertical frequency of the horizontal sway: one rise and fall per
	# footfall, one side-to-side per full stride. That two-to-one is what makes a
	# bob read as walking instead of as a floating hand.
	var bob := Vector3(cos(_bob_phase) * 0.020, -absf(sin(_bob_phase)) * 0.024, 0.0) * _bob_amp
	var bob_rot := Vector3(0.0, 0.0, cos(_bob_phase) * 0.05) * _bob_amp

	# --- mining loop ------------------------------------------------------
	# While a block is being chipped away, swing on repeat. _mine_time counts up
	# for as long as the button is held on the same block, and resets the moment
	# you let go or look away, so the loop stops on its own.
	var chop := 0.0
	if _mine_time > 0.0 and _swing_t >= SWING_DURATION:
		chop = maxf(sin(_mine_time * 9.0), 0.0)

	# --- one-shot swing ---------------------------------------------------
	var s := 0.0
	if _swing_t < SWING_DURATION:
		_swing_t += delta
		s = sin(clampf(_swing_t / SWING_DURATION, 0.0, 1.0) * PI)

	var arc := maxf(s, chop * 0.75)
	_hand_pivot.position = HAND_IDLE_POS + bob
	_hand_pivot.rotation = HAND_IDLE_ROT + bob_rot + Vector3(-1.1, 0.5, -0.4) * arc


func _pick_up_station(st: Station) -> void:
	_add_item(st.kind, 1)
	# return whatever was inside to your inventory
	for s in st.storage:
		if s["count"] > 0:
			_add_item(s["id"], s["count"], s.get("props", {}), s.get("src", ""), s.get("mat", {}))
	if world != null:
		world._stations.erase(st)
	st.queue_free()
	_refresh_slots()
	_toast("Picked up " + Blocks.name_of(st.kind))


## Start a new ship where the player is looking, oriented to their current frame.
func _start_ship() -> void:
	if world == null:
		return
	_ray.force_raycast_update()
	var up := -world.gravity_at(global_position).normalized()
	if up.length() < 0.1:
		up = global_transform.basis.y
	var fwd := -_camera.global_transform.basis.z
	var pos: Vector3
	if _ray.is_colliding():
		pos = _ray.get_collision_point() + _ray.get_collision_normal() * 0.5
	else:
		pos = global_position + fwd * 4.0
	world.spawn_ship(pos, up, fwd)


# --- UI -----------------------------------------------------------------------

# --- planet navigation markers ------------------------------------------------

func _update_markers() -> void:
	if world == null or _ui_layer == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# Underground you cannot see the sky, so you cannot see what is in it. These
	# are drawn as flat HUD text with no depth test, so without this they hang in
	# front of solid rock like the planets are inside the cave with you.
	if underground:
		for m in _markers:
			m.visible = false
		return
	while _markers.size() < world.planets.size():
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 14)
		l.modulate = Color(0.55, 0.9, 1.0)
		_ui_layer.add_child(l)
		_markers.append(l)

	var vp := get_viewport().get_visible_rect().size
	var center := vp * 0.5
	var margin := 52.0
	var inv := cam.global_transform.affine_inverse()
	for i in world.planets.size():
		var planet: Planet = world.planets[i]
		var lbl: Label = _markers[i]
		var wp := planet.global_position
		var dist := wp.distance_to(cam.global_position)
		if dist < planet.radius * 1.25:
			lbl.visible = false  # you're basically there; no need for a marker
			continue
		var localp := inv * wp                # planet in camera space (-Z is forward)
		var pos: Vector2
		var offscreen := true
		if localp.z < 0.0:
			pos = cam.unproject_position(wp)
			offscreen = pos.x < margin or pos.x > vp.x - margin or pos.y < margin or pos.y > vp.y - margin
		if offscreen:
			var d2 := Vector2(localp.x, -localp.y)
			if localp.z > 0.0:
				d2 = -d2                       # behind us: flip to point the right way
			if d2.length() < 0.001:
				d2 = Vector2(0, 1)
			pos = _clamp_to_edge(center, d2.normalized(), vp, margin)
			lbl.text = ">> %s  %s" % [planet.planet_name, _fmt_dist(dist)]
		else:
			lbl.text = "%s  %s" % [planet.planet_name, _fmt_dist(dist)]
		lbl.position = pos
		lbl.visible = true


func _clamp_to_edge(center: Vector2, dir: Vector2, vp: Vector2, margin: float) -> Vector2:
	var t := INF
	if dir.x > 0.0:
		t = minf(t, (vp.x - margin - center.x) / dir.x)
	elif dir.x < 0.0:
		t = minf(t, (margin - center.x) / dir.x)
	if dir.y > 0.0:
		t = minf(t, (vp.y - margin - center.y) / dir.y)
	elif dir.y < 0.0:
		t = minf(t, (margin - center.y) / dir.y)
	return center + dir * t


func _fmt_dist(d: float) -> String:
	if d >= 1000.0:
		return "%.1f km" % (d / 1000.0)
	return "%d m" % int(d)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui_layer = layer

	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 24)
	# Spans the screen and centres its own text, rather than being a small label
	# pinned AT the centre. PRESET_CENTER anchors the top-left corner there, so
	# the label grows right and down and a longer string drags the crosshair off
	# the middle of the screen -- which is what happened the moment it had
	# anything to say besides "+".
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_crosshair)

	_hotbar_label = Label.new()
	_hotbar_label.position = Vector2(16, 16)
	layer.add_child(_hotbar_label)

	_mode_label = Label.new()
	_mode_label.position = Vector2(16, 44)
	layer.add_child(_mode_label)

	_ship_label = Label.new()
	_ship_label.position = Vector2(16, 72)
	layer.add_child(_ship_label)

	# top-right: which system you're in and how civilized it is -- the first
	# visible piece of the galaxy layer; no warp travel yet, just showing where
	# you actually are
	_system_label = Label.new()
	_system_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_system_label.position = Vector2(-260, 16)
	_system_label.custom_minimum_size = Vector2(244, 0)
	_system_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_system_label.modulate = Color(0.75, 0.85, 1.0)
	if world != null:
		var sysdef := world.current_system()
		if not sysdef.is_empty():
			_system_label.text = "%s system\n%s" % [sysdef["name"], Galaxy.civ_name(sysdef["civ_tier"])]
	layer.add_child(_system_label)

	# what you're aiming at + mining progress, just under the crosshair
	_target_label = Label.new()
	_target_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_target_label.position = Vector2(0, 360)
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	layer.add_child(_target_label)

	_build_inventory_ui(layer)
	_build_station_ui(layer)
	_build_starmap_ui(layer)
	_build_book_ui(layer)
	_apply_place_mode_ui()   # start the crosshair and ghost in the right mode

	# transient save/load confirmation, top-center
	_toast_label = Label.new()
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast_label.position = Vector2(0, 24)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_label.add_theme_font_size_override("font_size", 22)
	_toast_label.visible = false
	layer.add_child(_toast_label)

	# survival bars (top-left, below the status labels)
	_hp_fill = _make_bar(layer, 104, Color(0.85, 0.25, 0.25), "HP")
	_o2_fill = _make_bar(layer, 126, Color(0.30, 0.62, 0.95), "O2")
	_food_fill = _make_bar(layer, 148, Color(0.78, 0.55, 0.20), "FOOD")
	_build_base_panel(layer)
	_hazard_label = Label.new()
	_hazard_label.position = Vector2(16, 170)
	_hazard_label.add_theme_font_size_override("font_size", 15)
	_hazard_label.visible = false
	layer.add_child(_hazard_label)

	_update_ui()
	_update_survival_ui()


func _make_bar(layer: CanvasLayer, y: int, color: Color, label: String) -> ColorRect:
	var bg := ColorRect.new()
	bg.position = Vector2(16, y)
	bg.size = Vector2(180, 16)
	bg.color = Color(0, 0, 0, 0.5)
	layer.add_child(bg)
	var fill := ColorRect.new()
	fill.position = Vector2(2, 2)
	fill.size = Vector2(176, 12)
	fill.color = color
	bg.add_child(fill)
	var lbl := Label.new()
	lbl.position = Vector2(202, y - 3)
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.modulate = Color(1, 1, 1, 0.8)
	layer.add_child(lbl)
	return fill


## Readout for the base you are standing in. Hidden outdoors, so it costs
## nothing and never clutters the screen while you are exploring.
func _build_base_panel(layer: CanvasLayer) -> void:
	_base_panel = Panel.new()
	_base_panel.position = Vector2(16, 178)
	_base_panel.size = Vector2(238, 108)
	_base_panel.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.78)
	sb.border_color = Color(0.35, 0.62, 0.72, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	_base_panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(_base_panel)
	_base_title = Label.new()
	_base_title.position = Vector2(10, 5)
	_base_title.add_theme_font_size_override("font_size", 13)
	_base_title.modulate = Color(0.65, 0.88, 1.0)
	_base_panel.add_child(_base_title)
	var rows := [["Power", Color(0.95, 0.80, 0.30)], ["Oxygen", Color(0.30, 0.62, 0.95)],
		["Temp", Color(0.90, 0.45, 0.30)]]
	for i in rows.size():
		var y := 28 + i * 26
		var name_lbl := Label.new()
		name_lbl.position = Vector2(10, y - 3)
		name_lbl.text = str(rows[i][0])
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.modulate = Color(1, 1, 1, 0.75)
		_base_panel.add_child(name_lbl)
		var bg := ColorRect.new()
		bg.position = Vector2(62, y)
		bg.size = Vector2(112, 14)
		bg.color = Color(0, 0, 0, 0.55)
		_base_panel.add_child(bg)
		var fill := ColorRect.new()
		fill.position = Vector2(1, 1)
		fill.size = Vector2(110, 12)
		fill.color = rows[i][1]
		bg.add_child(fill)
		_base_fills.append(fill)
		var val := Label.new()
		val.position = Vector2(180, y - 3)
		val.add_theme_font_size_override("font_size", 12)
		_base_panel.add_child(val)
		_base_values.append(val)


func _update_base_panel() -> void:
	if _base_panel == null:
		return
	if base_status.is_empty():
		_base_panel.visible = false
		return
	_base_panel.visible = true
	var pw: float = float(base_status.get("power", 0.0))
	var pmax: float = float(base_status.get("power_max", 0.0))
	var o2: float = float(base_status.get("o2", 0.0))
	var tp: float = float(base_status.get("temp", 15.0))
	_base_title.text = "BASE  ·  %d cells" % int(base_status.get("cells", 0))
	var pf: float = (pw / pmax) if pmax > 0.0 else 0.0
	_base_fills[0].size.x = 110.0 * clampf(pf, 0.0, 1.0)
	_base_values[0].text = "%d%%" % int(pf * 100.0) if pmax > 0.0 else "none"
	_base_values[0].modulate = Color(1, 1, 1, 0.85) if pmax > 0.0 else Color(1.0, 0.5, 0.4)
	_base_fills[1].size.x = 110.0 * clampf(o2, 0.0, 1.0)
	_base_values[1].text = "%d%%" % int(o2 * 100.0) if bool(base_status.get("ls", false)) else "none"
	_base_values[1].modulate = Color(1, 1, 1, 0.85) if base_breathable() else Color(1.0, 0.5, 0.4)
	# Temperature is a RANGE, not a fill from zero: -50..70 C mapped across the bar.
	_base_fills[2].size.x = 110.0 * clampf((tp + 50.0) / 120.0, 0.0, 1.0)
	_base_fills[2].color = Color(0.45, 0.72, 1.0) if tp < 5.0 else (
		Color(0.95, 0.45, 0.25) if tp > 40.0 else Color(0.45, 0.85, 0.45))
	_base_values[2].text = "%d C" % int(round(tp))
	_base_values[2].modulate = Color(1, 1, 1, 0.85) if base_safe_temp() else Color(1.0, 0.5, 0.4)


func _update_survival_ui() -> void:
	_update_base_panel()
	if _hp_fill != null:
		_hp_fill.size.x = 176.0 * clampf(health / MAX_HEALTH, 0.0, 1.0)
		_hp_fill.color = Color(0.85, 0.25, 0.25) if health > MAX_HEALTH * 0.3 else Color(1.0, 0.35, 0.2)
	if _o2_fill != null:
		_o2_fill.size.x = 176.0 * clampf(oxygen / _max_oxygen(), 0.0, 1.0)
	if _food_fill != null:
		_food_fill.size.x = 176.0 * clampf(hunger / MAX_HUNGER, 0.0, 1.0)
		_food_fill.color = Color(0.78, 0.55, 0.20) if hunger > HUNGER_REGEN_MIN 			else Color(0.95, 0.35, 0.2)
	if _hazard_label != null:
		var hz := _current_hazard()
		var suit := "  (suit -%d%%)" % int(_hazard_resist * 100.0) if _hazard_resist > 0.0 else ""
		if hz == "cold":
			_hazard_label.text = "FREEZING — reach shelter" + suit
			_hazard_label.modulate = Color(0.6, 0.85, 1.0)
			_hazard_label.visible = true
		elif hz == "heat":
			_hazard_label.text = "OVERHEATING — reach shelter" + suit
			_hazard_label.modulate = Color(1.0, 0.6, 0.35)
			_hazard_label.visible = true
		else:
			_hazard_label.visible = false


func _toast(msg: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = msg
	_toast_label.visible = true
	_toast_time = 2.0


# Build the always-visible hotbar strip and the toggleable full-inventory grid.
func _build_inventory_ui(layer: CanvasLayer) -> void:
	# hotbar strip, bottom-center
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	hb.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hb.position = Vector2(-8 * 32, -76)
	layer.add_child(hb)
	for i in HOTBAR_SLOTS:
		_hotbar_cells.append(_make_slot(hb, i, "none"))

	# full inventory overlay (E): inventory grid, a 2-tall Suit equip slot, and a
	# scrollable "Craft" list (scrolls instead of growing as recipes are added)
	# One source of truth for cell metrics: the tall-item renderer needs the
	# exact row pitch, and a hardcoded copy would silently misalign the moment
	# spacing changed.
	var grid_w := HOTBAR_SLOTS * INV_CELL_STEP
	var grid_h := 4 * INV_CELL_STEP
	# Suit sits on the LEFT, ahead of the grid: it's worn gear, so it reads as
	# part of "you" rather than as an afterthought tacked on past the bag.
	var equip_w := 64
	var equip_x := 12
	var grid_x := equip_x + equip_w + 16
	_inv_panel = Panel.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	# Just the bag and what you are wearing. The crafting column that used to sit
	# to the right of this is gone: everything is made at a bench now, so a list
	# of what you can make from your pockets would be an empty list.
	_inv_panel.custom_minimum_size = Vector2(grid_x + grid_w + 12, 44 + grid_h + 24)
	_inv_panel.size = _inv_panel.custom_minimum_size
	_inv_panel.position = -_inv_panel.size * 0.5
	_inv_panel.visible = false
	layer.add_child(_inv_panel)
	var title := Label.new()
	title.text = "Inventory  (drag to rearrange)"
	title.position = Vector2(grid_x + 2, 8)
	_inv_panel.add_child(title)
	var grid := GridContainer.new()
	grid.columns = HOTBAR_SLOTS
	grid.add_theme_constant_override("h_separation", INV_CELL_GAP)
	grid.add_theme_constant_override("v_separation", INV_CELL_GAP)
	grid.position = Vector2(grid_x, 44)
	_inv_panel.add_child(grid)
	for i in SLOTS:
		_grid_cells.append(_make_slot(grid, i, "select"))

	# equip slot: a Suit only protects you once dragged here -- carrying one loose
	# in the grid above does nothing (unlike the Drill)
	var equip_label := Label.new()
	equip_label.text = "Suit"
	equip_label.modulate = Color(1, 1, 1, 0.7)
	equip_label.position = Vector2(equip_x, 8)
	_inv_panel.add_child(equip_label)
	_equip_cell = _make_equip_slot(_inv_panel, Vector2(equip_x, 44))


# One slot cell: colored square + count. `mode`: "none" = display only,
# "select" = click picks the active slot, "inv"/"stor" = drag source & drop target
# (inventory slot / station-storage slot). Items are moved by dragging.
func _make_slot(parent: Node, index: int, mode: String) -> Dictionary:
	var root: Control
	if mode == "select":
		var b := Button.new()
		b.pressed.connect(_on_slot_pressed.bind(index))
		root = b
	else:
		root = Panel.new()
	root.custom_minimum_size = Vector2(INV_CELL, INV_CELL)
	parent.add_child(root)
	var swatch := ColorRect.new()
	swatch.set_anchors_preset(Control.PRESET_FULL_RECT)
	swatch.offset_left = 6; swatch.offset_top = 6
	swatch.offset_right = -6; swatch.offset_bottom = -6
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(swatch)
	var count := Label.new()
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -30; count.offset_top = -22
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(count)
	# drag & drop: "select"/"to_station" cells map to inventory slots, "from_station"
	# to the open station's storage
	var dcont := ""
	if mode == "select" or mode == "to_station":
		dcont = "inv"
	elif mode == "from_station":
		dcont = "stor"
	if dcont != "":
		root.set_drag_forwarding(
			_slot_get_drag.bind(dcont, index, root),
			_slot_can_drop.bind(dcont, index),
			_slot_do_drop.bind(dcont, index))
	return {"root": root, "swatch": swatch, "count": count}


# A single equip slot that's visually two grid cells tall, holding one Suit at a
# time (the item fills the whole slot, not spread across two separate cells).
func _make_equip_slot(parent: Node, pos: Vector2) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(56, 116)  # 2x56 + gap
	root.position = pos
	parent.add_child(root)
	var swatch := ColorRect.new()
	swatch.set_anchors_preset(Control.PRESET_FULL_RECT)
	swatch.offset_left = 6; swatch.offset_top = 6
	swatch.offset_right = -6; swatch.offset_bottom = -6
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(swatch)
	var count := Label.new()
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -30; count.offset_top = -22
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(count)
	root.set_drag_forwarding(
		_slot_get_drag.bind("equip", 0, root),
		_slot_can_drop.bind("equip", 0),
		_slot_do_drop.bind("equip", 0))
	return {"root": root, "swatch": swatch, "count": count}


func _on_slot_pressed(index: int) -> void:
	active_slot = index
	_refresh_slots()


# --- drag & drop --------------------------------------------------------------

func _slot_ref(cont: String, index: int) -> Dictionary:
	if cont == "inv":
		return inv[index]
	if cont == "equip":
		return suit_slot
	if cont == "stor" and index >= 0 and index < _stor_map.size():
		var m: Dictionary = _stor_map[index]
		var st: Station = m["st"]
		if is_instance_valid(st) and int(m["slot"]) < st.storage.size():
			return st.storage[int(m["slot"])]
	return {}


func _slot_get_drag(_at: Vector2, cont: String, index: int, root: Control) -> Variant:
	var slot := _slot_ref(cont, index)
	if slot.is_empty() or int(slot["count"]) <= 0:
		return null
	var pv := ColorRect.new()
	pv.size = Vector2(44, 44)
	pv.position = Vector2(-22, -22)
	var mat: Dictionary = slot.get("mat", {})
	pv.color = mat["color"] if mat.has("color") else Blocks.color_of(slot["id"])
	var wrap := Control.new()
	wrap.add_child(pv)
	root.set_drag_preview(wrap)
	return {"cont": cont, "index": index}


func _slot_can_drop(_at: Vector2, data: Variant, _cont: String, _index: int) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.has("cont")


func _slot_do_drop(_at: Vector2, data: Variant, cont: String, index: int) -> void:
	_transfer(data["cont"], int(data["index"]), cont, index)


func _clear_slot(s: Dictionary) -> void:
	s["id"] = Blocks.AIR
	s["count"] = 0
	s["props"] = {}
	s["src"] = ""
	s["mat"] = {}


func _copy_slot(src: Dictionary, dst: Dictionary) -> void:
	dst["id"] = src["id"]
	dst["count"] = src["count"]
	dst["props"] = src.get("props", {})
	dst["src"] = src.get("src", "")
	dst["mat"] = src.get("mat", {})


func _transfer(fc: String, fi: int, tc: String, ti: int) -> void:
	# Clicking the lower half of a two-cell item means the item itself.
	if fc == "inv" and _cover_owner(fi) >= 0:
		fi = _cover_owner(fi)
	if tc == "inv" and _cover_owner(ti) >= 0:
		ti = _cover_owner(ti)
	if fc == tc and fi == ti:
		return
	var from := _slot_ref(fc, fi)
	var to := _slot_ref(tc, ti)
	if from.is_empty() or to.is_empty() or int(from["count"]) <= 0:
		return
	# dropping INTO a machine's storage must match what it accepts (chests and the
	# Carpenter's Bench take any plain resource; the rest are picky by design so
	# each station's recipes read as one cohesive idea)
	if tc == "stor" and fc != "stor" and ti < _stor_map.size():
		var tst: Station = _stor_map[ti]["st"]
		var fid: int = from["id"]
		if Blocks.is_smelter_kind(tst.kind) and not (Blocks.is_ore(fid) or Blocks.is_refined(fid) or fid == Blocks.METAL):
			_toast("Smelter takes raw ore, refined material, or Metal")
			return
		if tst.kind == Blocks.FABRICATOR and fid != Blocks.CIRCUIT:
			_toast("Fabricator takes Circuitry")
			return
		if tst.kind == Blocks.SHIPWORKS and fid != Blocks.ALLOY:
			_toast("Shipworks takes Alloy Plating")
			return
	# the equip slot only ever holds a Suit -- that's what makes it worn, not just carried
	if tc == "equip" and from["id"] != Blocks.SUIT:
		_toast("Only a Suit fits there")
		return
	# A two-cell item needs the space beneath its destination, and swapping it
	# with something else has no sensible footprint, so both are refused rather
	# than silently doing something surprising.
	var from_tall: bool = Blocks.item_cells_tall(int(from["id"])) > 1
	if from_tall and tc == "inv":
		if not _can_place_tall(ti, fi if fc == "inv" else -1):
			_toast("%s needs two free slots, one above the other" % Blocks.name_of(int(from["id"])))
			return
		if int(to["count"]) > 0 and int(to["id"]) != int(from["id"]):
			_toast("Move that item out first")
			return
	if to["count"] > 0 and to["id"] == from["id"] and to.get("src", "") == from.get("src", ""):
		var cap: int = STACK_MAX if tc == "inv" else (1 if tc == "equip" else 100000)
		var mv: int = mini(cap - to["count"], from["count"])
		to["count"] += mv
		from["count"] -= mv
		if from["count"] <= 0:
			_clear_slot(from)
	elif to["count"] == 0:
		_copy_slot(from, to)
		_clear_slot(from)
	else:
		var tmp := {"id": to["id"], "count": to["count"], "props": to.get("props", {}),
			"src": to.get("src", ""), "mat": to.get("mat", {})}
		_copy_slot(from, to)
		from["id"] = tmp["id"]
		from["count"] = tmp["count"]
		from["props"] = tmp["props"]
		from["src"] = tmp["src"]
		from["mat"] = tmp["mat"]
	# Footprints can change on either end of a move, so re-derive both.
	if fc == "inv":
		_sync_cover(fi)
	if tc == "inv":
		_sync_cover(ti)
	_refresh_slots()
	_refresh_station_ui()


func _refresh_slots() -> void:
	active_slot = clampi(active_slot, 0, SLOTS - 1)
	for i in _hotbar_cells.size():
		_paint_cell(_hotbar_cells[i], inv[i], i == active_slot)
	for i in _grid_cells.size():
		var cell: Dictionary = _grid_cells[i]
		var sw: ColorRect = cell["swatch"]
		if _cover_owner(i) >= 0:
			# Lower half of a two-cell item: the owner's swatch already covers
			# this ground, so drawing anything here would double up.
			_paint_cell(cell, {"id": Blocks.AIR, "count": 0}, false)
			sw.offset_bottom = -6.0
			continue
		_paint_cell(cell, inv[i], i == active_slot)
		# A tall item is drawn as ONE swatch spilling into the cell beneath,
		# which is what makes it read as a single bulky object rather than two
		# copies stacked up.
		var tall := int(inv[i].get("count", 0)) > 0 			and Blocks.item_cells_tall(int(inv[i]["id"])) > 1
		sw.offset_bottom = (-6.0 + float(INV_CELL_STEP)) if tall else -6.0
	if not _equip_cell.is_empty():
		_paint_cell(_equip_cell, suit_slot, false)
	_update_mine_power()


# Your effective mining power is the best drill you carry (bare hands = 1.0). This
# sets mining speed and which ore tiers you can break. Also scans for
# gear -- the best you carry applies automatically. The Suit is different: it
# only protects you while actually worn in `suit_slot` (see that var's comment).
func _update_mine_power() -> void:
	var best := 1.0
	for s in inv:
		if s["count"] <= 0:
			continue
		var mat: Dictionary = s.get("mat", {})
		match s["id"]:
			Blocks.DRILL:
				best = maxf(best, float(mat.get("power", 1.0)))
	mine_power = best
	var resist := 0.0
	if suit_slot.get("id", Blocks.AIR) == Blocks.SUIT and int(suit_slot.get("count", 0)) > 0:
		resist = float(suit_slot.get("mat", {}).get("resist", 0.0))
	_hazard_resist = clampf(resist, 0.0, 0.9)

	# A melee weapon only does anything if it's the slot you're actively holding --
	# unlike worn gear (drill/tank/suit), carrying one in the pack isn't enough.
	var active: Dictionary = inv[active_slot] if active_slot >= 0 and active_slot < inv.size() else {}
	if active.get("id", -1) == Blocks.WEAPON and int(active.get("count", 0)) > 0:
		_melee_damage = float(active.get("mat", {}).get("damage", UNARMED_DAMAGE))
	else:
		_melee_damage = UNARMED_DAMAGE
	_update_held_item(active)


# --- held item view-model ------------------------------------------------------

func _update_held_item(active: Dictionary) -> void:
	var id: int = int(active.get("id", Blocks.AIR)) if not active.is_empty() else Blocks.AIR
	var mat: Dictionary = active.get("mat", {}) if not active.is_empty() else {}
	var count: int = int(active.get("count", 0)) if not active.is_empty() else 0
	var key := "%d:%s" % [id, mat.get("name", "")]
	if count <= 0:
		id = Blocks.AIR
		key = "air"
	if key == _held_key:
		return
	_held_key = key
	if _held_root != null:
		_held_root.queue_free()
		_held_root = null
	if id == Blocks.AIR or _hand_pivot == null:
		return
	_held_root = Node3D.new()
	_hand_pivot.add_child(_held_root)
	if id == Blocks.WEAPON:
		_build_held_weapon(mat.get("color", Color(0.8, 0.8, 0.85)))
	elif id == Blocks.PULSE_PISTOL:
		_build_held_pistol(mat.get("color", Color(0.3, 0.75, 0.85)))
	elif id == Blocks.DRILL:
		_build_held_drill(mat.get("color", Color(0.7, 0.7, 0.75)))
	elif Blocks.is_placeable_block(id) or Blocks.is_ore(id) or Blocks.is_refined(id) or Blocks.is_intermediate(id):
		_build_held_block(mat.get("color", Blocks.color_of(id)))
	# other gear (the Suit) is worn, not wielded -- nothing shown in hand


func _mk_view_box(size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	mi.material_override = mat
	_held_root.add_child(mi)
	return mi


func _build_held_weapon(color: Color) -> void:
	_mk_view_box(Vector3(0.05, 0.22, 0.05), Vector3(0, -0.14, 0), Color(0.25, 0.22, 0.2))  # hilt
	_mk_view_box(Vector3(0.16, 0.03, 0.03), Vector3(0, 0.0, 0), Color(0.35, 0.32, 0.3))    # guard
	_mk_view_box(Vector3(0.05, 0.55, 0.02), Vector3(0, 0.32, 0), color)                    # blade -- held vertical, not pointing forward


func _build_held_pistol(color: Color) -> void:
	_mk_view_box(Vector3(0.08, 0.16, 0.1), Vector3(0, -0.14, 0.02), Color(0.2, 0.2, 0.22))  # grip
	_mk_view_box(Vector3(0.1, 0.09, 0.3), Vector3(0, 0, -0.08), Color(0.28, 0.28, 0.3))     # body
	_mk_view_box(Vector3(0.05, 0.05, 0.14), Vector3(0, 0.01, -0.28), color)                  # barrel/emitter


func _build_held_drill(color: Color) -> void:
	_mk_view_box(Vector3(0.16, 0.16, 0.34), Vector3(0, 0, 0.06), Color(0.3, 0.3, 0.32))  # body
	_mk_view_box(Vector3(0.06, 0.06, 0.3), Vector3(0, 0, -0.28), color)                   # bit


func _build_held_block(color: Color) -> void:
	_mk_view_box(Vector3(0.22, 0.22, 0.22), Vector3(0, 0, -0.15), color)


func _max_oxygen() -> float:
	return MAX_OXYGEN


# Paint any slot cell from a slot dict. `highlight` toggles the active-slot glow.
func _paint_cell(cell: Dictionary, slot: Dictionary, highlight: bool) -> void:
	var swatch: ColorRect = cell["swatch"]
	var count: Label = cell["count"]
	var eighths := int(slot.get("eighths", 0)) if not slot.is_empty() else 0
	if not slot.is_empty() and (slot["count"] > 0 or eighths > 0):
		var mat: Dictionary = slot.get("mat", {})
		swatch.color = mat["color"] if mat.has("color") else Blocks.color_of(slot["id"])
		# Change shown as a real fraction rather than a second number: eighths
		# land exactly on the glyphs a font already has.
		const EIGHTH_GLYPH := ["", "⅛", "¼", "⅜", "½",
			"⅝", "¾", "⅞"]
		var whole: int = int(slot["count"])
		count.text = ("%d%s" % [whole, EIGHTH_GLYPH[eighths]]) if whole > 0 			else EIGHTH_GLYPH[eighths]
		cell["root"].tooltip_text = _item_tooltip(slot)
	else:
		swatch.color = Color(0.15, 0.15, 0.18, 0.6)
		count.text = ""
		cell["root"].tooltip_text = ""
	cell["root"].modulate = Color(1.4, 1.4, 0.7) if highlight else Color(1, 1, 1)


# Hover text. Raw ore stays unidentified (tier & stats hidden); a refined material
# shows its tier and property bars. Source planet is shown for both.
func _item_tooltip(slot: Dictionary) -> String:
	var id: int = slot["id"]
	var mat: Dictionary = slot.get("mat", {})
	var mname: String = mat.get("name", Blocks.name_of(id))
	var src: String = slot.get("src", "")
	var suffix := ("  ·  " + src) if src != "" else ""
	if id == Blocks.DRILL:
		var power := float(mat.get("power", 1.0))
		return "%s Drill%s\nMining power %.1f — breaks up to Tier %d" % [
			mname, suffix, power, Blocks.max_tier_for_power(power)]
	if id == Blocks.SUIT:
		return "%s Insulated Suit%s\nHazard resist %d%%" % [
			mname, suffix, int(round(float(mat.get("resist", 0.0)) * 100.0))]
	if Blocks.is_ore(id):
		return "%s Ore%s\nUnidentified — refine to reveal its tier & stats" % [mname, suffix]
	if Blocks.is_refined(id):
		var tier: int = int(mat.get("tier", 0))
		var props: Dictionary = slot.get("props", {})
		var lines := ["Refined %s%s  (%s · Tier %d)" % [mname, suffix, Blocks.TIER_NAMES[tier], tier]]
		for k in Blocks.PROP_KEYS:
			lines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(props.get(k, 0))])
		return "\n".join(lines)
	if Blocks.is_intermediate(id):
		var itier: int = int(mat.get("tier", 0))
		var iprops: Dictionary = slot.get("props", {})
		var ilines := ["%s — %s%s  (%s · Tier %d)" % [
			Blocks.name_of(id), mname, suffix, Blocks.TIER_NAMES[itier], itier]]
		for k in Blocks.PROP_KEYS:
			ilines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(iprops.get(k, 0))])
		return "\n".join(ilines)
	# crafted ship part (thruster/hull) carrying a material's stats
	var cprops: Dictionary = slot.get("props", {})
	if not cprops.is_empty() and mat.has("name"):
		var clines := ["%s %s%s" % [mname, Blocks.name_of(id), suffix]]
		for k in Blocks.PROP_KEYS:
			clines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(cprops.get(k, 0))])
		return "\n".join(clines)
	# ordinary block / item
	var use := Blocks.use_of(id)
	return Blocks.name_of(id) + ("\n" + use if use != "" else "")


# --- station build recipes (hand-assembled from carried materials) ------------

func _count_refined() -> int:
	var total := 0
	for s in inv:
		if Blocks.is_refined(s["id"]):
			total += s["count"]
	return total


func _remove_refined(n: int) -> int:
	for s in inv:
		if Blocks.is_refined(s["id"]) and s["count"] > 0:
			var take: int = mini(n, s["count"])
			s["count"] -= take
			n -= take
			if s["count"] == 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break
	return n


func _count_any(ids: Array) -> int:
	var total := 0
	for s in inv:
		if s["id"] in ids:
			total += s["count"]
	return total


func _remove_any(ids: Array, n: int) -> void:
	for s in inv:
		if s["id"] in ids and s["count"] > 0:
			var take: int = mini(n, s["count"])
			s["count"] -= take
			n -= take
			if s["count"] == 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break


func _recipe_afford(reqs: Array) -> bool:
	for r in reqs:
		if r.has("refined"):
			if _count_refined() < int(r["n"]):
				return false
		elif r.has("any"):
			if _count_any(r["any"]) < int(r["n"]):
				return false
		elif _count_item(int(r["id"])) < int(r["n"]):
			return false
	return true


## Properties of the material consumed by the last recipe, so an output can
## inherit them (an Ember Torch burns the ore it was made from).
var _consumed_props: Dictionary = {}
var _consumed_mat: Dictionary = {}

func _recipe_consume(reqs: Array) -> void:
	_consumed_props = {}
	_consumed_mat = {}
	for r in reqs:
		if r.has("refined"):
			for sl in inv:
				if int(sl.get("count", 0)) > 0 and Blocks.is_refined(int(sl.get("id", 0))):
					_consumed_props = sl.get("props", {}).duplicate()
					_consumed_mat = sl.get("mat", {}).duplicate()
					break
		if r.has("refined"):
			_remove_refined(int(r["n"]))
		elif r.has("any"):
			_remove_any(r["any"], int(r["n"]))
		else:
			_remove_item(int(r["id"]), int(r["n"]))


func _recipe_text(recipe: Dictionary) -> String:
	var parts := []
	for r in recipe["reqs"]:
		if r.has("refined"):
			parts.append("%d Refined Material" % int(r["n"]))
		elif r.has("any"):
			parts.append("%d %s" % [int(r["n"]), r.get("label", "items")])
		else:
			parts.append("%d %s" % [int(r["n"]), Blocks.name_of(int(r["id"]))])
	var out: int = recipe["out"]
	var n: int = recipe.get("n", 1)
	var verb := "Build" if Blocks.is_station(out) else "Craft"
	var out_txt := Blocks.name_of(out) if n == 1 else ("%d %s" % [n, Blocks.name_of(out)])
	return "%s %s  (%s)" % [verb, out_txt, ",  ".join(parts)]



# --- crafting stations --------------------------------------------------------

const _LEFT_W := 168   # left column (blueprints/actions) width
## Height of the recipe column. Four rows: enough to read a bench at a glance,
## short enough to leave the preview and progress lines below it alone.
const CRAFT_LIST_H := 140
const _STORE_COLS := 8 # storage cells per row
func _build_station_ui(layer: CanvasLayer) -> void:
	_rx = 12 + _LEFT_W + 12            # right column x
	var rx := _rx
	var grid_w := _STORE_COLS * 60
	_station_panel = Panel.new()
	_station_panel.custom_minimum_size = Vector2(rx + grid_w + 12, 124 + 4 * 60 + 16)
	_station_panel.size = _station_panel.custom_minimum_size
	_station_panel.visible = false
	layer.add_child(_station_panel)

	_station_title = Label.new()
	_station_title.position = Vector2(14, 8)
	_station_panel.add_child(_station_title)

	# --- left column: blueprints / actions -----------------------------------
	_left_header = Label.new()
	_left_header.modulate = Color(1, 1, 1, 0.7)
	_left_header.position = Vector2(14, 36)
	_station_panel.add_child(_left_header)

	_refine_btn = Button.new()
	_refine_btn.text = "Refine"
	_refine_btn.position = Vector2(12, 62)
	_refine_btn.custom_minimum_size = Vector2(_LEFT_W, 30)
	_refine_btn.pressed.connect(_on_refine)
	_station_panel.add_child(_refine_btn)

	# per-station craft buttons are (re)built when the station opens.
	#
	# Inside a scroller with a fixed height, because the number of recipes on a
	# bench is data now rather than a known small number: the Carpenter's Bench
	# went from three to eight the moment hand-crafting moved onto it, and a
	# column that simply grows runs straight through the labels underneath.
	_craft_scroll = ScrollContainer.new()
	_craft_scroll.position = Vector2(12, 62)
	_craft_scroll.custom_minimum_size = Vector2(_LEFT_W + 14, CRAFT_LIST_H)
	_craft_scroll.size = Vector2(_LEFT_W + 14, CRAFT_LIST_H)
	_craft_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_station_panel.add_child(_craft_scroll)
	_craft_row = Control.new()
	_craft_row.custom_minimum_size = Vector2(_LEFT_W, 0)
	_craft_scroll.add_child(_craft_row)

	_preview_label = Label.new()
	_preview_label.position = Vector2(14, 210)
	_preview_label.custom_minimum_size = Vector2(_LEFT_W, 0)
	_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_label.modulate = Color(0.82, 0.92, 1.0)
	_station_panel.add_child(_preview_label)

	_job_label = Label.new()
	_job_label.position = Vector2(14, 210)
	_job_label.add_theme_font_size_override("font_size", 16)
	_job_label.modulate = Color(1.0, 0.9, 0.5)
	_job_label.visible = false
	_station_panel.add_child(_job_label)

	# --- right column: machine storage (top) + your inventory (bottom) -------
	_station_store_label = Label.new()
	_station_store_label.modulate = Color(1, 1, 1, 0.7)
	_station_store_label.position = Vector2(rx + 2, 36)
	_station_panel.add_child(_station_store_label)

	# storage cells are built dynamically on open (a chest group spans several blocks)
	_stor_container = Control.new()
	_stor_container.position = Vector2(rx, 60)
	_station_panel.add_child(_stor_container)

	_pinv_label = Label.new()
	_pinv_label.text = "Your inventory  (drag to move)"
	_pinv_label.modulate = Color(1, 1, 1, 0.7)
	_pinv_label.position = Vector2(rx + 2, 122)
	_station_panel.add_child(_pinv_label)

	_pinv_grid = GridContainer.new()
	_pinv_grid.columns = HOTBAR_SLOTS
	_pinv_grid.add_theme_constant_override("h_separation", 4)
	_pinv_grid.add_theme_constant_override("v_separation", 4)
	_pinv_grid.position = Vector2(rx, 146)
	_station_panel.add_child(_pinv_grid)
	for i in SLOTS:
		_pinv_cells.append(_make_slot(_pinv_grid, i, "to_station"))


# Right-clicking a door opens/closes it (ships only; a closed door seals, an open
# one is a walk-through gap that vents air).
func _try_toggle_door() -> bool:
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		return false
	if not Blocks.is_door(int(tgt.get("id", Blocks.AIR))):
		return false
	var kind: String = tgt.get("kind", "")
	if kind == "ship":
		(tgt["obj"] as Ship).toggle_door(tgt["voxel"])
		return true
	if kind == "planet":
		(tgt["obj"] as Planet).toggle_door(tgt["voxel"])
		return true
	return false


func _looked_at_station() -> Station:
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return null
	var c := _ray.get_collider()
	return c as Station if c is Station else null


## Builds the craft buttons for a station. Split out of _open_station because
## the Shaper's list is DYNAMIC -- it depends on the block currently loaded, so
## it has to be rebuilt whenever the contents change, not just once on open.
func _rebuild_craft_buttons(st) -> void:
	var is_smelter: bool = Blocks.is_smelter_kind(st.kind)
	for b in _craft_buttons:
		b.queue_free()
	_craft_buttons.clear()
	var crafts: Array = Blocks.STATION_CRAFTS.get(Blocks.SMELTER if is_smelter else st.kind, [])
	if st.kind == Blocks.SHAPER:
		# No fixed recipe list: offer whatever shapes the loaded block can
		# become. A new shape is then one entry in Blocks.shapes_for() and works
		# for every material at once, instead of a recipe per material per shape.
		crafts = _shaper_crafts(st)
	var craft_top := 62.0 + (34.0 if is_smelter else 0.0)
	_craft_scroll.position = Vector2(12, craft_top)
	var by := 0.0
	for craft in crafts:
		var b := Button.new()
		b.text = craft["label"]
		b.position = Vector2(0, by)
		b.custom_minimum_size = Vector2(_LEFT_W, 30)
		b.pressed.connect(_on_station_craft.bind(craft))
		_craft_row.add_child(b)
		_craft_buttons.append(b)
		by += 34.0
	_craft_row.custom_minimum_size = Vector2(_LEFT_W, by)


## Labels currently shown, so a dynamic list is only torn down and rebuilt when
## it actually changed (rebuilding every frame would fight clicks and focus).
func _craft_button_labels() -> Array:
	var out: Array = []
	for b in _craft_buttons:
		out.append(b.text)
	return out


func _open_station(st: Station) -> void:
	_station_open = st
	if inv_open:
		_toggle_inventory()
	_station_title.text = st.title()
	_station_store_label.text = "%s contents  (drag to move)" % st.title()
	if st.kind == Blocks.SHAPER:
		_station_store_label.text = "Input a block, take the shapes out"
	var is_smelter: bool = Blocks.is_smelter_kind(st.kind)
	_refine_btn.visible = is_smelter

	_rebuild_craft_buttons(st)
	var has_left: bool = is_smelter or not _craft_buttons.is_empty()
	_left_header.visible = has_left
	_left_header.text = "Actions" if is_smelter else "Blueprints"

	# preview + job label sit just below the action/blueprint buttons (same spot;
	# only one shows at a time -- preview when idle, progress when working)
	# Measured from the SCROLLER, which is what actually occupies the column now:
	# the buttons inside it can be taller than the space they are shown in, and
	# the labels below have to sit under the visible box, not under the list.
	var col_h: int = mini(_craft_buttons.size() * 34, CRAFT_LIST_H) 		if not _craft_buttons.is_empty() else 34
	_craft_scroll.custom_minimum_size = Vector2(_LEFT_W + 14, col_h)
	_craft_scroll.size = Vector2(_LEFT_W + 14, col_h)
	var left_bottom: int = int(_craft_scroll.position.y) + col_h
	_preview_label.position = Vector2(14, left_bottom + 8)
	_preview_label.visible = not _craft_buttons.is_empty() or st.kind == Blocks.SHAPER
	_job_label.position = Vector2(14, left_bottom + 8)

	# build the storage grid (a chest opens its whole connected group) and reflow
	var ext := _build_storage_cells(st)   # (cols, rows) in cells
	var store_bottom: int = 60 + ext.y * 60
	_pinv_label.position = Vector2(_rx + 2, store_bottom + 4)
	_pinv_grid.position = Vector2(_rx, store_bottom + 28)
	var store_w: int = maxi(ext.x, _STORE_COLS) * 60
	var w: int = _rx + store_w + 12
	var h: int = maxi(store_bottom + 28 + 4 * 60 + 16, left_bottom + 8 + 76)
	h = maxi(h, 250)
	_station_panel.custom_minimum_size = Vector2(w, h)
	_station_panel.size = Vector2(w, h)
	var vp := get_viewport().get_visible_rect().size
	_station_panel.position = ((vp - Vector2(w, h)) * 0.5).round()

	_station_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_station_ui()


func _close_station() -> void:
	_station_open = null
	if _station_panel != null:
		_station_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# --- storage layout (chests connect into one shared grid) ---------------------

# (Re)build the storage cells for the open station, returning the grid size in
# cells (cols, rows). A chest lays out its whole connected group; other machines
# are a single 8-wide block.
func _build_storage_cells(st: Station) -> Vector2i:
	for c in _station_cells:
		c["root"].queue_free()
	_station_cells.clear()
	_stor_map.clear()
	var maxc := 0
	var maxr := 0
	for pl in _storage_placements(st):
		var idx := _stor_map.size()
		_station_cells.append(_make_stor_cell(idx, pl["cx"], pl["cy"]))
		_stor_map.append({"st": pl["st"], "slot": pl["slot"]})
		maxc = maxi(maxc, int(pl["cx"]) + 1)
		maxr = maxi(maxr, int(pl["cy"]) + 1)
	return Vector2i(maxc, maxr)


# Where each (station, slot) sits in the combined grid: {st, slot, cx, cy}.
func _storage_placements(st: Station) -> Array:
	var out := []
	if st.kind == Blocks.CHEST:
		for blk in _chest_layout(st):
			var cst: Station = blk["st"]
			for slot in cst.storage.size():
				out.append({"st": cst, "slot": slot,
					"cx": int(blk["cb"]) * _STORE_COLS + slot % _STORE_COLS,
					"cy": int(blk["rb"]) * 3 + slot / _STORE_COLS})
	else:
		for slot in st.storage.size():
			out.append({"st": st, "slot": slot, "cx": slot % _STORE_COLS, "cy": slot / _STORE_COLS})
	return out


func _make_stor_cell(index: int, cx: int, cy: int) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(INV_CELL, INV_CELL)
	root.size = Vector2(56, 56)
	root.position = Vector2(cx * 60, cy * 60)
	_stor_container.add_child(root)
	var swatch := ColorRect.new()
	swatch.position = Vector2(6, 6)
	swatch.size = Vector2(44, 44)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(swatch)
	var count := Label.new()
	count.position = Vector2(28, 34)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(count)
	root.set_drag_forwarding(
		_slot_get_drag.bind("stor", index, root),
		_slot_can_drop.bind("stor", index),
		_slot_do_drop.bind("stor", index))
	return {"root": root, "swatch": swatch, "count": count}


const MAX_CHEST_GROUP := 4   # chests won't combine into a cluster bigger than this
const _NEIGH6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


func _chest_posmap(parent: Node) -> Dictionary:
	var m := {}
	if world != null:
		for s in world._stations:
			if is_instance_valid(s) and s.kind == Blocks.CHEST and s.get_parent() == parent:
				m[Vector3i(s.position.round())] = s
	return m


# All chests connected (face-adjacent, same frame) to `chest`.
func _chest_group(chest: Station) -> Array:
	var posmap := _chest_posmap(chest.get_parent())
	var seen := {}
	var stack := [Vector3i(chest.position.round())]
	var group := []
	while not stack.is_empty():
		var p: Vector3i = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		if not posmap.has(p):
			continue
		group.append(posmap[p])
		for n in _NEIGH6:
			if not seen.has(p + n):
				stack.append(p + n)
	return group


# Size of the chest cluster that would form if a chest were placed at `cell` in
# `parent`'s frame (existing connected chests + the new one).
func _chest_cluster_size_at(parent: Node, cell: Vector3i) -> int:
	var posmap := _chest_posmap(parent)
	var seen := {}
	var stack := []
	for n in _NEIGH6:
		if posmap.has(cell + n):
			stack.append(cell + n)
	var count := 0
	while not stack.is_empty():
		var p: Vector3i = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		if not posmap.has(p):
			continue
		count += 1
		for n in _NEIGH6:
			if not seen.has(p + n):
				stack.append(p + n)
	return count + 1


# The chest's local up axis (snapped) -- stacking along it grows the grid taller;
# spreading perpendicular to it grows the grid wider.
func _chest_up_axis(c: Station) -> Vector3i:
	var y := c.transform.basis.y
	var ax := absf(y.x)
	var ay := absf(y.y)
	var az := absf(y.z)
	if ax >= ay and ax >= az:
		return Vector3i(1 if y.x >= 0.0 else -1, 0, 0)
	if ay >= az:
		return Vector3i(0, 1 if y.y >= 0.0 else -1, 0)
	return Vector3i(0, 0, 1 if y.z >= 0.0 else -1)


func _horiz_key(c: Station, up: Vector3i) -> Vector2i:
	var p := Vector3i(c.position.round())
	if absi(up.y) == 1:
		return Vector2i(p.x, p.z)
	if absi(up.x) == 1:
		return Vector2i(p.y, p.z)
	return Vector2i(p.x, p.y)


func _horiz_less(a: Station, b: Station, up: Vector3i) -> bool:
	var ka := _horiz_key(a, up)
	var kb := _horiz_key(b, up)
	return ka.x < kb.x if ka.x != kb.x else ka.y < kb.y


# Assign each chest in the group a (col-block, row-block): rows = vertical levels
# (higher chests on top), columns = ordering within a level.
func _chest_layout(chest: Station) -> Array:
	var group := _chest_group(chest)
	if group.size() <= 1:
		return [{"st": chest, "cb": 0, "rb": 0}]
	var up := _chest_up_axis(chest)
	var levels := {}
	for c in group:
		var d := Vector3i(c.position.round())
		var v: int = d.x * up.x + d.y * up.y + d.z * up.z
		if not levels.has(v):
			levels[v] = []
		levels[v].append(c)
	var keys := levels.keys()
	keys.sort()
	keys.reverse()   # higher vertical level = top row
	var out := []
	var rb := 0
	for k in keys:
		var band: Array = levels[k]
		band.sort_custom(_horiz_less.bind(up))
		var cb := 0
		for c in band:
			out.append({"st": c, "cb": cb, "rb": rb})
			cb += 1
		rb += 1
	return out


func _refresh_station_ui() -> void:
	if _station_open == null:
		return
	for i in _station_cells.size():
		_paint_cell(_station_cells[i], _slot_ref("stor", i), false)
	for i in _pinv_cells.size():
		_paint_cell(_pinv_cells[i], inv[i], false)
	# The Shaper's options depend on what is loaded RIGHT NOW, and loading
	# happens after the panel is already open -- so its buttons have to be
	# rebuilt on refresh, not just once when the station is opened. (That was
	# the bug behind "put rock in and got no options".) Only rebuilt when the
	# resulting list actually differs, so clicks and focus aren't disturbed.
	if _station_open.kind == Blocks.SHAPER:
		var want: Array = []
		for c in _shaper_crafts(_station_open):
			want.append(c["label"])
		if want != _craft_button_labels():
			_rebuild_craft_buttons(_station_open)
	var craft_key: int = Blocks.SMELTER if Blocks.is_smelter_kind(_station_open.kind) else _station_open.kind
	var has_crafts: bool = Blocks.STATION_CRAFTS.has(craft_key) or _station_open.kind == Blocks.SHAPER
	if has_crafts:
		_preview_label.text = _craft_preview_text(_station_open.kind)
	# show job progress while working; hide the idle preview during a job
	var busy: bool = _station_open.busy()
	_job_label.visible = busy
	_job_label.text = _station_open.job_text()
	if busy:
		_preview_label.visible = false
	elif has_crafts:
		_preview_label.visible = true


func _on_refine() -> void:
	if _station_open == null:
		return
	var r := _station_open.start_refine()
	if r == -1:
		_toast("Busy…")
	elif r == 0:
		_toast("Add raw ore to refine")
	else:
		_toast("Refining %d…" % r)
	_refresh_station_ui()


# The material a station will build from (first slot loaded matching its primary
# material type -- refined for the Smelter/Forge, Circuitry for the Fabricator,
# Alloy Plating for Shipworks).
## Shapes available for whatever shapeable block is loaded in a Shaper.
func _shaper_crafts(st) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for slot in st.storage:
		var sid: int = int(slot.get("id", Blocks.AIR))
		if int(slot.get("count", 0)) <= 0 or seen.has(sid):
			continue
		seen[sid] = true
		for sh in Blocks.shapes_for(sid):
			out.append({
				"label": "%s %s x%d" % [Blocks.name_of(sid), sh["shape"], int(sh["n"])],
				"out": int(sh["out"]), "n": int(sh["n"]),
				"reqs": [{"id": sid, "n": int(sh["cost_n"])}],
			})
	return out


func _station_primary_material(mtype: String) -> Dictionary:
	if _station_open == null:
		return {}
	for s in _station_open.storage:
		if s["count"] > 0 and Blocks.id_matches_material(s["id"], mtype):
			return s
	return {}


func _craft_preview_text(kind: int) -> String:
	if kind == Blocks.GENERATOR:
		var st := _station_open
		if st == null:
			return ""
		if not st.active:
			return "DAMAGED — replace the missing block to restart"
		var pct := 100.0 * st.power / Station.POWER_MAX
		if st.burn_t > 0.0:
			return "Power %d%%   burning: +%.1f/s   %.0fs left
Feed it combustible ore — the higher its Combustion, the longer and harder it burns." % [
				int(pct), st.burn_rate, st.burn_t]
		return "Power %d%%   idle
Load ore with a Combustion rating to start burning." % int(pct)
	if kind == Blocks.CARPENTER:
		return "Load Wood, Rock, and Metal to build →"
	if kind == Blocks.SHAPER:
		if _station_open != null and not _shaper_crafts(_station_open).is_empty():
			return "Pick a shape to cut →"
		return "Load a plain block (rock, dirt, wood…)
to see what it can become →"
	var mtype := Blocks.primary_material_for(kind)
	var m := _station_primary_material(mtype)
	if m.is_empty():
		var label: String = {"refined": "a refined material", "circuit": "Circuitry",
			"alloy": "Alloy Plating"}.get(mtype, "material")
		var extra_hint := "\n(plus some Metal, loaded here too)" if Blocks.is_smelter_kind(kind) else ""
		return "Load %s to build from →%s" % [label, extra_hint]
	var p: Dictionary = m["props"]
	var s := "%s   H%d D%d E%d R%d C%d" % [m["mat"].get("name", "material"),
		int(p.get("h", 0)), int(p.get("d", 0)), int(p.get("e", 0)),
		int(p.get("r", 0)), int(p.get("c", 0))]
	if kind == Blocks.FABRICATOR:
		var power := Blocks.drill_power(p)
		s += "\nDrill: power %.1f — up to Tier %d" % [power, Blocks.max_tier_for_power(power)]
		s += "\nWeapon: %.1f dmg/hit" % Blocks.weapon_damage(p)
	elif kind == Blocks.SHIPWORKS:
		s += "\nThruster thrust ↑ with Energy   |   Hull mass ↑ with Density"
	elif Blocks.is_smelter_kind(kind):
		s += "\nAlso load Metal, then pick a blueprint below:" \
			+ "\nAlloy Plating (for Shipworks) or Circuitry (for Fabricator)"
	return s


func _on_station_craft(craft: Dictionary) -> void:
	if _station_open == null:
		return
	var r := _station_open.start_craft(craft)
	if r == -1:
		_toast("Busy…")
	elif r == 0:
		if craft.has("reqs"):
			_toast("Missing materials")
		else:
			var mtype := Blocks.primary_material_for(_station_open.kind)
			var mat_label: String = {"refined": "Refined Material", "circuit": "Circuitry",
				"alloy": "Alloy Plating"}.get(mtype, "material")
			var msg := "Need %d %s loaded" % [int(craft["cost"]), mat_label]
			if craft.has("extra"):
				msg += ", plus %d %s" % [int(craft["extra"]["n"]), Blocks.name_of(int(craft["extra"]["id"]))]
			_toast(msg)
	else:
		_toast("Crafting %s…" % Blocks.name_of(int(craft["out"])))
	_refresh_station_ui()


func _update_ui() -> void:
	if _hotbar_label == null:
		return
	_update_markers()

	# targeted block + mining progress bar (hidden while piloting)
	if _target_label != null:
		if piloting != null:
			_target_label.text = ""
		else:
			# Mining progress is shown ON the block (see _update_crack) rather
			# than as a text bar, so this is just what you're looking at.
			_target_label.text = _look_name

	if eva:
		_hotbar_label.text = "EVA  (T to climb back in  |  aim + click to repair)"
		_mode_label.text = "On tether  |  6-axis thrust  |  holding: %s" % Blocks.name_of(_selected_id())
		_ship_label.text = ""
		return

	if aboard != null and is_instance_valid(aboard):
		var spd := aboard.velocity.length()
		_hotbar_label.text = "ABOARD SHIP  (walk around -- F cockpit to pilot, T to EVA)"
		_mode_label.text = "Interior gravity  |  %s" % ("cruising %.0f m/s" % spd if spd > 0.5 else "holding station")
		_ship_label.text = _life_support_text(aboard)
		return

	if piloting != null and is_instance_valid(piloting):
		var g := world.gravity_at(piloting.global_position) if world else Vector3.ZERO
		var pl := world.nearest_planet(piloting.global_position) if world else null
		var alt := 0.0
		if pl != null:
			alt = pl.altitude(piloting.global_position)
		var up := -g.normalized() if g.length() > 0.01 else Vector3.UP
		var vspeed := piloting.velocity.dot(up)  # +up / -down
		var ls := _life_support_text(piloting)
		_hotbar_label.text = "PILOTING  (F to exit)   |   %s" % ls
		if piloting.in_gravity:
			_mode_label.text = "LAUNCH/LAND ASSIST  |  Alt %.0f m  |  V-speed %+.1f m/s" % [alt, vspeed]
			if piloting.landed:
				_ship_label.text = "LANDED  (hold Space to lift off)"
			elif alt < 20.0 and absf(vspeed) < 6.0:
				_ship_label.text = "CLEAR TO LAND -- ease down with Shift"
			else:
				_ship_label.text = "Climb (Space) to break orbit and unlock maneuvering"
		else:
			_mode_label.text = "FREE FLIGHT  |  Speed %.0f m/s  |  Alt %.0f m" % [piloting.velocity.length(), alt]
			_ship_label.text = "Full 6-axis maneuvering"
		return

	var held := _selected_id()
	var tool_txt := "Drill (power %.1f, T%d)" % [mine_power, Blocks.max_tier_for_power(mine_power)] if mine_power > 1.0 else "bare hands"
	# Fine placing changes what EVERY click does, so it cannot live in a toast
	# you saw once. Left on by accident it silently builds eighth-blocks where
	# you meant whole ones -- a structure that looks right and matches nothing.
	var fine_txt := "   |   FINE PLACING (1/8) — C" if fine_place else ""
	_hotbar_label.text = "Holding: %s   |   Mining: %s%s" % [
		(Blocks.name_of(held) if held != Blocks.AIR else "(empty slot)"),
		tool_txt, fine_txt]
	_hotbar_label.modulate = Color(1.0, 0.82, 0.35) if fine_place else Color(1, 1, 1)
	var p := world.nearest_planet(global_position) if world else null
	var pname := p.planet_name if p else "Deep Space"
	_mode_label.text = "%s  |  %s" % ["GROUNDED" if grounded else "FLOATING (6-axis)", pname]

	var ship := world.nearest_ship(global_position) if world else null
	if ship != null and ship.global_position.distance_to(global_position) < 40.0:
		var st := ship.get_status()
		var near: bool = ship.global_position.distance_to(global_position) < 6.0
		var prompt := ""
		if st["can_fly"] and near:
			prompt = "  [F to pilot]"
		elif near and not st["can_fly"]:
			prompt = "  [needs cockpit + thruster + 4 blocks to fly]"
		_ship_label.text = "Ship: %d blocks  Cockpit %s  Thrusters %d%s" % [
			st["count"], "OK" if st["cockpit"] else "--", st["thrusters"], prompt]
	else:
		_ship_label.text = ""
