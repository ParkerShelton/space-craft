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

## Minecraft walks at 4.3. At 7 the world felt small -- a house was two
## strides across -- and every jump carried nearly five blocks.
const WALK_SPEED := 4.6
## How quickly you can change direction with your feet off the ground, per
## second. Low on purpose: a jump keeps the speed you left the ground with and
## can be nudged, not re-aimed. Steering at full walking speed in mid-air is
## what let a standing jump go as far as a running one.
const AIR_CONTROL := 2.5
const JUMP_SPEED := 8.0
## Webbing (see webbed): each glob that hits slows you more, and enough of them
## in a row hold you fast until you struggle out.
const WEB_MAX := 5.0
const WEB_SLOW := 0.15          # speed lost per glob
const WEB_STUCK_AT := 4.0       # this many and you are stuck
const WEB_STUCK_TIME := 1.8
## Fire sticks to you for a few seconds and burns while it does.
const BURN_DPS := 2.5
const WEB_HOLD := 5.0           # seconds after a hit before it starts to wear off
const WEB_WEAR := 0.5           # globs' worth shed per second after that
const FLY_SPEED := 16.0
const FLY_ACCEL := 6.0
const FLY_DAMP := 3.0
const MOUSE_SENS := 0.0025

# --- keys ---------------------------------------------------------------------
#
# Read through a table rather than written into the code, so they can be
# rebound. The engine's InputMap would be the other way round, but every one of
# these is POLLED (held, not pressed) in the middle of movement code, and a
# table of keycodes is the smaller change to make that rebindable.
const DEFAULT_BINDS := {
	"forward": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D,
	"jump": KEY_SPACE, "crouch": KEY_SHIFT,
	"inventory": KEY_E, "recipes": KEY_B, "stations": KEY_C,
	"rotate": KEY_R, "pilot": KEY_F, "eva": KEY_T, "starmap": KEY_M,
	"board": KEY_G,
}
## What each one is called on the settings page, in the order they show there.
const BIND_ORDER := ["forward", "back", "left", "right", "jump", "crouch",
	"inventory", "recipes", "stations", "rotate", "pilot", "board", "eva",
	"starmap"]
const BIND_NAMES := {
	"forward": "Walk forward", "back": "Walk back", "left": "Strafe left",
	"right": "Strafe right", "jump": "Jump / ascend", "crouch": "Crouch / descend",
	"inventory": "Inventory", "recipes": "Recipe book",
	"stations": "Station ring (hold)", "rotate": "Rotate what you are placing",
	"pilot": "Take the controls", "board": "Build a ship", "eva": "EVA suit",
	"starmap": "Star map",
}
var binds := DEFAULT_BINDS.duplicate()

## Is the key for this action held down right now?
func key_down(action: String) -> bool:
	return Input.is_physical_key_pressed(int(binds.get(action, DEFAULT_BINDS[action])))


## Was this event the key for this action?
func key_is(event: InputEventKey, action: String) -> bool:
	return event.keycode == int(binds.get(action, DEFAULT_BINDS[action]))

## Multiplies MOUSE_SENS. A setting, because what feels like a flick of the
## wrist to one person is a whole arm to another.
var look_sensitivity := 1.0
## Looking straight down and dragging up moves the view up, unless you grew up
## on a flight stick.
var invert_look := false
## Whether the HUD names the block under the crosshair.
var show_look_names := true
## Down on one knee: set while walking, cleared everywhere else, and sent to
## everyone else so their copy of you does it too.
var crouching := false
## Counts down from COYOTE_TIME once the ground is gone.
var _coyote := 0.0
## Counts down from JUMP_BUFFER after the jump key goes down in the air.
var _jump_buffer := 0.0
var _jump_was_held := false
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
## Crouching. Slower, because a careful step is a slow one -- and because the
## speed is what tells you the ledge guard is on without a word on screen.
const CROUCH_SPEED_MULT := 0.45
## How far the eye drops when crouching, as a fraction of standing eye height.
## Enough that you can see it happen in first person -- the point of a crouch
## you cannot see is not obvious.
const CROUCH_EYE_MULT := 0.55
## How far past the step to probe for floor, and how far down.
##
## Small on purpose. The probe is what decides where a crouched step stops, and
## at 0.45 it stopped you with the whole body still on the block -- safe, and
## useless for the thing crouching is actually for, which is leaning out over an
## edge to see what is under it. At 0.08 your centre gets within a hand's width
## of the lip and the body overhangs by most of its width, which is what makes
## looking down over a drop possible. The capsule still rests on what is left of
## the block, so you do not fall.
const CROUCH_LOOKAHEAD := 0.08
const CROUCH_PROBE := 1.25

## How long after walking off an edge a jump still counts.
##
## Not a cheat: a player presses jump when they SEE themselves at the edge, and
## by the time the input arrives the body has already left it. Every platformer
## worth playing has this, and the ones that do not are the ones that feel like
## they are ignoring you.
const COYOTE_TIME := 0.12

## And the other half of it: a jump pressed just BEFORE landing is remembered
## and fires the moment the ground arrives. Without it, the input a player makes
## while watching themselves fall is simply thrown away, and the game feels like
## it dropped the key press -- which it did.
const JUMP_BUFFER := 0.15

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
## How far you can touch the world with nothing in your hands.
##
## Deliberately short. Reach used to be six blocks flat, which is two floors of
## a building from where you stand -- so no tool could ever make you feel like
## you had got further, because you were already everywhere. A tool adds to
## this, and the Drill adds most.
const REACH_BARE := 3.6
## The longest reach any tool can give, so the physics ray is sized once for the
## worst case rather than rebuilt whenever your bag changes.
const REACH_MAX := 6.0
var reach := REACH_BARE          # block interaction distance, with what you carry
const BARE_MINE_MULT := 2.5       # bare-hand mining is slow; a drill divides this
## How much slower bare hands are than BARE_MINE_MULT on the three kinds of
## material a basic tool is for -- the gap that makes the tool worth making.
## At a flat 2.5 for everything, a Pick only halved the time it took to break
## rock, and 2.25 seconds a block was never long enough to want one. These put
## hands close to Minecraft's: rock about 7 seconds, a log 3, dirt about 1. The
## times WITH the tool are unchanged; only doing without got slower. Anything
## no tool helps with -- glass, metal, a torch -- keeps BARE_MINE_MULT.
## Soil was 3.0 -- about a second a block by hand against a third of one with a
## Spade -- and at those speeds the two felt the same: both quick enough not to
## notice. At 7.0 a block of dirt is two and a half seconds by hand, and the
## Spade is the difference between digging a hole and waiting for one.
const HAND_MINE_MULT := {"rock": 8.0, "wood": 5.0, "soil": 7.0}
var mine_power := 1.0             # >1 once you craft a drill (Phase 2)
## How hard you hit each kind of material, from the best tool you carry for it.
## Bare hands are 1.0 at everything.
var _class_power := {"rock": 1.0, "wood": 1.0, "soil": 1.0}


## What you are effectively swinging at this block.
func _power_for(id: int) -> float:
	var c := Blocks.material_class(id)
	if c == "":
		return mine_power     # nothing is specialised for it; only a Drill helps
	return maxf(float(_class_power.get(c, 1.0)), 1.0)

# --- survival ---
const MAX_HEALTH := 100.0
const MAX_OXYGEN := 100.0
const O2_DRAIN := 4.0             # oxygen/sec with no air (space / airless / underwater)
const O2_REFILL := 30.0           # oxygen/sec while breathing (in atmosphere or a ship)
const SUFFOCATE_DMG := 7.0        # health/sec once oxygen hits zero
const HEALTH_REGEN := 3.0         # health/sec while safe and oxygenated
## Lying down heals faster than standing about, and unlike standing about it
## does not ask you to be well fed -- resting is the thing you do BECAUSE you
## are in a bad way.
const BED_REGEN := 9.0
## Lying down: the eye drops to about the height of the bedding, and the view
## tips back toward the sky. Both eased rather than snapped, because the whole
## point is that it reads as getting INTO something.
const BED_EYE := 0.12
const BED_PITCH := 0.85     # radians up from level, a bit over halfway to straight up
const BED_SETTLE := 0.6     # seconds the view takes to tip back
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
## The model inside it, when what you are holding has one (food, the journal).
## Kept so the eating and reading animations have something to move.
var _held_item: MeshInstance3D
var _held_book: Node3D        # the journal, which has a hinge
var _eating := false          # right mouse held with food in hand
var _eating_id := 0
var _eat_t := 0.0             # how long you have been at it
var _eat_bites := -1          # how much of the model has been bitten away
var _read_t := 0.0            # 0 shut, 1 open -- the journal in your hands
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
## The hotbar and the bag are drawn bigger than a station's storage: they are
## what you look at most, and 56 pixels was small enough to squint at. Station
## panels keep INV_CELL, because their layout is measured in fixed steps of it.
const HOTBAR_CELL := 68
const HOTBAR_GAP := 6
const BAG_CELL := 64
const BAG_GAP := 8
const BAG_STEP := BAG_CELL + BAG_GAP
## Slot frames: a dark translucent tile with a soft border, and a bright gold
## one for the slot in your hand. Shared, so every slot in the game matches.
const SLOT_BG := Color(0.07, 0.08, 0.11, 0.78)
const SLOT_EDGE := Color(0.34, 0.40, 0.50, 0.85)
const SLOT_EDGE_HOVER := Color(0.55, 0.64, 0.78, 0.95)
const SLOT_SELECT := Color(1.0, 0.84, 0.38, 1.0)
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
var _web := 0.0
var _web_hold := 0.0
var _stuck_t := 0.0
var _web_overlay: TextureRect
var _burn_t := 0.0
var _dread := 0.0
var _dread_want := 0.0
var _dread_rect: TextureRect
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
## Coming round. You open your eyes looking at the floor and your head comes up
## on its own; look input is ignored until it has, because you are not in
## control yet and that is the whole point of the moment.
## The seat you are in, if any. Sitting is not a mode with much in it: you stay
## where the seat is, you can look around, and you cannot walk. Crouch gets you
## out -- the same key that gets you out of everywhere else.
var seated: Node3D = null
var _rousing := false
var _rouse_end_ms := 0
var _rouse_len := 0.0
var _rouse_from := 0.0
var _interior_floor := false
var _body_shape: CollisionShape3D
## Where a bed has been claimed, and on which planet. Empty planet name means
## none claimed, and death falls back to the home world's spawn point as before.
var bed_planet := ""
var bed_pos := Vector3.ZERO

## Lying in one. The world carries on around you -- this is rest, not a pause.
var in_bed := false
var _bed_settle := 0.0
var _bed_yaw_to := Vector3.ZERO
var _bed_panel: Control
var _bed_planet_now: Planet

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
## Eighth-block placing is parked: stations are set models you put down from
## the station ring now, so there is nothing left that needed placing by the
## eighth. Left as a constant so the ghost and the crosshair still read it.
const fine_place := false
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
	# Upgrades are always listed: they are how half the stations in the game
	# come to exist, and nothing else in the game says so.
	return all_known or known_recipes.has(key) or key.begins_with("grow:")


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
var _gen_switch_btn: Button        # Generator's on/off, the lever's twin
var _craft_row: Control            # holds per-station craft buttons
var _craft_scroll: ScrollContainer # scrolls them when a bench has many
var _craft_buttons: Array = []     # current station's craft buttons
var _craft_multi: Array = []       # the x5 / All buttons beside each craft
## See _craft_signature: what the list was showing when it was last built.
var _craft_sig := ""
var _char_preview: CharacterPreview   # you, in the inventory
# Vanity: what you look like, and nothing else -- see Cosmetics. One slot per
# Cosmetics.SLOTS entry, each shaped like an `inv` entry.
var vanity: Dictionary = {}
var _vanity_cells: Dictionary = {}    # slot -> cell
var _gear_box: Control                # the Suit slot, on the Gear tab
var _vanity_box: Control              # the seven vanity slots, on the Vanity tab
var _gear_tab: Button
var _vanity_tab: Button
var _look_tag := -1
var _trail: CPUParticles3D            # your own trail, left where you walk
var _trail_id := 0
var _preview_label: Label          # live craft-stat preview (Fabricator/Shipworks)
var _job_label: Label              # "Refining… 60%" / "Crafting… 30%" while a job runs
var _markers: Array[Label] = []   # one navigation marker per planet
## Where this world began, once she has flown (see WorldManager.crash_site).
var _crash_marker: Label


func _ready() -> void:
	call_deferred("_apply_look")   # whatever a loaded save has you wearing
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
	_ray.target_position = Vector3(0, 0, -REACH_MAX)
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
		"vanity": vanity,
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
	if d.has("vanity"):
		vanity = d["vanity"]
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
	var cap := Blocks.stack_cap(id, STACK_MAX)
	for s in inv:
		if s["id"] == id and s.get("src", "") == src and s["count"] > 0 and s["count"] < cap:
			var add: int = mini(n, cap - s["count"])
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
		s.erase("dur")
		var add: int = mini(n, cap)
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
			# Only once the eighths are gone too: a slot at no whole blocks can
			# still hold a quarter of one, and wiping its id left that quarter
			# with no item behind it -- drawn in the colour for nothing, pink.
			if s["count"] == 0 and int(s.get("eighths", 0)) <= 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break
	return n


## -1 when the vertical axis is inverted, which is all "inverted" means.
func _look_sign() -> float:
	return -1.0 if invert_look else 1.0


func set_fov(deg: float) -> void:
	if _camera != null:
		_camera.fov = deg


func _selected_id() -> int:
	# Change counts as carrying it: a slot holding five eighths of a rock can
	# still place four more eighths, and reading as empty would strand them.
	var s = inv[active_slot]
	return s["id"] if (int(s["count"]) > 0 or int(s.get("eighths", 0)) > 0) else Blocks.AIR


## What this player is visibly doing, so others can draw it (see Net.player_state).
## 0 = nothing, 1 = mining, 2 = placing.
## 0 nothing, 1 mining, 2 placing, plus CROUCH_BIT on top of any of them.
## A bit rather than another argument: this rides in a twenty-times-a-second
## broadcast, and it is one thing about the body among several.
const CROUCH_BIT := 4

func action_state() -> int:
	var a := 0
	if _place_flash > 0.0:
		a = 2
	elif _mine_time > 0.0:
		a = 1
	return a | (CROUCH_BIT if crouching else 0)


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
		if s["count"] == 0 and int(s.get("eighths", 0)) <= 0:
			s["id"] = Blocks.AIR
	_refresh_slots()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look += event.relative
	elif event is InputEventMouseButton and event.pressed:
		if inv_open or book_open or _station_open != null or menu_open or ui_typing:
			return  # a panel is open: clicks go to the UI
		# The ring has the mouse OUT on purpose, so it has to be asked before the
		# click that takes the mouse back -- that branch was eating every click
		# aimed at a station and putting the pointer away again.
		if _ring != null:
			if event.button_index == MOUSE_BUTTON_LEFT and _ring_hover >= 0:
				var it: Dictionary = _ring_items[_ring_hover]
				if bool(it["ok"]):
					_begin_placing(int(it["kind"]))
					_close_ring()
				else:
					Audio.ui("ui_deny")
					_toast("Not enough for a %s" % Blocks.name_of(int(it["kind"])))
			return
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if piloting:
			return  # no building while flying
		if _place_kind != Blocks.AIR:
			# A ghost in hand takes the click: right to put it down, the way
			# everything else in this game is placed.
			if event.button_index == MOUSE_BUTTON_RIGHT:
				_do_place_station()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				_toast("Right-click to place it, Esc to put it away")
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# right-click: open a station, or open/close a door, otherwise place a block
			#
			# Holding SHIFT means "I want to build here", and skips every one of
			# those. Once a bench is a bench, right-clicking it is the only way
			# to open it -- but it is also a flat surface at waist height with a
			# wall behind it, which is exactly where you want to keep building.
			if key_down("crouch"):
				_edit_block(false)
				return
			var st := _looked_at_station()
			# Beds are not reached here -- a build made of eighths has no
			# collider of its own, so see _try_assemble_machine below.
			if st != null and not eva:
				if not _use_generator_part(st):
					_open_station(st)
			elif _try_eat():
				pass
			# Farming comes before building: with a hoe or a seed in hand, the
			# ground under the crosshair is what you mean, and a block placed
			# instead of a row sown is a whole minute undone.
			elif _try_feed(_raycast_voxel()):
				pass
			elif _try_harvest(_raycast_voxel()):
				pass
			elif _try_plant(_raycast_voxel()):
				pass
			elif _try_till(_raycast_voxel()):
				pass
			elif _try_bucket(_raycast_voxel()):
				pass
			elif _try_read_journal():
				pass
			elif _try_launch_boat():
				pass
			elif _try_sit():
				pass
			elif _try_ship_computer():
				pass
			elif _try_ship_fitting():
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
	elif event is InputEventKey and not event.pressed and key_is(event, "stations"):
		_close_ring()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _journal_panel != null:
				_close_journal()
			elif _sys_panel != null:
				_close_fitting_panel()
			elif _ship_panel != null:
				_close_ship_computer()
			elif _place_kind != Blocks.AIR:
				_cancel_placing()
				_toast("Put it away")
			elif in_bed:
				_get_up()
			elif _station_open != null:
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
		elif key_is(event, "inventory"):
			if piloting != null:
				pass  # E rolls the ship while piloting -- not the inventory
			elif _station_open != null:
				_close_station()
			else:
				_toggle_inventory()
		elif _station_open != null:
			return  # a station panel is open: swallow other keys
		elif key_is(event, "pilot"):
			_toggle_pilot()
		elif key_is(event, "eva"):
			_toggle_eva()
		elif key_is(event, "starmap"):
			# warp requires actually piloting a ship built with a Warp Drive, in
			# space -- an exception to "only F/Esc/mouse-look work while flying"
			_try_open_starmap()
		elif piloting:
			return  # while flying, only F/M/Esc/mouse-look do anything
		elif key_is(event, "rotate") and _place_kind != Blocks.AIR:
			# Turning what is about to be put down, a quarter at a time.
			_place_rot = (_place_rot + 1) % 4
		elif key_is(event, "rotate"):
			# Step through EVERY stair state: the straight run turned through
			# four quarters, then the corner through four. Facing is part of the
			# cycle rather than read from the camera, so the ghost always shows
			# precisely what will be placed.
			_stair_state = (_stair_state + 1) % Blocks.STAIR_STATES
			_toast("Stairs: %s" % Blocks.stair_state_name(_stair_state))
		elif key_is(event, "stations"):
			_open_ring()
		elif key_is(event, "recipes"):
			if not (_book_search != null and _book_search.has_focus()):
				_toggle_book()
		elif key_is(event, "board"):
			if aboard == null and not eva:
				_start_ship()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_8:
			active_slot = event.keycode - KEY_1
			_refresh_slots()


# --- the station ring -----------------------------------------------------------
#
# Hold the key and every station you can build comes up in a ring round the
# crosshair. Mouse over one to see what it costs -- greyed out if you cannot
# afford it -- and click it to take up a ghost of the thing itself, which you
# turn with R and put down with a click.

const RING_RADIUS := 300.0
const RING_CELL := 84.0
const RING_CARD_W := 300.0
const RING_CARD_H := 300.0

var _ring: Control
var _ring_items: Array = []        # [{kind, node, reqs, ok}]
var _ring_hover := -1
var _ring_card_shown := -2         # which one the card in the middle is showing
var _ring_card: Panel
var _ring_card_icon: TextureRect
var _ring_card_name: Label
var _ring_card_reqs: VBoxContainer
var _place_kind := Blocks.AIR      # what the ghost is showing, AIR for nothing
var _place_rot := 0
var _place_ghost: MeshInstance3D
var _place_ok := false
var _place_from_item := false      # holding one in your bag rather than building it


func _open_ring() -> void:
	if _ring != null or menu_open or inv_open or book_open:
		return
	_place_kind = Blocks.AIR
	_clear_ghost_model()
	_ring = Control.new()
	_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(_ring)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.35)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.add_child(shade)
	_ring_items.clear()
	_ring_hover = -1
	_ring_card_shown = -2
	var builds: Array = Blocks.STATION_BUILDS
	var vp := get_viewport().get_visible_rect().size
	var centre := vp * 0.5
	for i in builds.size():
		var b: Dictionary = builds[i]
		var kind := int(b["kind"])
		var ang := TAU * float(i) / float(builds.size()) - PI * 0.5
		var at := centre + Vector2(cos(ang), sin(ang)) * RING_RADIUS
		var cell := Panel.new()
		cell.size = Vector2(RING_CELL, RING_CELL)
		cell.position = at - Vector2(RING_CELL, RING_CELL) * 0.5
		# Styled as an inventory slot, so it reads as something to pick up.
		var sb := StyleBoxFlat.new()
		sb.bg_color = SLOT_BG
		sb.border_color = SLOT_EDGE
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(8)
		cell.add_theme_stylebox_override("panel", sb)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ring.add_child(cell)
		var icon := TextureRect.new()
		icon.texture = ItemIcon.of(kind, Blocks.color_of(kind),
			world.nearest_planet(global_position) if world != null else null)
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 8
		icon.offset_top = 6
		icon.offset_right = -8
		icon.offset_bottom = -22
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(icon)
		var nm := Label.new()
		nm.text = Blocks.name_of(kind)
		nm.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		nm.offset_top = -20
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.add_theme_font_size_override("font_size", 11)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(nm)
		_ring_items.append({"kind": kind, "node": cell, "reqs": b["reqs"],
			"ok": _can_afford(b["reqs"]), "at": at})
	# The card in the middle: a big picture of whatever the mouse is over, what
	# it takes line by line, and a tick or a cross against each.
	_ring_card = Panel.new()
	_ring_card.set_anchors_preset(Control.PRESET_CENTER)
	_ring_card.size = Vector2(RING_CARD_W, RING_CARD_H)
	_ring_card.position = -_ring_card.size * 0.5
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.05, 0.06, 0.09, 0.96)
	csb.border_color = SLOT_EDGE
	csb.set_border_width_all(2)
	csb.set_corner_radius_all(10)
	_ring_card.add_theme_stylebox_override("panel", csb)
	_ring_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.add_child(_ring_card)
	_ring_card_icon = TextureRect.new()
	_ring_card_icon.position = Vector2(RING_CARD_W * 0.5 - 60.0, 12)
	_ring_card_icon.size = Vector2(120, 120)
	_ring_card_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_ring_card_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_ring_card_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_card.add_child(_ring_card_icon)
	_ring_card_name = Label.new()
	_ring_card_name.position = Vector2(0, 134)
	_ring_card_name.size = Vector2(RING_CARD_W, 30)
	_ring_card_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ring_card_name.add_theme_font_size_override("font_size", 22)
	_ring_card_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_card.add_child(_ring_card_name)
	_ring_card_reqs = VBoxContainer.new()
	_ring_card_reqs.position = Vector2(22, 174)
	_ring_card_reqs.custom_minimum_size = Vector2(RING_CARD_W - 44.0, 0)
	_ring_card_reqs.add_theme_constant_override("separation", 6)
	_ring_card_reqs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_card.add_child(_ring_card_reqs)
	_paint_ring()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_viewport().warp_mouse(get_viewport().get_visible_rect().size * 0.5)


func _close_ring() -> void:
	if _ring == null:
		return
	_ring.queue_free()
	_ring = null
	_ring_items.clear()
	_ring_card = null
	if not (menu_open or inv_open or book_open):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Which one the mouse is over, and what it costs.
func _paint_ring() -> void:
	if _ring == null:
		return
	var m := _ring.get_local_mouse_position()
	_ring_hover = -1
	var best := RING_CELL * 0.8
	for i in _ring_items.size():
		var it: Dictionary = _ring_items[i]
		var d: float = (m - (it["at"] as Vector2)).length()
		if d < best:
			best = d
			_ring_hover = i
	for i in _ring_items.size():
		var it2: Dictionary = _ring_items[i]
		var cell: Panel = it2["node"]
		var ok: bool = it2["ok"]
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.16, 0.14, 0.08, 0.9) if i == _ring_hover else SLOT_BG
		sb.border_color = SLOT_SELECT if i == _ring_hover else (SLOT_EDGE if ok else Color(0.3, 0.2, 0.2, 0.7))
		sb.set_border_width_all(3 if i == _ring_hover else 2)
		sb.set_corner_radius_all(8)
		cell.add_theme_stylebox_override("panel", sb)
		# Greyed out is the whole of the message for one you cannot afford.
		cell.modulate = Color(1, 1, 1, 1) if ok else Color(0.45, 0.45, 0.5, 0.75)
	if _ring_card == null or _ring_hover == _ring_card_shown:
		return       # the card only changes when what is under the mouse does
	_ring_card_shown = _ring_hover
	for c in _ring_card_reqs.get_children():
		c.queue_free()
	if _ring_hover < 0:
		_ring_card_icon.texture = null
		_ring_card_name.text = "Stations"
		var hint := Label.new()
		hint.text = "Point at one to see what it takes.\nClick it to pick it up and place it."
		hint.custom_minimum_size = Vector2(RING_CARD_W - 44.0, 0)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 14)
		hint.modulate = Color(1, 1, 1, 0.55)
		_ring_card_reqs.add_child(hint)
		return
	var hov: Dictionary = _ring_items[_ring_hover]
	var kind := int(hov["kind"])
	_ring_card_icon.texture = ItemIcon.of(kind, Blocks.color_of(kind),
		world.nearest_planet(global_position) if world != null else null)
	_ring_card_name.text = Blocks.name_of(kind)
	_ring_card_name.modulate = Color(1, 1, 1) if bool(hov["ok"]) else Color(1, 0.7, 0.68)
	for r in (hov["reqs"] as Array):
		var need := int(r["n"])
		var have := _count_req(r)
		var enough := have >= need
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		_ring_card_reqs.add_child(line)
		# A tick or a cross, so which line is the problem is plain at a glance.
		var tick := Label.new()
		tick.text = "✓" if enough else "✗"
		tick.custom_minimum_size = Vector2(20, 0)
		tick.add_theme_font_size_override("font_size", 17)
		tick.modulate = Color(0.45, 0.95, 0.5) if enough else Color(1.0, 0.45, 0.42)
		line.add_child(tick)
		var what := Label.new()
		what.text = _req_label(r)
		what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		what.add_theme_font_size_override("font_size", 17)
		line.add_child(what)
		var count := Label.new()
		count.text = "%d / %d" % [have, need]
		count.add_theme_font_size_override("font_size", 17)
		count.modulate = Color(0.45, 0.95, 0.5) if enough else Color(1.0, 0.45, 0.42)
		line.add_child(count)
	var fp := StationModels.footprint(kind)
	var size_line := Label.new()
	size_line.text = ("stands on %d x %d blocks" % [fp.x, fp.z]) if fp.x * fp.z > 1 else "stands on one block"
	size_line.add_theme_font_size_override("font_size", 13)
	size_line.modulate = Color(1, 1, 1, 0.5)
	_ring_card_reqs.add_child(size_line)


func _req_label(r: Dictionary) -> String:
	if r.has("label"):
		return str(r["label"])
	return Blocks.name_of(int(r["id"]))


## How many of what this requirement asks for you are carrying.
func _count_req(r: Dictionary) -> int:
	var total := 0
	for sl in inv:
		if int(sl.get("count", 0)) <= 0:
			continue
		var id := int(sl["id"])
		if r.has("any"):
			if id in (r["any"] as Array):
				total += int(sl["count"])
		elif id == int(r["id"]):
			total += int(sl["count"])
	return total


func _can_afford(reqs: Array) -> bool:
	for r in reqs:
		if _count_req(r) < int(r["n"]):
			return false
	return true


## Take the cost out of your pockets. Only called once the placement is good.
func _pay(reqs: Array) -> void:
	for r in reqs:
		var left := int(r["n"])
		for sl in inv:
			if left <= 0:
				break
			if int(sl.get("count", 0)) <= 0:
				continue
			var id := int(sl["id"])
			var matches: bool = (id in (r["any"] as Array)) if r.has("any") else (id == int(r["id"]))
			if not matches:
				continue
			var take: int = mini(left, int(sl["count"]))
			sl["count"] = int(sl["count"]) - take
			left -= take
			if int(sl["count"]) <= 0:
				_clear_slot(sl)
	_refresh_slots()


## Most of what it cost, back in your hands. Not all of it: taking a bench apart
## and putting it up again should cost something, or placement is free anyway.
func _refund(kind: int) -> void:
	for r in Blocks.station_cost(kind):
		var n := int(ceil(float(r["n"]) * 0.75))
		var id: int = int((r["any"] as Array)[0]) if r.has("any") else int(r["id"])
		if n > 0:
			_add_item(id, n)


# --- the ghost of what you are about to put down ---------------------------------

## A station picked up and carried shows its ghost the moment it is in your
## hand: it is already paid for, so there is nothing to choose and no reason to
## make you open the ring to put it back down.
func _sync_held_station() -> void:
	var sel := _selected_id()
	var carried: bool = Blocks.is_station_build(sel) or Blocks.is_station(sel)
	if carried and (_place_kind != sel or not _place_from_item):
		_begin_placing(sel, true)
	elif not carried and _place_from_item:
		_cancel_placing()


func _begin_placing(kind: int, from_item := false) -> void:
	_place_kind = kind
	_place_from_item = from_item
	_place_rot = 0
	_clear_ghost_model()
	_place_ghost = MeshInstance3D.new()
	_place_ghost.mesh = StationModels.mesh_for(kind, true)
	_place_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if world != null:
		world.add_child(_place_ghost)
	if not from_item:
		_toast("%s — right-click to place, R to turn, Esc to put it away" % Blocks.name_of(kind))


func _clear_ghost_model() -> void:
	if _place_ghost != null and is_instance_valid(_place_ghost):
		_place_ghost.queue_free()
	_place_ghost = null


func _cancel_placing() -> void:
	_place_kind = Blocks.AIR
	_place_from_item = false
	_clear_ghost_model()


## Where the station would stand, given where you are looking: which cells it
## would fill, and the transform to stand it in.
func _place_spot(tgt: Dictionary = {}) -> Dictionary:
	if _place_kind == Blocks.AIR or world == null:
		return {}
	if tgt.is_empty():
		tgt = _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		return {}
	if tgt.get("kind", "") == "ship":
		return _place_spot_on_ship(tgt)
	if tgt.get("kind", "") != "planet":
		return {}
	var planet := tgt["obj"] as Planet
	var anchor: Vector3i = tgt["place"]
	var g := world.gravity_at(planet.to_global(Vector3(anchor)))
	var up: Vector3 = _snap_to_axis(-g) if g.length() > 0.01 else Vector3.UP
	var upi := Vector3i(roundi(up.x), roundi(up.y), roundi(up.z))
	# Which way it faces: away from you, turned by however many times R was hit.
	var face := -global_transform.basis.z
	face -= up * face.dot(up)
	var fwd: Vector3 = _snap_to_axis(face)
	if fwd == Vector3.ZERO or absf(fwd.dot(up)) > 0.5:
		fwd = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	for i in _place_rot:
		fwd = fwd.rotated(up, PI * 0.5)
		fwd = _snap_to_axis(fwd)
	var right: Vector3 = up.cross(-fwd)
	var fi := Vector3i(roundi(fwd.x), roundi(fwd.y), roundi(fwd.z))
	var ri := Vector3i(roundi(right.x), roundi(right.y), roundi(right.z))
	var fp := StationModels.footprint(_place_kind)
	var cells: Array = []
	for a in fp.x:
		for b in fp.y:
			for c in fp.z:
				cells.append(anchor + ri * a + upi * b + fi * c)
	# Every cell it would fill has to be free, and it has to be standing on
	# something rather than hanging in the air.
	var ok := true
	for cv in cells:
		var id := Blocks.bottom_of(planet.get_id(cv))
		if id != Blocks.AIR and id != Blocks.WATER:
			ok = false
		# ...and nothing already standing there, which no block would show.
		elif world.station_blocking(planet.to_global(Vector3(cv) + Vector3(0.5, 0.5, 0.5))):
			ok = false
	var footed := false
	for a2 in fp.x:
		for c2 in fp.z:
			var under := anchor + ri * a2 + fi * c2 - upi
			var uid := Blocks.bottom_of(planet.get_id(under))
			if uid != Blocks.AIR and uid != Blocks.WATER:
				footed = true
	if not footed:
		ok = false
	# The middle of the bottom layer, in world space, is where it stands.
	var centre_local := Vector3(anchor) + Vector3(0.5, 0.5, 0.5) 		+ (Vector3(ri) * float(fp.x - 1) + Vector3(fi) * float(fp.z - 1)) * 0.5
	var pos := planet.to_global(centre_local)
	if pos.distance_to(global_position) < 1.2:
		ok = false
	return {"planet": planet, "cells": cells, "pos": pos, "up": up, "fwd": fwd, "ok": ok}


## The same question asked of a ship instead of a planet: where would this
## station stand, does it fit, and is it standing on anything.
##
## A ship has no gravity of its own and no axis to snap to, so everything is
## measured in the hull's own frame -- up is the deck's up, whichever way the
## ship is lying. Without this a station could not go on a ship at all: the
## routine returned nothing the moment you were not pointing at a planet, so
## there was no ghost and no way to put one down.
func _place_spot_on_ship(tgt: Dictionary) -> Dictionary:
	var ship := tgt["obj"] as Ship
	if ship == null:
		return {}
	var anchor: Vector3i = tgt["place"]
	var sb := ship.global_transform.basis
	var up: Vector3 = sb.y.normalized()
	var upi := Vector3i(0, 1, 0)
	# Facing: the ship-local axis nearest the way you are looking, turned by
	# however many times R was pressed.
	var look: Vector3 = sb.inverse() * (-global_transform.basis.z)
	look.y = 0.0
	var fi := Vector3i(0, 0, -1)
	if absf(look.x) > absf(look.z):
		fi = Vector3i(1, 0, 0) if look.x > 0.0 else Vector3i(-1, 0, 0)
	elif look.z > 0.0:
		fi = Vector3i(0, 0, 1)
	for i in _place_rot:
		fi = Vector3i(fi.z, 0, -fi.x)
	var ri := Vector3i(fi.z, 0, -fi.x)
	var fp := StationModels.footprint(_place_kind)
	var cells: Array = []
	for a in fp.x:
		for b in fp.y:
			for c in fp.z:
				cells.append(anchor + ri * a + upi * b + fi * c)
	var ok := true
	for cv in cells:
		if ship.blocks.has(cv):
			ok = false
		elif world.station_blocking(ship.to_global(Vector3(cv) + Vector3(0.5, 0.5, 0.5))):
			ok = false
	var footed := false
	for a2 in fp.x:
		for c2 in fp.z:
			if ship.blocks.has(anchor + ri * a2 + fi * c2 - upi):
				footed = true
	if not footed:
		ok = false
	var centre_local := Vector3(anchor) + Vector3(0.5, 0.5, 0.5) \
		+ (Vector3(ri) * float(fp.x - 1) + Vector3(fi) * float(fp.z - 1)) * 0.5
	var pos := ship.to_global(centre_local)
	if pos.distance_to(global_position) < 1.2:
		ok = false
	return {"ship": ship, "cells": cells, "pos": pos, "up": up,
		"fwd": (sb * Vector3(fi)).normalized(), "ok": ok,
		"local": anchor, "local_fwd": fi}


## Follow the crosshair with the ghost, green where it would go, red where it
## would not.
func _update_place_ghost(spot: Dictionary = {}) -> void:
	if _place_kind == Blocks.AIR or _place_ghost == null:
		return
	if spot.is_empty():
		spot = _place_spot()
	_place_ok = bool(spot.get("ok", false)) and (_place_from_item
		or _can_afford(Blocks.station_cost(_place_kind)))
	_place_ghost.visible = not spot.is_empty()
	if spot.is_empty():
		return
	var up: Vector3 = spot["up"]
	var fwd: Vector3 = spot["fwd"]
	var x := up.cross(-fwd).normalized()
	_place_ghost.global_transform = Transform3D(Basis(x, up, -fwd), spot["pos"] as Vector3)
	_place_ghost.position -= up * 0.5     # model space stands on y 0
	var mat := _place_ghost.get_active_material(0)
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).albedo_color = Color(0.6, 1.0, 0.6, 0.45) if _place_ok 			else Color(1.0, 0.4, 0.4, 0.4)


## Put it down, if it fits and you can pay for it.
func _do_place_station() -> void:
	var spot := _place_spot()
	var reqs := Blocks.station_cost(_place_kind)
	if spot.is_empty() or not spot.get("ok", false):
		# A station in hand can also go on a ship, which the ground check knows
		# nothing about -- that path still handles it.
		if _place_from_item:
			_place_station(_place_kind)
			return
		_toast("No room for that here")
		Audio.ui("ui_deny")
		return
	if not _place_from_item and not _can_afford(reqs):
		_toast("Not enough materials")
		Audio.ui("ui_deny")
		return
	if _place_from_item:
		_consume_active()
	else:
		_pay(reqs)
	# On a ship it is mounted as a child of the hull, so it rides with her; on
	# a planet it simply stands where it was put.
	var st: Station = null
	if spot.has("ship"):
		st = world.spawn_station_on_ship(_place_kind, spot["ship"] as Ship,
			spot["local"] as Vector3i, spot["local_fwd"] as Vector3i)
	else:
		st = world.spawn_station(_place_kind, (spot["pos"] as Vector3) - Vector3(0.5, 0.5, 0.5),
			spot["up"] as Vector3, spot["fwd"] as Vector3)
	if st != null:
		_toast("%s built" % Blocks.name_of(_place_kind))
		Audio.at("place_rock", spot["pos"] as Vector3)
	# Still holding the same thing, so a row of chests is a row of clicks --
	# until the stack or the materials run out.
	if not _place_from_item and not _can_afford(reqs):
		_cancel_placing()


# --- the ship's computer ---------------------------------------------------------
#
# Right-click the cockpit. While the ship is wrecked this is the game's only
# tutorial: what is broken, what each repair is made of, and where that comes
# from -- ticked off as you do it. Once she flies it turns into what a ship's
# computer is for: how she is doing, where you have been, and where you can go.

var _ship_panel: Control
var _ship_panel_ship: Ship
## The journal page, while it is open.
var _journal_panel: Panel
var _ship_panel_body: Control = null
var _ship_panel_sig := ""
var _ship_panel_t := 0.0


## Right-clicking the nose of a ship you are not flying.
func _try_ship_computer() -> bool:
	if piloting:
		return false
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false) or tgt.get("kind", "") != "ship":
		return false
	if Blocks.bottom_of(int(tgt.get("id", Blocks.AIR))) != Blocks.COCKPIT:
		return false
	_open_ship_computer(tgt["obj"] as Ship)
	return true


func _open_ship_computer(ship: Ship) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	_close_ship_computer()
	_ship_panel_ship = ship
	_ship_panel = Panel.new()
	_ship_panel.set_anchors_preset(Control.PRESET_CENTER)
	_ship_panel.custom_minimum_size = Vector2(560, 520)
	_ship_panel.size = _ship_panel.custom_minimum_size
	_ship_panel.position = -_ship_panel.size * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.07, 0.09, 0.97)
	sb.border_color = Color(0.3, 0.7, 0.8, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	_ship_panel.add_theme_stylebox_override("panel", sb)
	_ui_layer.add_child(_ship_panel)
	menu_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_ship_panel_sig = ""
	_ship_panel_body = null
	_build_ship_close_button()
	_refresh_ship_computer()
	_fit_panel(_ship_panel)


# --- the screens on the fittings themselves -----------------------------------
#
# The cockpit talks about the whole ship. Right-clicking a scrubber, an engine
# or the warp drive opens that ONE part's own gauge instead: is it powered, what
# is it doing, how much is left in it. None of them take anything, so none of
# them have slots -- they are read, not loaded.

var _sys_panel: Panel = null
var _sys_body: Control = null
var _sys_ship: Ship = null
var _sys_cell := Vector3i.ZERO
var _sys_id := 0
var _sys_sig := ""


## Right-clicking a fitting on a ship.
func _try_ship_fitting() -> bool:
	if piloting:
		return false
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false) or tgt.get("kind", "") != "ship":
		return false
	var id := int(tgt.get("id", Blocks.AIR))
	if not ShipPanels.has_panel(id):
		return false
	var ship := tgt["obj"] as Ship
	if ship == null:
		return false
	_open_fitting_panel(ship, tgt.get("voxel", Vector3i.ZERO) as Vector3i, id)
	return true


func _open_fitting_panel(ship: Ship, cell: Vector3i, id: int) -> void:
	_close_fitting_panel()
	_sys_ship = ship
	_sys_cell = cell
	_sys_id = id
	_sys_panel = Panel.new()
	_sys_panel.set_anchors_preset(Control.PRESET_CENTER)
	_sys_panel.custom_minimum_size = Vector2(500, 430)
	_sys_panel.size = _sys_panel.custom_minimum_size
	_sys_panel.position = -_sys_panel.size * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.07, 0.09, 0.97)
	sb.border_color = Color(0.3, 0.7, 0.8, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	_sys_panel.add_theme_stylebox_override("panel", sb)
	_ui_layer.add_child(_sys_panel)
	menu_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Audio.ui("ui_open")
	# Built once, outside everything the refresh throws away, for the same
	# reason the ship computer's is: a button freed between your press and your
	# release does nothing.
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(120, 34)
	close.position = Vector2(20, _sys_panel.custom_minimum_size.y - 48)
	close.mouse_entered.connect(func(): Audio.ui("ui_hover"))
	close.pressed.connect(func(): Audio.ui("ui_back"))
	close.pressed.connect(_close_fitting_panel)
	_sys_panel.add_child(close)
	var title := Label.new()
	title.text = ShipPanels.title_of(id)
	title.position = Vector2(20, 14)
	title.add_theme_font_size_override("font_size", 22)
	title.modulate = Color(0.55, 0.9, 1.0)
	_sys_panel.add_child(title)
	_sys_sig = ""
	_refresh_fitting_panel()
	_fit_panel(_sys_panel)


func _close_fitting_panel() -> void:
	if _sys_panel != null:
		_sys_panel.queue_free()
		_sys_panel = null
	_sys_body = null
	_sys_ship = null
	_sys_sig = ""
	if not (inv_open or book_open or _station_open != null or _ship_panel != null):
		menu_open = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Redrawn only when the numbers have actually moved, so the gauges keep up
## without the panel flickering out from under the cursor.
func _refresh_fitting_panel() -> void:
	if _sys_panel == null or _sys_ship == null or not is_instance_valid(_sys_ship):
		_close_fitting_panel()
		return
	# Broken off the ship while you were looking at it.
	if int(_sys_ship.blocks.get(_sys_cell, Blocks.AIR)) != _sys_id:
		_close_fitting_panel()
		return
	var sig := ShipPanels.signature(_sys_ship, _sys_cell, _sys_id)
	if _sys_body != null and is_instance_valid(_sys_body) and sig == _sys_sig:
		return
	_sys_sig = sig
	if _sys_body != null and is_instance_valid(_sys_body):
		_sys_body.queue_free()
	_sys_body = ShipPanels.build(_sys_ship, _sys_cell, _sys_id)
	_sys_body.position = Vector2(20, 52)
	_sys_panel.add_child(_sys_body)


func _close_ship_computer() -> void:
	if _ship_panel != null:
		_ship_panel.queue_free()
		_ship_panel = null
	_ship_panel_ship = null
	_ship_panel_body = null
	_ship_panel_sig = ""
	menu_open = false
	if not (inv_open or book_open or _station_open != null):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Redrawn rather than updated: it is a dozen labels, and a screen that is
## rebuilt cannot disagree with the ship it is describing.
func _refresh_ship_computer() -> void:
	if _ship_panel == null or _ship_panel_ship == null or not is_instance_valid(_ship_panel_ship):
		_close_ship_computer()
		return
	var ship := _ship_panel_ship
	var flies := ShipComputer.flightworthy(ship)
	# Only redraw when there is something different to say. This screen is
	# refreshed every three quarters of a second so it keeps up with repairs,
	# and it used to rebuild itself every time -- including the Close button.
	# Pressing a button that is freed between your press and your release does
	# nothing, and a freshly built button under a cursor that has not moved is
	# not hovered, so the click had to land in the gap between rebuilds. That is
	# the "it only works if I move the mouse first" you were hitting.
	var sig := _ship_screen_signature(ship, flies)
	if _ship_panel_body != null and is_instance_valid(_ship_panel_body) and sig == _ship_panel_sig:
		return
	_ship_panel_sig = sig
	if _ship_panel_body != null and is_instance_valid(_ship_panel_body):
		_ship_panel_body.queue_free()
	var vb := VBoxContainer.new()
	_ship_panel_body = vb
	vb.position = Vector2(22, 18)
	vb.custom_minimum_size = Vector2(516, 0)
	vb.add_theme_constant_override("separation", 8)
	_ship_panel.add_child(vb)
	var title := Label.new()
	title.text = "SHIP'S COMPUTER"
	title.add_theme_font_size_override("font_size", 22)
	title.modulate = Color(0.55, 0.9, 1.0)
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "systems check" if not flies else "all systems nominal"
	sub.add_theme_font_size_override("font_size", 14)
	sub.modulate = Color(1, 1, 1, 0.55)
	vb.add_child(sub)
	vb.add_child(_gap(6))
	if not flies:
		_draw_repair_screen(vb, ship)
	else:
		_draw_flight_screen(vb, ship)


## What the screen currently SAYS, as one string. Two refreshes that would draw
## the same thing do not redraw it.
func _ship_screen_signature(ship: Ship, flies: bool) -> String:
	var parts: Array = ["1" if flies else "0"]
	if flies:
		parts.append_array(ShipComputer.status_lines(ship))
		parts.append(str(ship.ship_log.size()))
	else:
		for it in ShipComputer.checklist(ship):
			var item: ShipComputer.Item = it
			parts.append("%s|%s|%s" % [item.name, "1" if item.done else "0", item.detail])
	return "
".join(PackedStringArray(parts))


## The Close button is built ONCE, with the panel, and lives outside everything
## the refresh throws away. Whatever the screen is saying, the way out of it is
## always the same button that was there a moment ago.
func _build_ship_close_button() -> void:
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(120, 34)
	# Plain top-left offsets. With a BOTTOM_LEFT preset the position is measured
	# from the bottom edge, which put it a whole panel's height below the panel.
	close.position = Vector2(22, _ship_panel.custom_minimum_size.y - 50)
	close.mouse_entered.connect(func(): Audio.ui("ui_hover"))
	close.pressed.connect(func(): Audio.ui("ui_back"))
	close.pressed.connect(_close_ship_computer)
	_ship_panel.add_child(close)


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


## The checklist, and under it the one thing worth doing next.
func _draw_repair_screen(vb: VBoxContainer, ship: Ship) -> void:
	var ghosts := _ghosts_for(ship)
	for it in ShipComputer.checklist(ship):
		var item: ShipComputer.Item = it
		# The whole row is a button. Clicking it marks that job on the hull --
		# blue outlines in the holes for the plating, a turning hologram over
		# the mount for a part -- and clicking it again takes them away. Nothing
		# is shown on the ship until you ask for it here.
		var row := Button.new()
		row.flat = true
		row.custom_minimum_size = Vector2(500, 30)
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var on: bool = ghosts != null and ghosts.is_showing(item.name)
		row.text = "%s  %-18s %s%s" % ["OK " if item.done else "-- ", item.name,
			item.detail, "      [showing on the ship]" if on else ""]
		row.modulate = Color(0.55, 0.9, 1.0) if item.done else Color(1, 0.84, 0.66)
		if on:
			row.modulate = Color(0.45, 0.85, 1.0)
		row.tooltip_text = "Click to mark this on the ship" if not on 			else "Click to stop marking this"
		row.pressed.connect(_toggle_repair_ghost.bind(item.name))
		vb.add_child(row)

	vb.add_child(_gap(8))
	var next := Label.new()
	next.text = ShipComputer.next_step(ship)
	next.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	next.custom_minimum_size = Vector2(500, 0)
	next.add_theme_font_size_override("font_size", 15)
	next.modulate = Color(0.75, 0.95, 1.0)
	vb.add_child(next)


## Once she flies: how she is doing, where you have been, and where you can go.
func _draw_flight_screen(vb: VBoxContainer, ship: Ship) -> void:
	for line in ShipComputer.status_lines(ship):
		var l := Label.new()
		l.text = str(line)
		l.add_theme_font_size_override("font_size", 16)
		vb.add_child(l)
	vb.add_child(_gap(6))
	# Where you could go. Nearby planets always; everything else once there is
	# a warp drive aboard to reach it with.
	var head := Label.new()
	head.text = "NEARBY"
	head.add_theme_font_size_override("font_size", 14)
	head.modulate = Color(0.55, 0.9, 1.0)
	vb.add_child(head)
	if world != null:
		var here := ship.global_position
		var rows: Array = []
		for p in world.planets:
			rows.append([(p as Planet).planet_name, here.distance_to((p as Planet).global_position)])
		rows.sort_custom(func(a, b): return float(a[1]) < float(b[1]))
		for i in mini(rows.size(), 5):
			var l2 := Label.new()
			l2.text = "  %s   %.1f km" % [str(rows[i][0]), float(rows[i][1]) / 1000.0]
			l2.add_theme_font_size_override("font_size", 15)
			l2.modulate = Color(1, 1, 1, 0.85)
			vb.add_child(l2)
	var st: Dictionary = ship.get_status()
	if bool(st.get("warp_drive", false)):
		var b := Button.new()
		b.text = "Star map"
		b.custom_minimum_size = Vector2(160, 32)
		b.mouse_entered.connect(func(): Audio.ui("ui_hover"))
		b.pressed.connect(func():
			Audio.ui("ui_click")
			_close_ship_computer()
			_try_open_starmap())
		vb.add_child(b)
	else:
		var note := Label.new()
		note.text = "A warp drive would put the other systems in reach."
		note.add_theme_font_size_override("font_size", 14)
		note.modulate = Color(1, 1, 1, 0.5)
		vb.add_child(note)
	if not ship.ship_log.is_empty():
		vb.add_child(_gap(6))
		var lh := Label.new()
		lh.text = "LOG"
		lh.add_theme_font_size_override("font_size", 14)
		lh.modulate = Color(0.55, 0.9, 1.0)
		vb.add_child(lh)
		var start: int = maxi(ship.ship_log.size() - 4, 0)
		for i in range(start, ship.ship_log.size()):
			var le := Label.new()
			le.text = "  " + str(ship.ship_log[i])
			le.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			le.custom_minimum_size = Vector2(500, 0)
			le.add_theme_font_size_override("font_size", 14)
			le.modulate = Color(1, 1, 1, 0.65)
			vb.add_child(le)


## Watch the wreck being put right: each line that goes green is worth saying
## out loud, and the moment she will fly is worth more than that.
func _watch_repairs(delta: float) -> void:
	if world == null:
		return
	_ship_panel_t -= delta
	if _ship_panel_t > 0.0:
		return
	_ship_panel_t = 0.75
	if _ship_panel != null:
		_refresh_ship_computer()
	if _sys_panel != null:
		_refresh_fitting_panel()
	for sh in world._ships:
		var ship: Ship = sh
		if not is_instance_valid(ship) or ship.wreck_missing == null:
			continue
		if ship.ship_log.is_empty():
			continue     # not the wreck this world started in
		var done_now: Array = []
		for it in ShipComputer.checklist(ship):
			var item: ShipComputer.Item = it
			if item.done:
				done_now.append(item.name)
		var seen: Array = ship.ship_log
		for name in done_now:
			var line := "%s: restored." % name
			if not seen.has(line):
				ship.ship_log.append(line)
				_toast("Ship's computer — %s restored" % str(name).to_lower())
		if ShipComputer.flightworthy(ship) and not seen.has("The ship flies."):
			ship.ship_log.append("The ship flies.")
			_toast("Ship's computer: all systems nominal. The ship will fly.")


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
			_fit_panel(_book_panel)
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
		mats.visible = str(rec["diagram"]) == "" and not rec.has("def")
		mats.text = needs
		mats.add_theme_font_size_override("font_size", 12)
		mats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		mats.custom_minimum_size = Vector2(548, 0)
		mats.modulate = Color(1, 1, 1, 0.75)
		vb.add_child(mats)
		if rec.has("grow_from"):
			# An upgrade: what it grows out of, then the same picture a build
			# gets -- here, the station with its materials packed round it.
			var from_name := Blocks.name_of(int(rec["grow_from"]))
			where.text = "Upgrade a %s" % from_name
			vb.add_child(_pattern_view(rec["def"],
				"Pack these anywhere touching a %s -- corners count -- then right-click it and choose %s." % [
					from_name, name]))
		elif rec.has("def"):
			# Multiblocks are the reason this screen exists. Shown as a picture
			# of the finished build, each layer drawn out with the materials'
			# own icons, and a key in words -- not letters to decode.
			vb.add_child(_pattern_view(rec["def"]))
		elif str(rec["diagram"]) != "":
			var dg := Label.new()
			dg.text = str(rec["diagram"])
			dg.add_theme_font_size_override("font_size", 12)
			dg.add_theme_color_override("font_color", Color(0.98, 0.86, 0.58))
			vb.add_child(dg)
		_book_vbox.add_child(row)
	_book_empty.text = "" if shown > 0 else "Nothing matches that."
	_book_empty.visible = shown == 0


## A build pattern drawn out for the Recipe Book: the finished thing in 3D on
## the left; on the right, each layer from the ground up as a grid of the
## materials' icons, and a key saying what each one is.
func _pattern_view(def: Dictionary, how_text: String = "") -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	# The finished build as a live model, turning, and turned by dragging.
	hb.add_child(PatternView.new(def))

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	hb.add_child(right)
	var planet := world.nearest_planet(global_position) if world != null else null
	# Blocky patterns are shown a block to a square; fine ones an eighth.
	var step := 2 if (not def.has("legend") and Blocks.part_pattern_is_blocky(def)) else 1
	var layers: Array = def["layers"]
	var grids := HBoxContainer.new()
	grids.add_theme_constant_override("separation", 16)
	right.add_child(grids)
	var count := int(ceil(layers.size() / float(step)))
	var y := 0
	while y < layers.size():
		var li := y / step
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 3)
		var cap := Label.new()
		cap.text = "Layer %d" % (li + 1)
		if count > 1 and li == 0:
			cap.text += " (bottom)"
		elif count > 1 and li == count - 1:
			cap.text += " (top)"
		cap.add_theme_font_size_override("font_size", 11)
		cap.modulate = Color(0.62, 0.80, 0.95)
		col.add_child(cap)
		var grid := GridContainer.new()
		var rows: Array = layers[y]
		var width := int(ceil((rows[0] as String).length() / float(step)))
		grid.columns = maxi(width, 1)
		grid.add_theme_constant_override("h_separation", 2)
		grid.add_theme_constant_override("v_separation", 2)
		var z := 0
		while z < rows.size():
			var row: String = rows[z]
			var x := 0
			while x < row.length():
				grid.add_child(_pattern_cell(def, row[x], planet))
				x += step
			z += step
		col.add_child(grid)
		grids.add_child(col)
		y += step
	var seen := Label.new()
	seen.text = "Each layer seen from above."
	seen.add_theme_font_size_override("font_size", 10)
	seen.modulate = Color(1, 1, 1, 0.45)
	right.add_child(seen)

	# The key, in pictures and words.
	var key := HFlowContainer.new()
	key.add_theme_constant_override("h_separation", 12)
	key.custom_minimum_size = Vector2(360, 0)
	for ch in Blocks.pattern_letters(def):
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 4)
		item.add_child(_pattern_cell(def, ch, planet))
		var lab := Label.new()
		lab.text = Blocks.pattern_letter_label(def, ch)
		lab.add_theme_font_size_override("font_size", 12)
		item.add_child(lab)
		key.add_child(item)
	right.add_child(key)
	var how := Label.new()
	how.text = how_text if how_text != "" else "Build it, then right-click it to confirm."
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.custom_minimum_size = Vector2(340, 0)
	how.add_theme_font_size_override("font_size", 11)
	how.modulate = Color(0.98, 0.86, 0.58)
	right.add_child(how)
	return hb


## One square of a pattern grid: the material's icon on its colour, or a faint
## outline where the cell is left empty.
func _pattern_cell(def: Dictionary, ch: String, planet: Planet) -> Control:
	const CELL := 22
	var id := Blocks.pattern_letter_id(def, ch)
	var box := ColorRect.new()
	box.custom_minimum_size = Vector2(CELL, CELL)
	if id == Blocks.AIR:
		box.color = Color(1, 1, 1, 0.06)
		return box
	var c := Blocks.color_of(id)
	box.color = Color(c.r, c.g, c.b, 0.35)
	var icon := TextureRect.new()
	icon.texture = ItemIcon.of(id, c, planet)
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icon)
	box.tooltip_text = Blocks.pattern_letter_label(def, ch)
	return box


func _toggle_inventory() -> void:
	inv_open = not inv_open
	if inv_open and _char_preview != null:
		var main := get_tree().current_scene
		if main != null and main.has_method("current_skin_image"):
			_char_preview.refresh_skin(main.call("current_skin_image"))
	if _inv_panel != null:
		_inv_panel.visible = inv_open
		if inv_open:
			_fit_panel(_inv_panel)
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
	if in_bed:
		# No ceiling probe while lying down: the thing directly over you is
		# often the roof you built over the bed, and letting it push the eye
		# further down from an already-low position looks like sinking.
		_camera.position.y = move_toward(_camera.position.y, BED_EYE, delta * 1.8)
		if _bed_settle > 0.0:
			_bed_settle = maxf(_bed_settle - delta, 0.0)
			_pitch = move_toward(_pitch, BED_PITCH, delta * 2.2)
			_camera.rotation.x = _pitch
			if _bed_yaw_to != Vector3.ZERO:
				# Turned a little each frame toward lying along it, over the
				# same half second as the tip back, so the two read as one
				# movement of getting into bed.
				var up_now := global_transform.basis.y.normalized()
				var fwd := -global_transform.basis.z
				var err := fwd.signed_angle_to(_bed_yaw_to, up_now)
				if absf(err) < 0.01:
					_bed_yaw_to = Vector3.ZERO
				else:
					rotate(up_now, clampf(err, -delta * 4.0, delta * 4.0))
		return
	var want := EYE_HEIGHT * (CROUCH_EYE_MULT if crouching else 1.0)
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
			# A ceiling overrules a crouch in one direction only: it can push the
			# eye further down, never hold it up.
			want = minf(want, clampf(d - EYE_CLEARANCE, 0.0, EYE_HEIGHT))
	# Crouching eases both ways so it reads as a movement; a ceiling still drops
	# the eye instantly, because being late there is what puts it in the block.
	var ceiling_forced := want < _camera.position.y and not crouching
	if ceiling_forced:
		_camera.position.y = want
	else:
		_camera.position.y = move_toward(_camera.position.y, want, delta * 2.2)


func _physics_process(delta: float) -> void:
	if _ring != null:
		_paint_ring()
	_sync_held_station()
	_watch_repairs(delta)
	if _place_kind != Blocks.AIR:
		_update_place_ghost()
	_update_eye_clearance(delta)
	_tick_web(delta)
	_tick_dread(delta)
	_tick_held_anim(delta)
	if _trail != null:
		_trail.emitting = velocity.length() > 0.8
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
		crouching = false
		_pilot_physics(delta)
		_update_ui()
		return
	if seated != null:
		_sit_physics(delta)
		_process_mining(delta)
		_update_ui()
		return
	if aboard != null:
		if not is_instance_valid(aboard):
			aboard = null
		else:
			# Walk the interior in the ship's local frame (decoupled from how the
			# ship moves through space -- rock solid at any speed/orientation).
			grounded = true
			crouching = false
			_walk_interior(delta, aboard)
			_process_mining(delta)
			_update_ui()
			return
	var g := world.gravity_at(global_position) if world else Vector3(0, -9.8, 0)
	var up := -g.normalized() if g.length() > 0.01 else Vector3.UP
	var in_water := _in_water(global_position + up * 0.5) or _in_water(global_position - up * 0.8)
	_water_fx(delta, up, in_water)
	if in_water:
		# align to the snapped axis (like walking) so you stay upright vs gravity
		var sup := _face_up(g)
		crouching = false
		_swim(delta, sup, g.length())
	else:
		grounded = g.length() > FLIGHT_THRESHOLD
		if grounded:
			_walk(delta, _face_up(g), g.length())
		else:
			crouching = false
			_process_float(delta)
	_process_mining(delta)
	_update_ui()


# --- piloting -----------------------------------------------------------------

func _pilot_physics(delta: float) -> void:
	if not is_instance_valid(piloting):
		_exit_pilot()
		return
	var ascend := 0.0
	if not menu_open and not ui_typing and key_down("jump"): ascend += 1.0
	if key_down("crouch"): ascend -= 1.0
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
		if not is_instance_valid(aboard) or _parked(aboard) or not aboard.contains(global_position):
			_unboard()
	elif world != null:
		var s := world.nearest_ship(global_position)
		if s != null and not _parked(s) and s.contains(global_position):
			_board(s, false)


## A ship sitting on the ground is just a building: you walk through it on the
## planet's own gravity, colliding with its hull like any other wall. Interior
## mode exists so a ship can move UNDER you without throwing you about, and its
## frame change costs a camera snap -- so paying that while stood in a parked
## wreck is all cost and no benefit. Worse, `contains` wants a ceiling overhead,
## which a wreck with a hole in its roof does not have everywhere, so a walk
## across the cabin used to board and unboard you a dozen times, snapping the
## view on each one.
func _parked(ship: Ship) -> bool:
	return ship.landed and not ship.flying


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
	rotation.y -= _look.x * MOUSE_SENS * look_sensitivity   # yaw around the ship's up
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS * look_sensitivity * _look_sign(), -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var input := _move_input()
	var yaw := rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var wish := right * input.x + fwd * input.y
	if wish.length() > 0.001:
		wish = wish.normalized()
	var disp := wish * WALK_SPEED * (STARVE_SPEED_MULT if hunger <= 0.0 else 1.0) * _web_mult() * delta

	if _interior_floor and key_down("jump") and _stuck_t <= 0.0:
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
	# bottom_of, because a door packs its facing and hinge into the id and so
	# never equals the bare constant (see Ship._rebuild_collision).
	return ship.blocks.has(cell) 		and Blocks.bottom_of(int(ship.blocks[cell])) != Blocks.DOOR_OPEN


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


## Trim a step that would take you off the edge.
##
## Each axis is tested on its own, not just the pair: walking diagonally at a
## corner, the move as a whole leaves the ledge while one of its halves does
## not, and stopping dead there feels like catching on nothing. Keeping the half
## that still has ground under it is what lets you run a wall edge.
func _hold_the_ledge(horiz: Vector3, up: Vector3, delta: float) -> Vector3:
	if horiz.length_squared() < 0.0001:
		return horiz
	if _ground_ahead(horiz * delta, up):
		return horiz
	# Split along the two directions you are actually steering in.
	var fwd := -global_transform.basis.z
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := up.cross(fwd).normalized()
	var a := fwd * horiz.dot(fwd)
	var b := right * horiz.dot(right)
	if a.length_squared() > 0.0001 and _ground_ahead(a * delta, up):
		return a
	if b.length_squared() > 0.0001 and _ground_ahead(b * delta, up):
		return b
	return Vector3.ZERO


## Is there something to stand on a step from here?
##
## Probed a little PAST where the step lands, because the check has to fail
## while there is still floor under your feet -- testing the exact landing spot
## lets you creep out to the very edge and then stop with your heels over
## nothing, which reads as a bug rather than as caution.
func _ground_ahead(step: Vector3, up: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var lead: Vector3 = step
	if lead.length() > 0.0001:
		lead = lead.normalized() * maxf(lead.length(), CROUCH_LOOKAHEAD)
	var from: Vector3 = global_position + lead
	var q := PhysicsRayQueryParameters3D.create(from, from - up * CROUCH_PROBE)
	q.exclude = [get_rid()]
	q.collide_with_areas = false
	return not space.intersect_ray(q).is_empty()


func _walk(delta: float, up: Vector3, gmag: float) -> void:
	_align_up(up, delta)

	# Coming round: the head lift, which also ignores look input while it runs.
	if _tick_rouse():
		pass

	# Yaw around local up; pitch the camera.
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS * look_sensitivity)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS * look_sensitivity * _look_sign(), -1.45, 1.45)
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
	var horiz := wish * WALK_SPEED * (STARVE_SPEED_MULT if hunger <= 0.0 else 1.0) * _web_mult()

	v_up += -gmag * delta  # gravity pulls along -up (the snapped down axis)

	# Coyote time: the ground is remembered for a moment after it is gone.
	if is_on_floor():
		_coyote = COYOTE_TIME
	else:
		_coyote = maxf(_coyote - delta, 0.0)
	if is_on_floor() and v_up < 0.0:
		v_up = 0.0
	# Jump buffering: the PRESS is remembered, not just the hold, so a tap made
	# a moment before landing is still there when the ground arrives.
	var held := not menu_open and not ui_typing and key_down("jump")
	if held and not _jump_was_held:
		_jump_buffer = JUMP_BUFFER
	_jump_was_held = held
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	# Stuck fast: jumping is struggling, and every press works you a bit freer.
	if _stuck_t > 0.0:
		if held and not _jump_was_held_web:
			_stuck_t -= 0.3
		_jump_was_held_web = held
		_jump_buffer = 0.0
	elif _coyote > 0.0 and v_up <= 0.0 and (held or _jump_buffer > 0.0):
		v_up = JUMP_SPEED * lerpf(1.0, 0.55, _web / WEB_MAX)
		# One jump per departure, not one per frame in the air, and the buffered
		# press is spent rather than left to fire again on the next landing.
		_coyote = 0.0
		_jump_buffer = 0.0
	# No thrust once your feet leave the ground: a jump is a jump. There is no
	# jetpack in the game yet, and being able to hold jump and climb was standing
	# in for one -- if you are down a hole, the way out is to build your way out.

	# Crouching: hold shift and you will not walk off what you are standing on.
	crouching = not menu_open and not ui_typing and key_down("crouch") and is_on_floor()
	if crouching:
		horiz = _hold_the_ledge(horiz, up, delta) * CROUCH_SPEED_MULT

	if not is_on_floor():
		var flat_now := velocity - up * velocity.dot(up)
		horiz = flat_now.lerp(horiz, clampf(delta * AIR_CONTROL, 0.0, 1.0))
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
	# Room to rise at all? The test below starts from the raised position, and
	# under a ceiling that position is already inside it -- where a move is
	# reported as unblocked, because nothing is in the way of a body that is
	# already overlapping. That read as a ledge, and lifted you into whatever
	# was over your head every frame you walked into a wall beneath it.
	if test_move(xf, up * STEP_HEIGHT):
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
	var tb := Time.get_ticks_usec()
	_update_base(delta)
	WorldManager.perf_mark("base tick", tb)
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
	elif in_bed and air and oxygen > 0.0 and health < MAX_HEALTH:
		# No hunger requirement: resting is what you do BECAUSE you are in a bad
		# way, and a bed that refused to help the starving would be no use on
		# the night it is most needed.
		health = minf(health + BED_REGEN * delta, MAX_HEALTH)
	elif air and oxygen > 0.0 and health < MAX_HEALTH and hunger >= HUNGER_REGEN_MIN:
		health = minf(health + HEALTH_REGEN * delta, MAX_HEALTH)
	# Lie down at dusk and the question comes to you when the sun actually goes.
	if in_bed and _bed_panel == null and _bed_planet_now != null 			and _bed_planet_now.is_night():
		_open_sleep_prompt(_bed_planet_now)
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
	_get_up()
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
	var woke_in_bed := false
	if world != null and bed_planet != "":
		for p in world.planets:
			if p.planet_name == bed_planet:
				global_position = bed_pos
				woke_in_bed = true
				break
		if not woke_in_bed:
			# The bed is on a world that is not in this system any more. Say so
			# rather than silently sending them home wondering where it went.
			bed_planet = ""
			_toast("Your bed is somewhere you cannot get back to")
	if not woke_in_bed and world != null and not world.planets.is_empty():
		global_position = world.planets[0].find_spawn_point(Vector3.UP)
	# Hold still until there is ground. Chunks stream in asynchronously, so for
	# the first moments after a respawn there is nothing under you and gravity
	# drops you straight through the world.
	_await_ground = 6.0
	_toast("You blacked out — woke up in your bed" if woke_in_bed
		else "You blacked out — respawned at home")


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
	# How DEEP, not merely whether there is water here. A cell holding an eighth
	# of a cell of water is a wet floor, and starting to swim in one -- which is
	# what asking only for the block id does -- means a spill across a plain
	# turns into a lake you cannot walk over.
	var v := p.world_to_voxel(wp)
	if p.get_id(v) != Blocks.WATER:
		return false
	var fill := p.water_fill(v)
	if fill >= 0.999:
		return true
	# Inside the cell: water fills it from the cell's DOWN face upward, which is
	# what the mesher draws, so how far up the point sits is what decides whether
	# it is under the surface. Measured along the cell's own up axis, because on
	# the far side of a planet that is a different direction entirely.
	var up := p._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	var l := p.to_local(wp) - Vector3(v) - Vector3(0.5, 0.5, 0.5)
	return l.dot(up) + 0.5 <= fill


# Buoyant, draggy movement: swim relative to the camera, hold Space to rise / Shift
# to dive, and float gently up to the surface when you let go.
func _swim(delta: float, up: Vector3, gmag: float) -> void:
	grounded = false
	_align_up(up, delta)
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS * look_sensitivity * _look_sign(), -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var cam := _camera.global_transform.basis
	var input := _move_input()
	var wish := (-cam.z) * input.y + cam.x * input.x  # swim toward where you look
	var desired := Vector3.ZERO
	if wish.length() > 0.01:
		desired = wish.normalized() * SWIM_SPEED
	var vy := 0.0
	var jump := not menu_open and not ui_typing and key_down("jump")
	if jump: vy += 1.0
	if key_down("crouch"): vy -= 1.0
	if vy != 0.0:
		desired += up * vy * SWIM_SPEED
	elif _in_water(global_position + up * 0.5):
		desired += up * SWIM_BUOY  # submerged & idle: bob up to the surface

	# Scrambling out. Swimming up only ever lifts you until your feet reach the
	# surface -- past that you are out of the water and gravity has you -- and a
	# bank is nearly always a block higher than the water beside it. So you
	# could tread water against a one-block ledge for ever. Surfaced, pressing
	# into something and holding jump is a real jump instead: out and onto it,
	# the way climbing out of a pool works.
	_water_leap_t = maxf(_water_leap_t - delta, 0.0)
	var surfaced := not _in_water(global_position + up * 0.5)
	if _water_leap_t <= 0.0 and jump and surfaced and is_on_wall() \
			and velocity.dot(up) < JUMP_SPEED * 0.5:
		velocity += up * (JUMP_SPEED - velocity.dot(up))
		_water_leap_t = WATER_LEAP_TIME
		_splash(global_position + up * 0.3, 0.8)

	if _water_leap_t > 0.0:
		# Mid-leap the water does not get to drag you back: the climb is left
		# to gravity, and only the sideways part eases toward where you steer.
		var v_up := velocity.dot(up) - gmag * delta
		var flat := velocity - up * velocity.dot(up)
		var flat_want := desired - up * desired.dot(up)
		velocity = flat.lerp(flat_want, clampf(delta * SWIM_ACCEL, 0.0, 1.0)) + up * v_up
	else:
		velocity = velocity.lerp(desired, clampf(delta * SWIM_ACCEL, 0.0, 1.0))
	up_direction = up
	move_and_slide()


# --- WATER EFFECTS ------------------------------------------------------------

## How long a scramble out of the water belongs to gravity rather than to the
## water. Long enough to clear the surface; after that you are out anyway.
const WATER_LEAP_TIME := 0.45
## Least time between two small splashes. A big one ignores it: jumping in
## while the last bob's ripple is still going should still make a splash.
const SPLASH_GAP := 0.3

## True while the CAMERA is under water. The environment reads it to turn its
## fog into the water; the overlay below reads it for everything else.
var underwater := false
var _water_leap_t := 0.0
var _chest_wet := false
var _splash_cool := 0.0
var _wake_t := 0.0
var _uw_layer: CanvasLayer
var _uw_mat: ShaderMaterial
var _uw_strength := 0.0
static var _drop_mat: StandardMaterial3D
static var _drop_mesh: BoxMesh


## Splashes, and the view from under the surface.
func _water_fx(delta: float, up: Vector3, in_water: bool) -> void:
	_splash_cool = maxf(_splash_cool - delta, 0.0)
	var chest := _in_water(global_position + up * 0.5)
	var v_up := velocity.dot(up)
	# Crossing the surface, either way: falling in, bobbing up, and every bob
	# after that. How hard is how fast you were going through it.
	if chest != _chest_wet and absf(v_up) > 0.5:
		_splash(global_position + up * 0.5, clampf(absf(v_up) / 9.0, 0.12, 1.0))
	_chest_wet = chest
	# Swimming along the top: a small wash off the front every so often.
	if in_water and not chest:
		var flat := velocity - up * v_up
		_wake_t -= delta
		if flat.length() > 2.0 and _wake_t <= 0.0:
			_wake_t = 0.35
			_splash(global_position + up * 0.45 + flat.normalized() * 0.45, 0.15)

	# The overlay eases in and out rather than snapping, so bobbing at the
	# surface flickers softly instead of strobing.
	underwater = _camera != null and _in_water(_camera.global_position)
	_uw_strength = move_toward(_uw_strength, 1.0 if underwater else 0.0, delta * 6.0)
	if _uw_strength <= 0.0 and _uw_layer == null:
		return
	if _uw_layer == null:
		_uw_layer = CanvasLayer.new()
		# Under the HUD (layer 1): the water should colour the world, not the
		# health bar.
		_uw_layer.layer = 0
		add_child(_uw_layer)
		var r := ColorRect.new()
		r.set_anchors_preset(Control.PRESET_FULL_RECT)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_uw_mat = ShaderMaterial.new()
		_uw_mat.shader = load("res://shaders/underwater.gdshader")
		r.material = _uw_mat
		_uw_layer.add_child(r)
	_uw_layer.visible = _uw_strength > 0.0
	_uw_mat.set_shader_parameter("strength", _uw_strength)
	var p := world.nearest_planet(global_position) if world != null else null
	if p != null:
		var t := Player.water_wash(p)
		_uw_mat.set_shader_parameter("water_color", Vector3(t.r, t.g, t.b))


## The water's hue as something safe to tint a whole view with: full
## brightness, saturation capped. A world's water colour is rolled freely and
## drawn at half opacity over a lit sea bed, so what it LOOKS like from the bank
## is far paler than its raw value -- used straight, a water that read as grey-
## blue from above turned the view under it red.
static func water_wash(p: Planet) -> Color:
	var wc: Color = p.color_of(Blocks.WATER)
	return Color.from_hsv(wc.h, minf(wc.s, 0.35), 1.0)


## Throw up a burst of droplets where the body met the water. Little cubes
## rather than soft dots -- everything else in the world is made of blocks, and
## so is its water.
func _splash(pos: Vector3, strength: float) -> void:
	if strength < 0.5 and _splash_cool > 0.0:
		return
	_splash_cool = SPLASH_GAP
	var host := get_tree().current_scene
	if host == null:
		return
	var up := -world.gravity_at(pos).normalized() if world != null else Vector3.UP
	if up.length() < 0.5:
		up = global_transform.basis.y
	if _drop_mesh == null:
		_drop_mesh = BoxMesh.new()
		_drop_mesh.size = Vector3.ONE * 0.07
		_drop_mat = StandardMaterial3D.new()
		_drop_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_drop_mat.vertex_color_use_as_albedo = true
		_drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_drop_mesh.material = _drop_mat
	var wc := Color(0.75, 0.88, 1.0)
	var p := world.nearest_planet(pos) if world != null else null
	if p != null:
		wc = p.color_of(Blocks.WATER).lerp(Color.WHITE, 0.6)
	var ps := CPUParticles3D.new()
	ps.mesh = _drop_mesh
	ps.one_shot = true
	ps.explosiveness = 0.92
	ps.amount = int(lerpf(8.0, 42.0, strength))
	ps.lifetime = lerpf(0.4, 0.95, strength)
	# Emitted up out of the surface in the node's own frame, which is turned to
	# face the planet's up below; gravity is in the world's frame, so it is
	# simply the real down.
	ps.direction = Vector3.UP
	ps.spread = lerpf(40.0, 28.0, strength)
	ps.initial_velocity_min = lerpf(1.2, 3.0, strength)
	ps.initial_velocity_max = lerpf(2.6, 6.5, strength)
	ps.gravity = -up * 11.0
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	ps.emission_sphere_radius = lerpf(0.2, 0.55, strength)
	ps.scale_amount_min = lerpf(0.6, 0.9, strength)
	ps.scale_amount_max = lerpf(1.0, 1.8, strength)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(wc.r, wc.g, wc.b, 0.9))
	ramp.set_color(1, Color(wc.r, wc.g, wc.b, 0.0))
	ps.color_ramp = ramp
	# Emitting only once it is in place -- see _emit_at.
	ps.emitting = false
	host.add_child(ps)
	var x := up.cross(Vector3(0.31, 0.12, 0.94)).normalized()
	ps.global_transform = Transform3D(Basis(x, up, x.cross(up)), pos)
	ps.set_deferred("emitting", true)
	get_tree().create_timer(ps.lifetime + 0.3).timeout.connect(ps.queue_free)
	Audio.at("splash_big" if strength >= 0.5 else "splash", pos)


# --- FLOAT --------------------------------------------------------------------

func _process_float(delta: float) -> void:
	# Free look: yaw around body up, pitch the camera. No forced orientation.
	if _look.x != 0.0:
		rotate(global_transform.basis.y, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS * look_sensitivity * _look_sign(), -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var input := _move_input()
	var cam := _camera.global_transform.basis
	var fwd := -cam.z
	var right := cam.x
	var up := cam.y
	var vertical := 0.0
	if not menu_open and not ui_typing and key_down("jump"):
		vertical += 1.0
	if key_down("crouch"):
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
## Which face of the world you are standing on, and the body it belongs to.
##
## Remembered rather than worked out fresh, because the answer has to be STICKY
## -- see _face_up.
var _up_axis := Vector3.ZERO
var _up_body: int = 0
## How far past the lip you have to get before the next face is yours. A couple
## of blocks -- just enough that standing exactly on the line does not flicker.
const FACE_LIP := 2.0


## Up, on a cube world, without changing its mind while you dig.
##
## The face is chosen from where you are, but it does not change the instant
## another axis edges ahead. Near an edge the two are within a hair of each
## other, and digging DOWN there moves you closer to the middle along your own
## axis -- which is enough to hand the lead to the neighbour. Gravity would then
## turn ninety degrees because you dug a hole, and the shaft you were standing
## in would become a wall.
##
## Going over the edge is a different motion: it carries you clear along the
## neighbour's axis rather than shortening your own, so it passes the margin
## easily and the face changes as it should.
func _face_up(g: Vector3) -> Vector3:
	if g.length() < 0.01:
		return Vector3.UP
	var planet := world.nearest_planet(global_position) if world != null else null
	if planet == null or not planet.shape_cube:
		_up_axis = Vector3.ZERO
		return -_snap_to_axis(g)
	var body := planet.get_instance_id()
	var rel := global_position - planet.global_position
	if _up_axis == Vector3.ZERO or body != _up_body:
		_up_axis = _snap_to_axis(rel)
		_up_body = body
	_up_axis = _face_axis(rel, planet.radius, _up_axis)
	return _up_axis


## The face a point belongs to, given the face it was on.
##
## Not "whichever axis is biggest", which is the answer that flips: near an edge
## the two are within a hair of each other, and digging DOWN there shortens your
## own axis, which is enough to hand the lead to the neighbour.
##
## A face is a COLUMN, not a wedge. The +Y face of a cube covers every point
## whose other two coordinates are inside the cube's half-width, at any height
## and any depth -- so a shaft sunk a hundred blocks from the lip is still that
## face's shaft, however deep it goes. You are on another face once you are
## outside the column, which is what going over the edge means and what digging
## under one never does. That is exact, and needs no fudge factor to tune.
static func _face_axis(rel: Vector3, radius: float, current: Vector3) -> Vector3:
	var lim := radius + FACE_LIP
	var inside := true
	for a in 3:
		if absf(current[a]) > 0.5:
			continue          # the face's own axis is free to be anything
		if absf(rel[a]) > lim:
			inside = false
	if inside:
		return current
	var ax := absf(rel.x)
	var ay := absf(rel.y)
	var az := absf(rel.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(rel.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(rel.y), 0)
	return Vector3(0, 0, signf(rel.z))


## Which of the four quarters a door placed here should look out of, in the
## order shape_boxes reads them.
func _door_facing(planet: Planet, v: Vector3i) -> int:
	var up := planet._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5))
	var ax := Vector3(1, 0, 0)
	var bx := Vector3(0, 0, 1)
	if absf(up.x) > 0.5:
		ax = Vector3(0, 1, 0)
	elif absf(up.z) > 0.5:
		bx = Vector3(0, 1, 0)
	var look := -_camera.global_transform.basis.z if _camera != null else Vector3.FORWARD
	look = look - up * look.dot(up)
	if look.length_squared() < 0.0001:
		look = ax
	look = look.normalized()
	# The panel hangs on the side you are standing on, so its face is toward
	# you: the quarter that best matches the way BACK to you.
	var dirs := [ax, bx, -ax, -bx]
	var best := 0
	var bd := -2.0
	for i in 4:
		var d: float = (dirs[i] as Vector3).dot(-look)
		if d > bd:
			bd = d
			best = i
	return best


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
	if in_bed:
		# Getting out of bed is just moving. The input that did it is spent on
		# standing up rather than also taking a step, so you do not shuffle off
		# the frame in the same instant.
		if key_down("forward") or key_down("back") or key_down("left") 				or key_down("right") or key_down("jump"):
			_get_up()
			_toast("Up and about")
		return Vector2.ZERO
	var x := 0.0
	var y := 0.0
	if key_down("forward"): y += 1.0
	if key_down("back"): y -= 1.0
	if key_down("right"): x += 1.0
	if key_down("left"): x -= 1.0
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
	# The ray is built once at the longest reach any tool could give, so that it
	# never has to be rebuilt; what it comes back with is then held to the reach
	# you actually have right now.
	if origin.distance_to(hit) > reach:
		return _dda_no_collider()
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
		return _dda(aboard, origin, dir, origin + dir, "ship", reach)
	var planet := world.nearest_planet(origin)
	if planet == null:
		return {}
	return _dda(planet, origin, dir, origin + dir, "planet", reach)


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
	if low == Blocks.CROP:
		# A crop is aimed at only by its small stem, so the tilled ground around
		# it -- where the next seed goes -- can be aimed at past it.
		var cb := _crop_box((obj as Planet)._axis_of(Vector3(v) + Vector3(0.5, 0.5, 0.5)))
		return [[Vector3(v) + (cb[0] as Vector3), Vector3(v) + (cb[1] as Vector3)]]
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


## A crop's target: a small post standing on the ground of its cell, in the
## cell's own 0..1 space. `up` is the way the ground faces there.
const CROP_W := 0.36
const CROP_H := 0.4
static func _crop_box(up: Vector3) -> Array:
	var lo := Vector3.ONE * (0.5 - CROP_W * 0.5)
	var hi := Vector3.ONE * (0.5 + CROP_W * 0.5)
	for a in 3:
		if up[a] > 0.5:
			lo[a] = 0.0
			hi[a] = CROP_H
		elif up[a] < -0.5:
			lo[a] = 1.0 - CROP_H
			hi[a] = 1.0
	return [lo, hi]


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
		elif Blocks.bottom_of(raw) == Blocks.CROP:
			var cb := _crop_box(up)
			lo = cb[0]
			hi = cb[1]
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
## Put a one-shot particle burst at `where` and set it off.
##
## NOT "add it, move it, emit": CPUParticles3D emits a one-shot batch with the
## transform it had before it was moved, so every burst in the game was going
## off at the world's origin -- a kilometre and more under your feet on a
## planet -- and nobody ever saw a spark or a chip of rock. Emission starts on
## the next frame, once the node is where it was put.
func _emit_at(ps: CPUParticles3D, parent: Node, where: Vector3) -> void:
	ps.emitting = false
	parent.add_child(ps)
	ps.global_position = where
	ps.set_deferred("emitting", true)


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
	_emit_at(ps, parent, where)
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
	# A station standing there owns that space even though no block says so.
	if tgt["kind"] == "planet" and world != null and world.station_blocking(
			(obj as Planet).to_global(Vector3(plan.get("voxel", pv)) + Vector3(0.5, 0.5, 0.5))):
		_toast("Something is already standing there")
		return
	if plan.has("part") and tgt["kind"] == "planet":
		world.edit_part(obj as Planet, plan["voxel"], int(plan["part"]), int(plan["value"]))
		_consume_eighth()
		return
	# Some placements land in the cell you're POINTING AT rather than the one
	# beyond it -- a slab stacking onto a slab, or a block replacing tall grass --
	# so they take an early exit before the normal adjacent-cell path.
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
				# Hung to face WHOEVER PUT IT THERE, rather than square to the
				# world -- a door is the one block whose orientation you never
				# want to have to think about.
				var face := _door_facing(obj as Planet, pv)
				world.edit_block(obj as Planet, pv,
					Blocks.door_with(false, face, 0, false))
				world.edit_block(obj as Planet, pv + axis,
					Blocks.door_with(false, face, 0, true))
			else:
				world.edit_block(obj as Planet, pv, placed_value)
			_consume_active()

	elif tgt["kind"] == "ship":
		if obj.to_global(Vector3(pv) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			var props: Dictionary = inv[active_slot].get("props", {})
			if place_id == Blocks.DOOR:
				# A door is two cells tall on a ship exactly as it is on the
				# ground. Placing one cell of it left a lone half in the wall --
				# which the ship's mesher draws as a plain cube, so what you got
				# back for your door was a block.
				var above: Vector3i = pv + Vector3i(0, 1, 0)
				if (obj as Ship).blocks.has(above):
					_toast("No headroom for a door there")
					return
				obj.set_block(pv, Blocks.door_with(false, 0, 0, false), props)
				obj.set_block(above, Blocks.door_with(false, 0, 0, true), props)
			else:
				# crafted ship blocks carry their material stats onto the ship
				obj.set_block(pv, place_id, props)
			_consume_active()


## Hand over a seed for something that grows on this world.
##
## Mostly the plant you just broke; now and then a different one that lives here
## too, which is what stops finding a species being a search for the one bush
## that carries it. Everything green is a slow lottery ticket for everything
## else green nearby.
func _drop_flora_seed(planet: Planet, kind: String, item: int) -> void:
	var sp := _pick_flora(planet, kind)
	if sp.is_empty():
		return          # nothing grows here to have seeded it
	_give_seeds(planet, sp, 1)
	_toast("Found " + _seed_label(sp, planet))


## Which plant a seed from `kind` turns out to be: mostly that one, now and then
## another that grows here too.
func _pick_flora(planet: Planet, kind: String) -> Dictionary:
	var sp: Dictionary = planet.flora_of_kind(kind)
	if randf() < Blocks.CROSS_SEED_CHANCE:
		var other: Dictionary = planet.random_flora(randf())
		if not other.is_empty():
			sp = other
	return sp


## The seed a plant of `kind` would give, as an item not yet in anyone's hands:
## {id, props, src, mat, label}, or empty. For something that DROPS its seed on
## the ground -- a felled tree's leaves -- rather than handing it straight over.
func _roll_flora_seed(planet: Planet, kind: String) -> Dictionary:
	var sp := _pick_flora(planet, kind)
	if sp.is_empty():
		return {}
	var give: int = Blocks.SAPLING if str(sp["kind"]) == "tree" else Blocks.SEEDS
	return {"id": give,
		"props": {"species": str(sp["key"]), "class": planet.planet_class()},
		"src": planet.planet_name,
		"mat": {"name": _seed_label(sp, planet), "color": Blocks.color_of(give)},
		"label": _seed_label(sp, planet)}


## The seed item for a species, in the player's hands.
##
## The class rides along, not the planet: what matters when you come to plant it
## is the kind of world it needs, and that travels between worlds while a planet
## name does not.
func _give_seeds(planet: Planet, sp: Dictionary, n: int) -> void:
	if sp.is_empty() or n <= 0:
		return
	var give: int = Blocks.SAPLING if str(sp["kind"]) == "tree" else Blocks.SEEDS
	_add_item(give, n, {"species": str(sp["key"]), "class": planet.planet_class()},
		planet.planet_name, {"name": _seed_label(sp, planet),
		"color": Blocks.color_of(give)})


## Always resolved through the planet, so a seed and the harvest it came from
## call the plant the same thing. Reading the name straight off the species had
## them disagreeing: the table calls it Meadow Grass everywhere, and the world
## it grew on does not.
func _seed_label(sp: Dictionary, planet: Planet = null) -> String:
	var nm := str(sp.get("name", "Crop"))
	if planet != null:
		nm = planet.flora_name(str(sp.get("key", "")))
	return "%s %s" % [nm, "Sapling" if str(sp["kind"]) == "tree" else "Seeds"]


# --- farming ------------------------------------------------------------------

## How far from water ground can be worked. Two blocks: close enough that a farm
## has to be somewhere, far enough that it does not have to be a shoreline.
const TILL_RANGE := 3

## Work the ground under the crosshair, if it is soil and there is water nearby.
func _try_till(tgt: Dictionary) -> bool:
	if _selected_id() != Blocks.HOE or tgt.get("kind", "") != "planet":
		return false
	var planet := tgt["obj"] as Planet
	var v: Vector3i = tgt["voxel"]
	var id := Blocks.bottom_of(planet.get_id(v))
	if id != Blocks.GRASS and id != Blocks.DIRT:
		_toast("Only grass and dirt can be worked")
		return true
	if not _water_within(planet, v, TILL_RANGE):
		_toast("Too dry -- soil has to be worked near water")
		return true
	world.edit_block(planet, v, Blocks.TILLED)
	_wear_held(1)
	return true


## Fill an empty bucket from water, or pour a full one out.
##
## Pouring makes a SPRING, not a puddle: it holds itself full and feeds what is
## around it, the same way the sea does. A single cell that drained away the
## moment you turned round would be no use for the one thing this is for --
## working soil somewhere that is not a shoreline.
func _try_bucket(tgt: Dictionary) -> bool:
	var sel := _selected_id()
	if sel != Blocks.BUCKET and sel != Blocks.WATER_BUCKET:
		return false
	if sel == Blocks.BUCKET:
		var got := _water_under_crosshair()
		if got.is_empty():
			_toast("Nothing here to fill it from")
			return true
		var from: Planet = got["planet"]
		var wv: Vector3i = got["voxel"]
		# Only a full cell. The shallow end of a stream is an eighth of a cell
		# of water, and carrying that away as a whole bucketful would turn any
		# spill into an infinite supply.
		if from.water_fill(wv) < 0.999:
			_toast("Too shallow to fill from")
			return true
		# The open sea is left alone -- see Planet.water_is_native. Water that
		# somebody poured or that flowed here is really carried away.
		if not from.water_is_native(wv):
			world.edit_block(from, wv, Blocks.AIR)
		_swap_held(Blocks.WATER_BUCKET)
		return true
	if tgt.get("kind", "") != "planet" or not tgt.get("hit", false):
		return false        # nothing aimed at: fall through to the normal chain
	var planet := tgt["obj"] as Planet
	var v: Vector3i = tgt["place"]
	if planet.get_id(v) != Blocks.AIR:
		_toast("There is no room for it there")
		return true
	world.edit_block(planet, v, Blocks.WATER)
	_swap_held(Blocks.BUCKET)
	return true


## Trade the thing in your hand for one of another kind, in the SAME slot where
## possible: an empty bucket that jumps to the far end of the bar is one you
## have to go looking for in the middle of a field.
func _swap_held(to_id: int) -> void:
	_place_flash = 0.3
	_swing_t = 0.0
	var s = inv[active_slot]
	s["count"] = int(s["count"]) - 1
	if int(s["count"]) <= 0:
		s["id"] = to_id
		s["count"] = 1
		s["props"] = {}
		s["src"] = ""
		s["mat"] = {}
	elif _add_item(to_id, 1) > 0:
		_toast("No room for the bucket")
	_refresh_slots()


## The first water under the crosshair, within reach.
##
## Its own march rather than _raycast_voxel, which deliberately passes THROUGH
## water: everything else you can aim at is solid, and a ray that stopped at the
## surface of a lake would put blocks on top of it instead of on the bed.
func _water_under_crosshair() -> Dictionary:
	if world == null or _camera == null:
		return {}
	var planet := world.nearest_planet(_camera.global_position)
	if planet == null:
		return {}
	var o := planet.to_local(_camera.global_position)
	var d := (planet.global_transform.basis.inverse()
		* -_camera.global_transform.basis.z).normalized()
	var v := Vector3i(floori(o.x), floori(o.y), floori(o.z))
	var step := Vector3i(1 if d.x >= 0.0 else -1, 1 if d.y >= 0.0 else -1,
		1 if d.z >= 0.0 else -1)
	var tmax := Vector3(_tmax(o.x, d.x), _tmax(o.y, d.y), _tmax(o.z, d.z))
	var tdelta := Vector3(_tdelta(d.x), _tdelta(d.y), _tdelta(d.z))
	var travelled := 0.0
	for i in 24:
		if travelled > reach:
			break
		var id := planet.get_id(v)
		if id == Blocks.WATER:
			return {"planet": planet, "voxel": v}
		if id != Blocks.AIR:
			return {}      # something solid comes first: nothing to fill from
		if tmax.x < tmax.y and tmax.x < tmax.z:
			travelled = tmax.x
			v.x += step.x
			tmax.x += tdelta.x
		elif tmax.y < tmax.z:
			travelled = tmax.y
			v.y += step.y
			tmax.y += tdelta.y
		else:
			travelled = tmax.z
			v.z += step.z
			tmax.z += tdelta.z
	return {}


func _water_within(planet: Planet, v: Vector3i, r: int) -> bool:
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if Blocks.bottom_of(planet.get_id(v + Vector3i(dx, dy, dz))) == Blocks.WATER:
					return true
	return false


## Put a seed or a sapling in the ground.
##
## Crops want soil somebody has worked; a tree or a bush will take any ground it
## would have grown on by itself. And nothing takes root on a world that cannot
## keep it alive, which is what the planet classes are for.
func _try_plant(tgt: Dictionary) -> bool:
	var held := _active_item()
	var item := int(held.get("id", Blocks.AIR))
	if item != Blocks.SEEDS and item != Blocks.SAPLING:
		return false
	if tgt.get("kind", "") != "planet":
		return false
	var planet := tgt["obj"] as Planet
	var props: Dictionary = held.get("props", {})
	var want: String = str(props.get("class", ""))
	if want != "" and want != planet.planet_class():
		_toast("%s needs a class %s world -- this is %s"
			% [Blocks.name_of(item), want, planet.class_title()])
		return true
	var v: Vector3i = tgt["place"]
	var ground := Blocks.bottom_of(planet.get_id(tgt["voxel"]))
	var tree := item == Blocks.SAPLING
	if tree:
		if ground != Blocks.GRASS and ground != Blocks.DIRT and ground != Blocks.TILLED:
			_toast("Plant that on grass or dirt")
			return true
	elif ground != Blocks.TILLED:
		_toast("Crops need soil worked with a hoe")
		return true
	if not world.plant(planet, v, str(props.get("species", "meadow")), tree):
		return true
	_consume_active()
	return true


## Bone meal: one stage of growth, or a sapling straight into a tree.
##
## Sits BEFORE harvesting in the right-click chain so that a handful of meal and
## a ripe crop do not fight over the same click -- feeding refuses a finished
## plant, and the harvest below then takes it.
func _try_feed(tgt: Dictionary) -> bool:
	var held := _active_item()
	if int(held.get("id", Blocks.AIR)) != Blocks.BONEMEAL:
		return false
	if tgt.get("kind", "") != "planet":
		return false
	var planet := tgt["obj"] as Planet
	var v: Vector3i = tgt["voxel"]
	if planet.crop_at(v).is_empty():
		return false
	if not world.feed_crop(planet, v):
		_toast("That is ready to pull up")
		return true
	_consume_active()
	return true


## Pull up whatever is ripe under the crosshair.
func _try_harvest(tgt: Dictionary) -> bool:
	if tgt.get("kind", "") != "planet":
		return false
	var planet := tgt["obj"] as Planet
	var v: Vector3i = tgt["voxel"]
	if not planet.crop_ripe(v):
		return false
	var got := world.harvest_crop(planet, v)
	if got.is_empty():
		return false
	var sp := Blocks.flora_by_key(str(got["key"]))
	# Named by the WORLD, not by the table: a seed found here said one thing and
	# the harvest said another, because only the seed knew where it came from.
	var nm: String = planet.flora_name(str(got["key"]))
	# What comes up depends on the species, not on the act: a fibre crop is
	# harvested exactly like a food one and simply yields something else.
	var out := Blocks.crop_yield(str(got["key"]))
	var label: String = nm if out == Blocks.CROP else Blocks.name_of(out)
	_add_item(out, int(got["n"]), {"species": str(got["key"])}, planet.planet_name,
		{"name": label, "color": Blocks.color_of(out)})
	# ...and its seed back. A crop that ate its own seed would make farming a
	# way to run out of plants, so a harvest always replaces itself; a second
	# seed now and then is how a field grows.
	var seeds := Blocks.seed_return(str(got["key"]))
	_give_seeds(planet, sp, seeds)
	_toast("Harvested %d %s, and %d seed%s" % [int(got["n"]), label, seeds,
		"" if seeds == 1 else "s"])
	return true


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
	# Tall grass is REPLACED, not built around. It is a wisp with no collision
	# that you walk straight through, so treating it as a surface to stack
	# against put your block a cell off from where you aimed -- beside the grass
	# or on top of it -- for the sake of something that gets trampled anyway.
	var aim_v: Vector3i = tgt["voxel"]
	if Blocks.is_plant((obj as Planet).get_id(aim_v)):
		pv = aim_v
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
			Blocks.stair_state_variant(_stair_state),
			_stair_upside_down(tgt, obj, pv))}
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
	if Blocks.is_leaf(place_id):
		# Marked as placed, so it neither withers nor comes down with a tree.
		return {"voxel": pv, "value": Blocks.placed_leaf(place_id)}
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


## Minecraft's rule, and the one that needs no extra key: a stair is placed
## upside down when you aim at the underside of a block, or at the upper half
## of a block's side. Aiming at the top of a block, or the lower half of a
## side, places it the right way up. R still turns it either way.
func _stair_upside_down(tgt: Dictionary, obj: Object, pv: Vector3i) -> bool:
	var n: Vector3i = tgt.get("normal", Vector3i.ZERO)
	var upv := Vector3.UP
	if obj is Planet:
		upv = (obj as Planet)._axis_of(Vector3(pv) + Vector3(0.5, 0.5, 0.5))
	var upi := Vector3i(roundi(upv.x), roundi(upv.y), roundi(upv.z))
	if n == -upi:
		return true       # against a ceiling
	if n == upi:
		return false      # on a floor
	# A side: which half of the face you clicked, measured up the cell.
	var hit_cell := pv - n
	var pt: Vector3 = tgt.get("point", Vector3(hit_cell) + Vector3(0.5, 0.5, 0.5))
	var along := (pt - Vector3(hit_cell) - Vector3(0.5, 0.5, 0.5)).dot(Vector3(upi))
	return along > 0.0


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
	# Right-click STARTS eating; the rest happens in _tick_eating while you keep
	# holding it. Nothing is consumed and nothing is gained until you finish.
	_eating = true
	_eating_id = id
	_eat_t = 0.0
	_eat_bites = -1
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
	if existing != null and (is_core or planet.machine_online_at(v)):
		if not planet.machine_online_at(v):
			_toast("%s is damaged -- replace the missing block" % existing.title())
			_open_station(existing)
			return true
		# A bed is not opened, it is got into. This is the path that catches it:
		# a build made of eighths has no collider of its own -- the ray hits the
		# blocks, and _looked_at_station only ever sees stations that ARE a
		# node, so the check up in the click handler never fired for one.
		if existing.kind == Blocks.BED:
			_use_bed(existing, planet.machine_long_axis(planet.machine_anchor_at(v)))
		else:
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
		if _process_anvil_strike(tgt["obj"], lmb_pressed):
			return
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
		if planet != null and Blocks.bottom_of(id) == Blocks.CROP:
			# A crop is two different things to a player -- something to leave
			# alone, or something to come back for -- and "Crop" told them
			# neither. The species goes in it too: a field of one green wisp
			# looks much like a field of another.
			var c: Dictionary = planet.crop_at(v)
			var sp: Dictionary = Blocks.flora_by_key(str(c.get("key", "")))
			var who: String = str(sp.get("name", "Crop")) if not sp.is_empty() else "Crop"
			if planet.crop_ripe(v):
				nm = "%s  -- ready to harvest" % who
				use = ""
			else:
				var g: Dictionary = Blocks.crop_growth(str(c.get("key", "")))
				nm = "%s  (growing, %d of %d)" % [who,
					int(c.get("stage", 0)) + 1, int(g["stages"])]
				use = ""
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
	var power := _power_for(id)
	# Ore cannot be worked with hands at all -- see Blocks.needs_tool for why it
	# is ore and not rock.
	if Blocks.needs_tool(id) and power <= 1.0:
		# The same refusal covers ore and metal now, so it says which it is.
		_look_name = "%s  — %s, hold a Pick" % [_look_name,
			"bare hands cannot get ore out" if Blocks.is_ore(Blocks.bottom_of(id))
				else "bare hands will not shift metal"]
		_mine_key = ""
		_mine_time = 0.0
		return
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
		# Nothing in hand that helps with this material: the full cost of
		# doing it by hand. See HAND_MINE_MULT.
		var mclass := Blocks.material_class(id)
		if power <= 1.0 and HAND_MINE_MULT.has(mclass) and not Blocks.is_leaf(Blocks.bottom_of(id)):
			bare = float(HAND_MINE_MULT[mclass])
		_mine_total = hardness * bare / power
	_mine_time += delta
	# Asked for every frame while the button is held; Audio decides how often it
	# actually sounds, and it stops on its own when the asking stops.
	Audio.mining(id, obj.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)))
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
				_wear_from_block()
			_mine_key = ""
			_mine_time = 0.0
			if _crack != null:
				_crack.visible = false
			return
		if planet != null and Blocks.bottom_of(id) == Blocks.YOUNG_TREE:
			# Deliberately immovable for now: a tree part way up is neither a
			# sapling you could put back nor a log worth having.
			_toast("It is still growing")
			_mine_key = ""
			_mine_time = 0.0
			if _crack != null:
				_crack.visible = false
			return
		if planet != null and Blocks.bottom_of(id) == Blocks.CROP:
			# Ripe comes up as a harvest; anything earlier is just trampled.
			if not _try_harvest(tgt):
				planet.clear_crop(v)
				world.edit_block(planet, v, Blocks.AIR)
			_mine_key = ""
			_mine_time = 0.0
			if _crack != null:
				_crack.visible = false
			return
		if planet != null:
			world.edit_block(planet, v, Blocks.AIR)
			_wear_from_block()
			# A doorway is two cells. Taking one and leaving the other floating
			# is not a thing a door does.
			if Blocks.is_door(id):
				for dn in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
						Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
					if Blocks.is_door(planet.get_id(v + (dn as Vector3i))):
						world.edit_block(planet, v + (dn as Vector3i), Blocks.AIR)
						break
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
			elif Blocks.is_plant(id):
				# Grass is cleared, not harvested: a handful of blades is not a
				# thing to carry around. What it sometimes leaves is a seed.
				if randf() < Blocks.SEED_DROP_CHANCE:
					_drop_flora_seed(planet, "grass", Blocks.SEEDS)
			elif Blocks.bottom_of(id) == Blocks.CRACKED_METAL:
				# Split plate from the wreck: it comes apart rather than off,
				# and what is left is not worth carrying.
				pass
			elif Blocks.is_leaf(Blocks.bottom_of(id)):
				# Leaves give you the tree, not a pile of leaves.
				if randf() < Blocks.SAPLING_DROP_CHANCE:
					_drop_flora_seed(planet, "tree", Blocks.SAPLING)
			else:
				# Strip any packed orientation before it becomes an item: a
				# rotated stair or an axis-aligned log would otherwise come back
				# as a packed value that can't be placed again.
				_add_item(Blocks.bottom_of(id), 1)
				# Cut through a trunk and what is above it comes down; and any
				# leaves this log was holding up start to wither.
				if Blocks.is_wood(Blocks.bottom_of(id)):
					TreeFall.try_fell(planet, world, self, v)
					LeafDecay.nudge(planet, world, self, v)
		elif ship != null:
			ship.set_block(v, Blocks.AIR)
			# Both halves of a doorway come out together and give you back one
			# door, rather than leaving a half hanging in the wall.
			if Blocks.is_door(id):
				var step := Vector3i(0, -1, 0) if Blocks.door_is_top(id) else Vector3i(0, 1, 0)
				var other: Vector3i = v + step
				var oid: int = ship.blocks.get(other, Blocks.AIR)
				if Blocks.is_door(oid) and Blocks.door_is_top(oid) != Blocks.door_is_top(id):
					ship.set_block(other, Blocks.AIR)
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
	_look_name = st.title() + "  (hold to take apart)"
	var holding := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not holding:
		_mine_key = ""
		_mine_time = 0.0
		st.set_dismantle(0.0)
		if _crack != null:
			_crack.visible = false
		return
	var key := "st%d" % st.get_instance_id()
	if key != _mine_key:
		_mine_key = key
		_mine_time = 0.0
		_mine_total = 0.6
	_mine_time += delta
	# Coming apart in front of you: it shrinks and reddens as the seconds run,
	# and says how far along it is.
	var t := clampf(_mine_time / maxf(_mine_total, 0.001), 0.0, 1.0)
	st.set_dismantle(t)
	_look_name = "%s  (taking apart %d%%)" % [st.title(), int(t * 100.0)]
	Audio.at("break_wood", st.global_position)
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
			# A blade is for this; anything else used as a club wears twice as fast.
			var hid := _selected_id()
			_wear_held(1 if hid == Blocks.SWORD or hid == Blocks.WEAPON else 2)
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
		_wear_held(1)
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
## Which half-cycle of the walk bob we were in last frame; a change is a step.
var _step_last := 0
## Whether we were walking last frame, so the first footfall of a movement can
## be made to happen rather than waited for.
var _was_walking := false


## What you are standing ON, which is not always what you are standing in --
## the probe starts below the capsule's feet and reaches down, so tall grass at
## ankle height does not get mistaken for the ground under it.
func _footstep() -> void:
	if world == null:
		return
	var p := world.nearest_planet(global_position)
	if p == null:
		return
	var foot := global_position - up_direction * 0.9
	for depth in [0.15, 0.45]:
		var id := p.get_id(p.world_to_voxel(foot - up_direction * depth))
		if id != Blocks.AIR and id != Blocks.WATER:
			Audio.footstep(id, foot)
			return


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
	# Starting to move ALWAYS makes a sound. The phase below runs whether or not
	# you are walking, so a short movement that began just after a crossing and
	# ended before the next one made no noise at all -- and at ~3.5 rad/s that
	# is anything under about 0.9 seconds, which is most of shuffling about.
	# Restarting the stride here also means the first footfall lands when you
	# start walking rather than wherever the free-running phase happened to be.
	if walking and not _was_walking:
		_bob_phase = 0.0
		_step_last = 0
		if not crouching:
			_footstep()
	_was_walking = walking
	# Phase advances with speed so steps land with the ground, not with the clock.
	_bob_phase += delta * (3.0 + speed * 0.9)
	# One footfall per dip of the bob. Hanging the sound off the same phase the
	# camera already uses means steps land with the stride you can see rather
	# than on a timer of their own -- and it slows down when you are wading or
	# starving for free, because the phase already does.
	var step := floori(_bob_phase / PI)
	if step != _step_last:
		_step_last = step
		if walking and not crouching:
			_footstep()
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
	# The station itself comes back, not a pile of what it was made of, so it
	# can simply be put down again somewhere better.
	_add_item(st.kind, 1)
	_break_burst(st.global_position, Blocks.color_of(st.kind))
	Audio.at("break_wood", st.global_position)
	# return whatever was inside to your inventory
	for s in st.storage:
		if int(s.get("count", 0)) > 0:
			_add_item(s["id"], s["count"], s.get("props", {}), s.get("src", ""), s.get("mat", {}))
		# Change comes back too, one eighth at a time, which is how _add_eighth
		# already knows to find or open the right stack.
		for i in int(s.get("eighths", 0)):
			_add_eighth(int(s["id"]))
	if world != null:
		world._stations.erase(st)
	st.queue_free()
	_refresh_slots()
	_toast("Took apart the %s — put it down again from your bag" % Blocks.name_of(st.kind))


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
	# ...and not over a menu, which they used to be drawn straight across.
	var menu := inv_open or book_open or _station_open != null
	if underground or menu:
		for m in _markers:
			m.visible = false
		if _crash_marker != null:
			_crash_marker.visible = false
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
	_update_crash_marker(cam, inv, vp, center, margin)


## The wreck site, marked the way a planet is: a label over it on screen, or
## pinned to the edge pointing at it when it is behind you or out of view.
## Only once she has flown (there is no point marking where you are standing),
## and only near enough to go back to.
func _update_crash_marker(cam: Camera3D, inv: Transform3D, vp: Vector2, center: Vector2,
		margin: float) -> void:
	var cs: Dictionary = world.crash_site
	var planet: Planet = null
	if not cs.is_empty() and bool(cs.get("shown", false)):
		for p in world.planets:
			if (p as Planet).planet_name == str(cs.get("planet", "")):
				planet = p
				break
	if planet == null:
		if _crash_marker != null:
			_crash_marker.visible = false
		return
	if _crash_marker == null:
		_crash_marker = Label.new()
		_crash_marker.add_theme_font_size_override("font_size", 14)
		_crash_marker.modulate = Color(1.0, 0.72, 0.35)
		_ui_layer.add_child(_crash_marker)
	var wp: Vector3 = planet.to_global(cs["local"] as Vector3)
	var dist := wp.distance_to(cam.global_position)
	if dist < 30.0 or dist > 30000.0:
		_crash_marker.visible = false
		return
	var localp := inv * wp
	var pos: Vector2
	var offscreen := true
	if localp.z < 0.0:
		pos = cam.unproject_position(wp)
		offscreen = pos.x < margin or pos.x > vp.x - margin or pos.y < margin or pos.y > vp.y - margin
	if offscreen:
		var d2 := Vector2(localp.x, -localp.y)
		if localp.z > 0.0:
			d2 = -d2
		if d2.length() < 0.001:
			d2 = Vector2(0, 1)
		pos = _clamp_to_edge(center, d2.normalized(), vp, margin)
		_crash_marker.text = ">> Crash site  %s" % _fmt_dist(dist)
	else:
		_crash_marker.text = "Crash site  %s" % _fmt_dist(dist)
	_crash_marker.position = pos
	_crash_marker.visible = true


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


## A toast that stays up. Used once, when a world opens, to say that the thing
## in front of you can be talked to -- long enough to read while your head is
## still coming up, and gone before it becomes furniture.
func hold_toast(msg: String, seconds: float) -> void:
	if _toast_label == null:
		return
	_toast_label.text = msg
	_toast_label.visible = true
	_toast_time = seconds


# Build the always-visible hotbar strip and the toggleable full-inventory grid.
func _build_inventory_ui(layer: CanvasLayer) -> void:
	# hotbar strip, bottom-center, on a backing strip of its own
	var pad := 8.0
	var strip_w := HOTBAR_SLOTS * HOTBAR_CELL + (HOTBAR_SLOTS - 1) * HOTBAR_GAP + pad * 2.0
	var strip_h := HOTBAR_CELL + pad * 2.0
	var strip := Panel.new()
	strip.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	strip.size = Vector2(strip_w, strip_h)
	strip.position = Vector2(-strip_w * 0.5, -strip_h - 14.0)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ssb := StyleBoxFlat.new()
	ssb.bg_color = Color(0.03, 0.04, 0.06, 0.45)
	ssb.set_corner_radius_all(12)
	strip.add_theme_stylebox_override("panel", ssb)
	layer.add_child(strip)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", HOTBAR_GAP)
	hb.position = Vector2(pad, pad)
	strip.add_child(hb)
	for i in HOTBAR_SLOTS:
		var cell := _make_slot(hb, i, "none", HOTBAR_CELL)
		# Its number, faint in the corner: the key that selects it.
		var num := Label.new()
		num.text = str(i + 1)
		num.position = Vector2(6, 2)
		num.add_theme_font_size_override("font_size", 12)
		num.modulate = Color(1, 1, 1, 0.5)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell["root"].add_child(num)
		_hotbar_cells.append(cell)

	# full inventory overlay (E): inventory grid, a 2-tall Suit equip slot, and a
	# scrollable "Craft" list (scrolls instead of growing as recipes are added)
	# One source of truth for cell metrics: the tall-item renderer needs the
	# exact row pitch, and a hardcoded copy would silently misalign the moment
	# spacing changed.
	var grid_w := HOTBAR_SLOTS * BAG_STEP
	var grid_h := 4 * BAG_STEP
	# Suit sits on the LEFT, ahead of the grid: it's worn gear, so it reads as
	# part of "you" rather than as an afterthought tacked on past the bag.
	# Two columns wide, for the vanity slots; the Suit sits in the middle of it.
	var equip_w := BAG_STEP + BAG_CELL + 8
	var equip_x := 14
	# You, between what you wear and what you carry -- see CharacterPreview.
	var fig_w := 150
	var fig_x := equip_x + equip_w + 6
	var grid_x := fig_x + fig_w + 14
	_inv_panel = Panel.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	# Just the bag and what you are wearing. The crafting column that used to sit
	# to the right of this is gone: everything is made at a bench now, so a list
	# of what you can make from your pockets would be an empty list.
	_inv_panel.custom_minimum_size = Vector2(grid_x + grid_w + 12, 48 + grid_h + 20)
	_inv_panel.size = _inv_panel.custom_minimum_size
	_inv_panel.position = -_inv_panel.size * 0.5
	_inv_panel.visible = false
	# The same framed window as the Recipe Book.
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0.06, 0.07, 0.10, 0.94)
	isb.border_color = Color(0.40, 0.52, 0.62, 0.9)
	isb.set_border_width_all(1)
	isb.set_corner_radius_all(8)
	_inv_panel.add_theme_stylebox_override("panel", isb)
	layer.add_child(_inv_panel)
	var title := Label.new()
	title.text = "Inventory"
	title.position = Vector2(grid_x + 2, 10)
	title.add_theme_font_size_override("font_size", 18)
	_inv_panel.add_child(title)
	var sub := Label.new()
	sub.text = "drag to rearrange"
	sub.position = Vector2(grid_x + 94, 15)
	sub.add_theme_font_size_override("font_size", 12)
	sub.modulate = Color(1, 1, 1, 0.45)
	_inv_panel.add_child(sub)
	var grid := GridContainer.new()
	grid.columns = HOTBAR_SLOTS
	grid.add_theme_constant_override("h_separation", BAG_GAP)
	grid.add_theme_constant_override("v_separation", BAG_GAP)
	grid.position = Vector2(grid_x, 48)
	_inv_panel.add_child(grid)
	for i in SLOTS:
		_grid_cells.append(_make_slot(grid, i, "select", BAG_CELL))

	# equip slot: a Suit only protects you once dragged here -- carrying one loose
	# in the grid above does nothing (unlike the Drill)
	# Two tabs over it: Gear, what protects you, and Vanity, what you look like.
	var tab_w := (BAG_STEP + BAG_CELL) * 0.5 - 2.0
	_gear_tab = _inv_tab("Gear", Vector2(equip_x, 10), tab_w)
	_vanity_tab = _inv_tab("Vanity", Vector2(equip_x + tab_w + 4.0, 10), tab_w)
	_gear_tab.pressed.connect(_show_vanity.bind(false))
	_vanity_tab.pressed.connect(_show_vanity.bind(true))
	_gear_box = Control.new()
	_gear_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inv_panel.add_child(_gear_box)
	_equip_cell = _make_equip_slot(_gear_box, Vector2(equip_x + BAG_STEP * 0.5, 48))
	var suit_lbl := Label.new()
	suit_lbl.text = "Suit"
	suit_lbl.modulate = Color(1, 1, 1, 0.55)
	suit_lbl.add_theme_font_size_override("font_size", 13)
	suit_lbl.position = Vector2(equip_x + BAG_STEP * 0.5 + 18, 48 + BAG_CELL * 2 + BAG_GAP + 4)
	_gear_box.add_child(suit_lbl)
	_vanity_box = Control.new()
	_vanity_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inv_panel.add_child(_vanity_box)
	# Down the body on the left, head to foot; the extras on the right.
	var at := {"hat": Vector2(0, 0), "shirt": Vector2(0, 1), "pants": Vector2(0, 2),
		"shoes": Vector2(0, 3), "face": Vector2(1, 0), "back": Vector2(1, 1), "trail": Vector2(1, 2)}
	for slot in Cosmetics.SLOTS:
		var ix: int = Cosmetics.SLOTS.find(slot)
		var holder := Control.new()
		holder.position = Vector2(equip_x, 48) + at[slot] * BAG_STEP
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_vanity_box.add_child(holder)
		var cell := _make_slot(holder, ix, "vanity", BAG_CELL)
		# The slot's name, faint, for while it is empty.
		var nm := Label.new()
		nm.text = Cosmetics.SLOT_NAMES[slot]
		nm.set_anchors_preset(Control.PRESET_FULL_RECT)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		nm.add_theme_font_size_override("font_size", 13)
		nm.modulate = Color(1, 1, 1, 0.3)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell["root"].add_child(nm)
		cell["name"] = nm
		_vanity_cells[slot] = cell
	_show_vanity(false)
	var fig_back := Panel.new()
	fig_back.position = Vector2(fig_x, 48)
	fig_back.size = Vector2(fig_w, grid_h - BAG_GAP)
	fig_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0.03, 0.04, 0.06, 0.7)
	fsb.border_color = SLOT_EDGE
	fsb.set_border_width_all(1)
	fsb.set_corner_radius_all(8)
	fig_back.add_theme_stylebox_override("panel", fsb)
	_inv_panel.add_child(fig_back)
	get_viewport().size_changed.connect(_refit_panels)
	_char_preview = CharacterPreview.new(Vector2i(fig_w, int(grid_h - BAG_GAP)))
	_char_preview.position = Vector2(fig_x, 48)
	_inv_panel.add_child(_char_preview)


# One slot cell: colored square + count. `mode`: "none" = display only,
# "select" = click picks the active slot, "inv"/"stor" = drag source & drop target
# (inventory slot / station-storage slot). Items are moved by dragging.
func _make_slot(parent: Node, index: int, mode: String, px: int = INV_CELL) -> Dictionary:
	var root: Control
	if mode == "select":
		var b := Button.new()
		b.pressed.connect(_on_slot_pressed.bind(index))
		root = b
	else:
		root = Panel.new()
	root.custom_minimum_size = Vector2(px, px)
	_style_slot(root, false)
	parent.add_child(root)
	var swatch := ColorRect.new()
	swatch.set_anchors_preset(Control.PRESET_FULL_RECT)
	swatch.offset_left = 6; swatch.offset_top = 6
	swatch.offset_right = -6; swatch.offset_bottom = -6
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(swatch)
	var count := _slot_count_label(px)
	root.add_child(count)
	# drag & drop: "select"/"to_station" cells map to inventory slots, "from_station"
	# to the open station's storage
	var dcont := ""
	if mode == "select" or mode == "to_station":
		dcont = "inv"
	elif mode == "from_station":
		dcont = "stor"
	elif mode == "vanity":
		dcont = "vanity"
	if dcont != "":
		root.set_drag_forwarding(
			_slot_get_drag.bind(dcont, index, root),
			_slot_can_drop.bind(dcont, index),
			_slot_do_drop.bind(dcont, index))
	return {"root": root, "swatch": swatch, "count": count, "selected": false}


## A slot's frame. Buttons (the bag's slots) get the hover and pressed states
## too, so the slot under the mouse lights up.
func _style_slot(root: Control, selected: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SLOT_BG if not selected else Color(0.16, 0.14, 0.08, 0.85)
	sb.border_color = SLOT_SELECT if selected else SLOT_EDGE
	sb.set_border_width_all(3 if selected else 2)
	sb.set_corner_radius_all(7)
	if root is Button:
		var hv := sb.duplicate() as StyleBoxFlat
		if not selected:
			hv.border_color = SLOT_EDGE_HOVER
			hv.bg_color = Color(0.11, 0.13, 0.17, 0.85)
		for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			root.add_theme_stylebox_override(st, hv if st != "normal" else sb)
	else:
		root.add_theme_stylebox_override("panel", sb)


## How many: bottom right, white with a dark outline so it reads over any icon.
func _slot_count_label(px: int) -> Label:
	var count := Label.new()
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -px * 0.6
	count.offset_top = -24
	count.offset_right = -5
	count.offset_bottom = -1
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.add_theme_font_size_override("font_size", 15 if px >= 60 else 13)
	count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	count.add_theme_constant_override("outline_size", 5)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return count


# A single equip slot that's visually two grid cells tall, holding one Suit at a
# time (the item fills the whole slot, not spread across two separate cells).
func _make_equip_slot(parent: Node, pos: Vector2) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(BAG_CELL, BAG_CELL * 2 + BAG_GAP)  # two bag cells tall
	root.position = pos
	_style_slot(root, false)
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
	if cont == "vanity":
		return _vanity_slot(index)
	if cont == "stor" and index >= 0 and index < _stor_map.size():
		var m: Dictionary = _stor_map[index]
		var st: Station = m["st"]
		if is_instance_valid(st) and int(m["slot"]) < st.storage.size():
			return st.storage[int(m["slot"])]
	return {}


func _slot_get_drag(_at: Vector2, cont: String, index: int, root: Control) -> Variant:
	var slot := _slot_ref(cont, index)
	if not _slot_holds(slot):
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
	s["eighths"] = 0
	s["props"] = {}
	s["src"] = ""
	s["mat"] = {}
	s.erase("dur")


func _copy_slot(src: Dictionary, dst: Dictionary) -> void:
	dst["id"] = src["id"]
	dst["count"] = src["count"]
	# The change travels with the blocks. Leaving it behind stranded a fraction
	# of a block in a slot that looked empty, with no way to get it out again
	# except by placing it.
	dst["eighths"] = int(src.get("eighths", 0))
	dst["props"] = src.get("props", {})
	dst["src"] = src.get("src", "")
	dst["mat"] = src.get("mat", {})
	# How worn it is goes with it, or moving a tool would mend it.
	if src.has("dur"):
		dst["dur"] = int(src["dur"])
	else:
		dst.erase("dur")


## A tool's wear, as a bar along the bottom of its slot -- only once it has
## been used, so a new tool's slot stays clean. Green when fresh, red near the end.
func _paint_wear(cell: Dictionary, mx: int, dur: int) -> void:
	var bar = cell.get("wear")
	if mx <= 0 or dur >= mx:
		if bar != null:
			(bar as Control).visible = false
		return
	if bar == null:
		var bg := ColorRect.new()
		bg.color = Color(0, 0, 0, 0.85)
		bg.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		bg.offset_left = 8
		bg.offset_right = -8
		bg.offset_top = -10
		bg.offset_bottom = -6
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill := ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.position = Vector2.ZERO
		bg.add_child(fill)
		(cell["root"] as Control).add_child(bg)
		cell["wear"] = bg
		bar = bg
	var f := clampf(float(dur) / float(mx), 0.0, 1.0)
	var fill_r: ColorRect = (bar as Control).get_child(0)
	fill_r.anchor_left = 0.0
	fill_r.anchor_top = 0.0
	fill_r.anchor_bottom = 1.0
	fill_r.anchor_right = maxf(f, 0.04)
	fill_r.offset_left = 0
	fill_r.offset_top = 0
	fill_r.offset_right = 0
	fill_r.offset_bottom = 0
	fill_r.color = Color(1.0, 0.2, 0.1).lerp(Color(0.3, 0.9, 0.2), f)
	(bar as Control).visible = true


## Use up some of what is in your hand, if it wears. Breaks it at nothing left.
func _wear_held(amount: int) -> void:
	if active_slot < 0 or active_slot >= inv.size():
		return
	var s: Dictionary = inv[active_slot]
	if int(s.get("count", 0)) <= 0:
		return
	var id := int(s["id"])
	var mx := Blocks.max_durability(id)
	if mx <= 0:
		return
	if int(s["count"]) > 1:
		# A stack from before tools wore out: the rest step aside into a free
		# slot, so only the one in hand takes the wear.
		for i in inv.size():
			var e: Dictionary = inv[i]
			if i != active_slot and not _slot_holds(e) and _cover_owner(i) < 0:
				_copy_slot(s, e)
				e["count"] = int(s["count"]) - 1
				e.erase("dur")
				s["count"] = 1
				break
	var left := int(s.get("dur", mx)) - amount
	if left <= 0:
		_toast("Your %s broke" % Blocks.name_of(id))
		if int(s["count"]) > 1:
			s["count"] = int(s["count"]) - 1
			s.erase("dur")
		else:
			_clear_slot(s)
	else:
		s["dur"] = left
	_refresh_slots()


## Breaking a block with a blade is misuse, and costs it double.
func _wear_from_block() -> void:
	var id := _selected_id()
	_wear_held(2 if id == Blocks.SWORD or id == Blocks.WEAPON else 1)


## Whether a slot holds anything at all. Five eighths of a rock is something,
## and every check that asked only about `count` treated it as nothing.
func _slot_holds(s: Dictionary) -> bool:
	return not s.is_empty() and (int(s.get("count", 0)) > 0
		or int(s.get("eighths", 0)) > 0)


## Which of a generator's bays a slot reference is: 0 the cradle, 1 the
## hopper, 2+ a leftover slot from an older save, -1 not a generator at all.
func _gen_bay_of(cont: String, index: int) -> int:
	if cont != "stor" or index < 0 or index >= _stor_map.size():
		return -1
	var st: Station = _stor_map[index]["st"]
	if not is_instance_valid(st) or st.kind != Blocks.GENERATOR:
		return -1
	return int(_stor_map[index]["slot"])


## May `item` go into this slot? Only ever says no for a generator's bays, and
## says why when it does.
func _gen_bay_allows(cont: String, index: int, item: Dictionary) -> bool:
	var bay := _gen_bay_of(cont, index)
	if bay < 0 or not _slot_holds(item):
		return true
	if Station.gen_accepts(bay, int(item["id"]), item.get("props", {})):
		return true
	if bay == 0:
		_toast("The cradle takes a battery")
	elif bay == 1:
		_toast("The hopper takes ore with Combustion")
	else:
		_toast("Take that out -- this generator only has a cradle and a hopper now")
	return false


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
	if to.is_empty() or not _slot_holds(from):
		return
	# dropping INTO a machine's storage must match what it accepts (chests and the
	# Carpenter's Bench take any plain resource; the rest are picky by design so
	# each station's recipes read as one cohesive idea)
	if tc == "stor" and fc != "stor" and ti < _stor_map.size():
		var tst: Station = _stor_map[ti]["st"]
		var fid: int = from["id"]
		if Blocks.is_smelter_kind(tst.kind) and not (Blocks.is_ore(fid) or Blocks.is_refined(fid)
				or fid == Blocks.METAL or fid == Blocks.SCRAP):
			_toast("Smelter takes raw ore, ingots, scrap, or Metal")
			return
		# A bench takes what its own recipes use -- see Blocks.station_accepts.
		if (tst.kind == Blocks.FABRICATOR or tst.kind == Blocks.SHIPWORKS) \
				and not Blocks.station_accepts(tst.kind, fid):
			_toast("The %s has no use for that" % Blocks.name_of(tst.kind))
			return
	# A generator's two bays each take one kind of thing, both ways round: what
	# goes in has to fit, and so does whatever a swap sends back the other way.
	if not _gen_bay_allows(tc, ti, from) or (_slot_holds(to) and not _gen_bay_allows(fc, fi, to)):
		return
	var gen_cradle := _gen_bay_of(tc, ti)
	if gen_cradle == 0 and int(from["count"]) > 1:
		# The cradle holds exactly one battery. Seat one off the stack.
		if _slot_holds(to):
			_toast("Take the battery out of the cradle first")
			return
		_copy_slot(from, to)
		to["count"] = 1
		from["count"] = int(from["count"]) - 1
		_refresh_slots()
		_refresh_station_ui()
		return
	if gen_cradle == 0 and _slot_holds(to) and int(to["id"]) == int(from["id"]):
		# Two batteries never stack in the cradle -- swap them instead.
		var tmp_b: Dictionary = to.duplicate(true)
		_copy_slot(from, to)
		_copy_slot(tmp_b, from)
		_refresh_slots()
		_refresh_station_ui()
		return
	# the equip slot only ever holds a Suit -- that's what makes it worn, not just carried
	if tc == "equip" and from["id"] != Blocks.SUIT:
		_toast("Only a Suit fits there")
		return
	# Swapping puts what was at the far end back where this came from, so that
	# has to fit there too -- or a rock ends up worn as a hat.
	if fc == "equip" and _slot_holds(to) and to["id"] != Blocks.SUIT:
		_toast("Only a Suit fits there")
		return
	if tc == "vanity" and not _fits_vanity(int(from["id"]), ti):
		_toast(_vanity_refusal(ti))
		return
	if fc == "vanity" and _slot_holds(to) and int(to["id"]) != int(from["id"]):
		if not _fits_vanity(int(to["id"]), fi):
			_toast(_vanity_refusal(fi))
			return
		if int(to["count"]) > 1:
			_toast("Wear one at a time -- move the rest out first")
			return
	# One of a stack is worn; the rest stay in the bag.
	if tc == "vanity" and int(from["count"]) > 1:
		if _slot_holds(to):
			_toast("Take off the one you are wearing first")
			return
		_copy_slot(from, to)
		to["count"] = 1
		from["count"] = int(from["count"]) - 1
		if fc == "inv":
			_sync_cover(fi)
		_refresh_slots()
		_refresh_station_ui()
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
	if _slot_holds(to) and to["id"] == from["id"] and to.get("src", "") == from.get("src", ""):
		var cap: int = STACK_MAX if tc == "inv" else (1 if tc == "equip" or tc == "vanity" else 100000)
		cap = Blocks.stack_cap(int(from["id"]), cap)
		var mv: int = mini(cap - int(to["count"]), int(from["count"]))
		to["count"] += mv
		from["count"] -= mv
		# Change only follows once the whole blocks have gone, because a partial
		# move that split it would leave a fraction of a block in each place --
		# two slots each showing a piece of one rock.
		if int(from["count"]) <= 0 and int(from.get("eighths", 0)) > 0:
			var e := int(to.get("eighths", 0)) + int(from["eighths"])
			# Eight eighths are a block, and it becomes one rather than sitting
			# there as a fraction that will not add up.
			if e >= 8 and int(to["count"]) < cap:
				to["count"] = int(to["count"]) + 1
				e -= 8
			if e < 8:
				to["eighths"] = e
				from["eighths"] = 0
		if not _slot_holds(from):
			_clear_slot(from)
	elif not _slot_holds(to):
		_copy_slot(from, to)
		_clear_slot(from)
	else:
		var tmp := {"id": to["id"], "count": to["count"],
			"eighths": int(to.get("eighths", 0)), "props": to.get("props", {}),
			"src": to.get("src", ""), "mat": to.get("mat", {})}
		if to.has("dur"):
			tmp["dur"] = int(to["dur"])
		_copy_slot(from, to)
		from["id"] = tmp["id"]
		from["count"] = tmp["count"]
		from["eighths"] = tmp["eighths"]
		from["props"] = tmp["props"]
		from["src"] = tmp["src"]
		from["mat"] = tmp["mat"]
		if tmp.has("dur"):
			from["dur"] = tmp["dur"]
		else:
			from.erase("dur")
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
		sw.offset_bottom = (-6.0 + float(BAG_STEP)) if tall else -6.0
	if not _equip_cell.is_empty():
		_paint_cell(_equip_cell, suit_slot, false)
	for slot in _vanity_cells:
		var vc: Dictionary = _vanity_cells[slot]
		var vs := _vanity_slot(Cosmetics.SLOTS.find(slot))
		_paint_cell(vc, vs, false)
		(vc["name"] as Label).visible = not _slot_holds(vs)
		(vc["count"] as Label).text = ""
	_apply_look()
	_update_mine_power()


# --- vanity ---------------------------------------------------------------------

func _vanity_slot(index: int) -> Dictionary:
	if index < 0 or index >= Cosmetics.SLOTS.size():
		return {}
	var slot: String = Cosmetics.SLOTS[index]
	if not vanity.has(slot):
		vanity[slot] = {"id": Blocks.AIR, "count": 0, "props": {}, "src": "", "mat": {}}
	return vanity[slot]


func _fits_vanity(id: int, index: int) -> bool:
	return index >= 0 and index < Cosmetics.SLOTS.size() 		and Cosmetics.slot_of(id) == Cosmetics.SLOTS[index]


func _vanity_refusal(index: int) -> String:
	var slot: String = Cosmetics.SLOTS[clampi(index, 0, Cosmetics.SLOTS.size() - 1)]
	var n: String = Cosmetics.SLOT_NAMES[slot]
	if slot == "pants" or slot == "shoes":
		return "Only %s go there" % n.to_lower()
	return "Only a %s goes there" % n.to_lower()


## What you are wearing, as {slot: item id} -- all anybody else needs to draw it.
func worn_look() -> Dictionary:
	var out := {}
	for i in Cosmetics.SLOTS.size():
		var s := _vanity_slot(i)
		if _slot_holds(s) and Cosmetics.is_cosmetic(int(s["id"])):
			out[Cosmetics.SLOTS[i]] = int(s["id"])
	return out


## Put what is worn on the inventory's figure, on your own trail, and tell
## everyone else -- only when it has changed.
func _apply_look() -> void:
	var look := worn_look()
	var tag := hash(look)
	# Not remembered until it can be told to anyone, so a look put on before
	# the player is in the world is still announced once it is.
	if tag == _look_tag or not is_inside_tree():
		return
	_look_tag = tag
	if _char_preview != null:
		_char_preview.wear(look)
	var tid := int(look.get("trail", 0))
	if tid != _trail_id:
		_trail_id = tid
		if _trail != null:
			_trail.queue_free()
			_trail = null
		if tid != 0:
			_trail = Cosmetics.make_trail(tid)
			if _trail != null:
				_trail.position = Vector3(0, -0.75, 0)
				add_child(_trail)
	var main := get_tree().current_scene if is_inside_tree() else null
	if main != null:
		var net = main.get("_net")
		if net != null and net.has_method("announce_look"):
			net.announce_look(look)


func _inv_tab(text: String, pos: Vector2, w: float) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.position = pos
	b.custom_minimum_size = Vector2(w, 28)
	b.size = b.custom_minimum_size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 14)
	_inv_panel.add_child(b)
	return b


func _show_vanity(on: bool) -> void:
	if _gear_box == null or _vanity_box == null:
		return
	_gear_box.visible = not on
	_vanity_box.visible = on
	_gear_tab.set_pressed_no_signal(not on)
	_vanity_tab.set_pressed_no_signal(on)


# Your effective mining power is the best drill you carry (bare hands = 1.0). This
# sets mining speed and which ore tiers you can break. Also scans for
# gear -- the best you carry applies automatically. The Suit is different: it
# only protects you while actually worn in `suit_slot` (see that var's comment).
func _update_mine_power() -> void:
	var best := 1.0
	var by_class := {"rock": 1.0, "wood": 1.0, "soil": 1.0}
	var bonus := 0.0
	# Only what is in your HAND helps. Carrying a Pick in the bag used to be
	# enough, which meant digging with bare hands was never slow once you had
	# made one -- and there was no telling the two apart.
	var held_slot: Dictionary = inv[active_slot] if active_slot >= 0 and active_slot < inv.size() else {}
	for s in [held_slot]:
		if s.is_empty() or int(s.get("count", 0)) <= 0:
			continue
		var mat: Dictionary = s.get("mat", {})
		var id: int = s["id"]
		if id == Blocks.DRILL:
			var p := float(mat.get("power", 1.0))
			best = maxf(best, p)
			# A Drill is every class at once. That is the whole point of it:
			# once you have one the three basic tools have nothing left to do.
			for k in by_class:
				by_class[k] = maxf(float(by_class[k]), p)
			bonus = maxf(bonus, Blocks.DRILL_REACH)
		elif Blocks.TOOLS.has(id):
			var t: Dictionary = Blocks.TOOLS[id]
			var c := str(t["class"])
			by_class[c] = maxf(float(by_class[c]), float(t["power"]))
			bonus = maxf(bonus, float(t["reach"]))
	mine_power = best
	_class_power = by_class
	reach = clampf(REACH_BARE + bonus, REACH_BARE, REACH_MAX)
	var resist := 0.0
	if suit_slot.get("id", Blocks.AIR) == Blocks.SUIT and int(suit_slot.get("count", 0)) > 0:
		resist = float(suit_slot.get("mat", {}).get("resist", 0.0))
	_hazard_resist = clampf(resist, 0.0, 0.9)

	# A melee weapon only does anything if it's the slot you're actively holding --
	# unlike worn gear (drill/tank/suit), carrying one in the pack isn't enough.
	var active: Dictionary = inv[active_slot] if active_slot >= 0 and active_slot < inv.size() else {}
	if active.get("id", -1) == Blocks.WEAPON and int(active.get("count", 0)) > 0:
		_melee_damage = float(active.get("mat", {}).get("damage", UNARMED_DAMAGE))
	elif active.get("id", -1) == Blocks.SWORD and int(active.get("count", 0)) > 0:
		_melee_damage = Blocks.SWORD_DAMAGE
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
	# Everyone else sees it in your figure's hand, and so does your own in the
	# inventory.
	if _char_preview != null:
		_char_preview.hold(id)
	var main := get_tree().current_scene if is_inside_tree() else null
	if main != null:
		var net = main.get("_net")
		if net != null and net.has_method("announce_held"):
			net.announce_held(id)
	if _held_root != null:
		_held_root.queue_free()
		_held_root = null
	_held_item = null
	_held_book = null
	if id == Blocks.AIR or _hand_pivot == null:
		return
	_held_root = Node3D.new()
	_hand_pivot.add_child(_held_root)
	if ToolModels.has_model(id):
		var tint: Color = mat.get("color", _tool_tint(id))
		var mi := MeshInstance3D.new()
		mi.mesh = ToolModels.mesh(id, tint)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Held smaller than life, low in the corner of the view and leaning away,
		# so the working end is on screen rather than up past the top edge.
		if ToolModels.is_upright(id):
			mi.scale = Vector3.ONE * 0.6
			mi.position = Vector3(0, -0.04, 0)
			mi.rotation = Vector3(-0.55, 0, 0)
		else:
			mi.scale = Vector3.ONE * 0.6
			mi.position = Vector3(0, -0.04, 0)
		_held_root.add_child(mi)
	elif id == Blocks.JOURNAL:
		# The book is a rig rather than a mesh: it has a hinge, and a hinge is
		# the only thing that makes opening one look like opening one.
		_held_book = ItemModels.make_book()
		_held_book.scale = Vector3.ONE * 0.55
		_held_book.position = Vector3(0.04, -0.06, 0)
		_held_book.rotation = Vector3(-0.25, 0.6, 0.0)
		_held_root.add_child(_held_book)
		ItemModels.set_book_open(_held_book, 0.0)
	elif ItemModels.has_model(id):
		# Food: a model rather than a tinted cube. Held a little larger than a
		# tool, because a loaf in the corner of the eye at tool scale is a crumb.
		_held_item = MeshInstance3D.new()
		_held_item.mesh = ItemModels.mesh(id, mat.get("color", Color(0, 0, 0, 0)))
		_held_item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_held_item.scale = Vector3.ONE * 0.55
		_held_item.position = Vector3(0, -0.05, 0)
		_held_item.rotation = Vector3(-0.2, 0.5, 0.15)
		_held_root.add_child(_held_item)
	elif Blocks.is_placeable_block(id) or Blocks.is_ore(id) or Blocks.is_refined(id) or Blocks.is_intermediate(id):
		_build_held_block(mat.get("color", Blocks.color_of(id)))
	# other gear (the Suit) is worn, not wielded -- nothing shown in hand


## How long you have to keep eating before it does you any good, and how long
## one chew of the animation takes.
const EAT_TIME := 1.6
const CHEW_TIME := 0.45


## The held model's own animations: eating and reading.
func _tick_held_anim(delta: float) -> void:
	_tick_eating(delta)
	_tick_reading(delta)


## Eating is HELD, not clicked. You bring the food up and keep at it, and the
## food only does you good once you have finished it -- so a meal is a moment
## you have to stand still for rather than a keypress.
func _tick_eating(delta: float) -> void:
	if not _eating:
		return
	var held := _active_item()
	var id := int(held.get("id", Blocks.AIR))
	var still_down: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED 		and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if not still_down or id != _eating_id or int(held.get("count", 0)) <= 0 or menu_open:
		_eating = false
		_eat_t = 0.0
		_reset_held_pose()
		_eat_bites = -1
		return
	_eat_t += delta
	if _held_item != null and is_instance_valid(_held_item):
		# Chewing: the same arc over and over while you hold, so it is obvious it
		# is still going and roughly how fast.
		var arc: float = sin(fposmod(_eat_t, CHEW_TIME) / CHEW_TIME * PI)
		_held_item.position = Vector3(-0.10 * arc, -0.05 + 0.16 * arc, 0.16 * arc)
		_held_item.rotation = Vector3(-0.2 - 0.9 * arc, 0.5 + 0.7 * arc, 0.15)
		_held_item.scale = Vector3.ONE * (0.55 - 0.06 * arc)
		# And it actually goes: a bite comes out of the model at the top of each
		# arc, so by the end there is nearly nothing left in your hand.
		var bites: int = mini(int(_eat_t / EAT_TIME * float(ItemModels.BITES)),
			ItemModels.BITES - 1)
		if bites != _eat_bites:
			_eat_bites = bites
			_held_item.mesh = ItemModels.mesh_bitten(id,
				float(bites) / float(ItemModels.BITES))
	if _eat_t < EAT_TIME:
		return
	# Finished it.
	_eating = false
	_eat_t = 0.0
	var gain := Blocks.food_value(id)
	hunger = minf(hunger + gain, MAX_HUNGER)
	_remove_item(id, 1)
	_toast("Ate %s  (+%d food)" % [Blocks.name_of(id), int(round(gain))])
	_update_survival_ui()
	_refresh_slots()
	_reset_held_pose()
	_eat_bites = -1



## Back to a whole item held normally -- either because you finished one and the
## next one is a fresh one, or because you let go part way and did not eat it.
func _reset_held_pose() -> void:
	if _held_item != null and is_instance_valid(_held_item):
		var id := int(_active_item().get("id", Blocks.AIR))
		if _eat_bites >= 0 and ItemModels.has_model(id):
			_held_item.mesh = ItemModels.mesh(id)
		_held_item.position = Vector3(0, -0.05, 0)
		_held_item.rotation = Vector3(-0.2, 0.5, 0.15)
		_held_item.scale = Vector3.ONE * 0.55


## The book opens in your hands while the page is up, and shuts when you put it
## away. A real hinge, so the covers swing rather than slide.
func _tick_reading(delta: float) -> void:
	if _held_book == null or not is_instance_valid(_held_book):
		return
	var want: float = 1.0 if _journal_panel != null else 0.0
	if is_equal_approx(_read_t, want):
		return
	_read_t = move_toward(_read_t, want, delta * 2.6)
	var e: float = _read_t * _read_t * (3.0 - 2.0 * _read_t)
	ItemModels.set_book_open(_held_book, e)
	# Brought up and turned square to you as it opens, so you are reading it
	# rather than holding it out at your side.
	_held_book.position = Vector3(0.04 - 0.04 * e, -0.06 + 0.05 * e, 0.10 * e)
	_held_book.rotation = Vector3(-0.25 - 0.35 * e, 0.6 - 0.6 * e, 0.0)
	_held_book.scale = Vector3.ONE * (0.55 + 0.18 * e)


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


## The colour of what a tool's working end is made of, when its material does
## not say.
static func _tool_tint(id: int) -> Color:
	match id:
		Blocks.WEAPON:
			return Color(0.8, 0.8, 0.85)
		Blocks.PULSE_PISTOL:
			return Color(0.3, 0.75, 0.85)
	return Color(0.7, 0.7, 0.75)


func _build_held_block(color: Color) -> void:
	_mk_view_box(Vector3(0.22, 0.22, 0.22), Vector3(0, 0, -0.15), color)


## Something is close behind you that you cannot see (see Watcher). `level` is
## 0..1 by how close. The screen darkens at the edges and pulses, and that is
## the only warning there is.
func dread(level: float) -> void:
	_dread_want = maxf(_dread_want, clampf(level, 0.0, 1.0))


func _tick_dread(delta: float) -> void:
	# Rises quickly, falls away slowly -- the feeling outlasts the thing.
	_dread = move_toward(_dread, _dread_want, delta * (2.5 if _dread_want > _dread else 0.5))
	_dread_want = 0.0
	if _dread <= 0.005:
		if _dread_rect != null:
			_dread_rect.visible = false
		return
	if _dread_rect == null and _ui_layer != null:
		_dread_rect = TextureRect.new()
		_dread_rect.texture = ImageTexture.create_from_image(_vignette_image())
		_dread_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_dread_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_dread_rect.stretch_mode = TextureRect.STRETCH_SCALE
		_dread_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui_layer.add_child(_dread_rect)
		_ui_layer.move_child(_dread_rect, 0)
	if _dread_rect == null:
		return
	# A heartbeat: two beats and a rest, faster the closer it is.
	var t := fmod(Time.get_ticks_msec() * 0.001 * lerpf(1.0, 1.8, _dread), 1.0)
	var b1 := t / 0.09
	var b2 := (t - 0.22) / 0.09
	var beat := exp(-b1 * b1) + 0.7 * exp(-b2 * b2)
	_dread_rect.visible = true
	_dread_rect.modulate = Color(1, 1, 1, _dread * (0.35 + 0.65 * beat) * 0.85)


## Darkness crowding in from the edges, with the faintest red in it.
static func _vignette_image() -> Image:
	var w := 192
	var h := 108
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var c := Vector2(w, h) * 0.5
	var half := c.length()
	for y in h:
		for x in w:
			var r := (Vector2(x, y) - c).length() / half
			var a := smoothstep(0.45, 1.0, r)
			img.set_pixel(x, y, Color(0.06, 0.0, 0.01, a))
	return img


## Set alight. Burns for `secs`, and being hit again while burning tops it up
## rather than starting over.
func ignite(secs: float) -> void:
	if _burn_t <= 0.0:
		_toast("On fire!")
	_burn_t = maxf(_burn_t, secs)


## Hit by a glob of webbing. Each one slows you further; enough in a row and
## you are held fast for a moment -- press jump to struggle free sooner.
func webbed(amount: float) -> void:
	_web = minf(_web + amount, WEB_MAX)
	_web_hold = WEB_HOLD
	if _web >= WEB_STUCK_AT and _stuck_t <= 0.0:
		_stuck_t = WEB_STUCK_TIME
		_toast("Stuck fast in webbing -- mash jump to break free!")
	elif _stuck_t <= 0.0:
		_toast("Webbed -- %d%% slower" % int(round((1.0 - _web_mult()) * 100.0)))
	if _web_overlay == null and _ui_layer != null:
		_web_overlay = TextureRect.new()
		_web_overlay.texture = ImageTexture.create_from_image(_web_image())
		_web_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_web_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_web_overlay.stretch_mode = TextureRect.STRETCH_SCALE
		_web_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui_layer.add_child(_web_overlay)
		_ui_layer.move_child(_web_overlay, 0)


var _jump_was_held_web := false


func _web_mult() -> float:
	if _stuck_t > 0.0:
		return 0.0
	return clampf(1.0 - _web * WEB_SLOW, 0.25, 1.0)


func _tick_web(delta: float) -> void:
	if _burn_t > 0.0:
		_burn_t -= delta
		# Standing in water puts it out, which is the obvious thing to try.
		if _in_water(global_position):
			_burn_t = 0.0
		else:
			take_damage(BURN_DPS * delta)
	if _stuck_t > 0.0:
		_stuck_t -= delta
		if _stuck_t <= 0.0:
			# Out -- still gummed up, but able to run.
			_web = minf(_web, 2.0)
			_web_hold = 1.0
	elif _web > 0.0:
		_web_hold -= delta
		if _web_hold <= 0.0:
			_web = maxf(_web - WEB_WEAR * delta, 0.0)
	if _web_overlay != null:
		var a := clampf(_web / WEB_MAX, 0.0, 1.0)
		if _stuck_t > 0.0:
			a = 1.0
		_web_overlay.modulate = Color(1, 1, 1, a * 0.9)
		_web_overlay.visible = a > 0.01


## Webbing across the corners of the view: strands out from each corner and
## sagging threads between them, drawn once.
static func _web_image() -> Image:
	var w := 480
	var h := 270
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var col := Color(0.9, 0.95, 0.85, 0.85)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for c in [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]:
		var corner: Vector2 = c
		var into: Vector2 = (Vector2(w, h) * 0.5 - corner).normalized()
		var base_ang: float = into.angle()
		var reach := rng.randf_range(150.0, 210.0)
		var spokes: Array = []
		for k in 7:
			var ang: float = base_ang + lerpf(-0.8, 0.8, k / 6.0) + rng.randf_range(-0.08, 0.08)
			spokes.append(ang)
			_web_line(img, corner, corner + Vector2.from_angle(ang) * reach * rng.randf_range(0.8, 1.1), col)
		for r in [40.0, 75.0, 110.0, 145.0]:
			for k in spokes.size() - 1:
				var p0: Vector2 = corner + Vector2.from_angle(spokes[k]) * r
				var p1: Vector2 = corner + Vector2.from_angle(spokes[k + 1]) * r
				var mid: Vector2 = (p0 + p1) * 0.5 - into * float(r) * 0.12
				_web_line(img, p0, mid, col * Color(1, 1, 1, 0.8))
				_web_line(img, mid, p1, col * Color(1, 1, 1, 0.8))
	return img


static func _web_line(img: Image, a: Vector2, b: Vector2, col: Color) -> void:
	var n := int(a.distance_to(b)) + 1
	for i in n:
		var p := a.lerp(b, float(i) / n)
		var x := int(p.x)
		var y := int(p.y)
		if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
			img.set_pixel(x, y, col)


func _max_oxygen() -> float:
	return MAX_OXYGEN


# Paint any slot cell from a slot dict. `highlight` toggles the active-slot glow.
## The picture layer for a slot, made the first time that slot needs one.
##
## A child of the swatch rather than a sibling, so it inherits the swatch's rect
## for free -- including the taller one a two-cell item spills into.
func _cell_icon(cell: Dictionary) -> TextureRect:
	var got = cell.get("icon")
	if got != null and is_instance_valid(got):
		return got
	var sw: ColorRect = cell["swatch"]
	var tr := TextureRect.new()
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sw.add_child(tr)
	cell["icon"] = tr
	return tr


func _paint_cell(cell: Dictionary, slot: Dictionary, highlight: bool) -> void:
	var swatch: ColorRect = cell["swatch"]
	var count: Label = cell["count"]
	var icon := _cell_icon(cell)
	var eighths := int(slot.get("eighths", 0)) if not slot.is_empty() else 0
	# Eighths of nothing: a slot that lost its item before the fix that keeps
	# it. There is no telling what they were eighths of, so they are let go
	# rather than left as a pink square that cannot be placed or used.
	if eighths > 0 and int(slot["id"]) == Blocks.AIR:
		slot["eighths"] = 0
		eighths = 0
	if not slot.is_empty() and (slot["count"] > 0 or eighths > 0):
		var mat: Dictionary = slot.get("mat", {})
		var col: Color = mat["color"] if mat.has("color") else Blocks.color_of(slot["id"])
		# A picture where there is one to take, and the flat colour where there
		# is not -- tools have no shape to photograph yet. The swatch stays
		# behind the picture either way, faint, so a slot still reads as full at
		# a glance and a block still reads as its own material.
		var tex := ItemIcon.of(int(slot["id"]), col,
			world.nearest_planet(global_position) if world != null else null)
		icon.texture = tex
		icon.visible = tex != null
		# Less than a whole block is drawn clearly smaller, by how much of one
		# there is: a quarter at a third of the size, seven eighths at half --
		# never close enough to a whole block to be mistaken for one.
		var part: float = 1.0 if int(slot["count"]) > 0 else 0.25 + 0.30 * float(eighths) / 8.0
		icon.pivot_offset = icon.size * 0.5
		icon.scale = Vector2.ONE * part
		swatch.color = Color(col.r, col.g, col.b, 0.22) if tex != null else col
		# Change shown as a real fraction rather than a second number: eighths
		# land exactly on the glyphs a font already has.
		const EIGHTH_GLYPH := ["", "⅛", "¼", "⅜", "½",
			"⅝", "¾", "⅞"]
		var whole: int = int(slot["count"])
		count.text = ("%d%s" % [whole, EIGHTH_GLYPH[eighths]]) if whole > 0 			else EIGHTH_GLYPH[eighths]
		cell["root"].tooltip_text = _item_tooltip(slot)
		var mx := Blocks.max_durability(int(slot["id"]))
		if mx > 0 and whole == 1:
			count.text = ""
		if int(slot["id"]) == Blocks.BATTERY:
			# A battery's bar is its charge, not its wear -- the same bar in the
			# same place, so a glance at a chest full of them tells you which
			# ones are worth carrying.
			count.text = ""
			var held: float = float((slot.get("props", {}) as Dictionary).get("charge", 0.0))
			_paint_wear(cell, int(Blocks.battery_capacity(slot.get("props", {}))), int(held))
		else:
			_paint_wear(cell, mx, int(slot.get("dur", mx)))
	else:
		_paint_wear(cell, 0, 0)
		# Empty: the slot's own frame is the picture of "nothing here".
		swatch.color = Color(0, 0, 0, 0)
		icon.texture = null
		icon.visible = false
		count.text = ""
		cell["root"].tooltip_text = ""
	# The slot in hand gets the gold frame. Restyled only when it changes, not
	# every time the bag is repainted.
	if bool(cell.get("selected", false)) != highlight:
		cell["selected"] = highlight
		_style_slot(cell["root"], highlight)


# Hover text. Raw ore stays unidentified (tier & stats hidden); a refined material
# shows its tier and property bars. Source planet is shown for both.
func _item_tooltip(slot: Dictionary) -> String:
	var id: int = slot["id"]
	var mat: Dictionary = slot.get("mat", {})
	var mname: String = mat.get("name", Blocks.name_of(id))
	var src: String = slot.get("src", "")
	var suffix := ("  ·  " + src) if src != "" else ""
	var mx := Blocks.max_durability(id)
	if mx > 0:
		var base := _item_tooltip_base(slot)
		return "%s\nDurability %d / %d" % [base, int(slot.get("dur", mx)), mx]
	return _item_tooltip_base(slot)


func _item_tooltip_base(slot: Dictionary) -> String:
	var id: int = slot["id"]
	var mat: Dictionary = slot.get("mat", {})
	var mname: String = mat.get("name", Blocks.name_of(id))
	var src: String = slot.get("src", "")
	var suffix := ("  ·  " + src) if src != "" else ""
	if Cosmetics.is_cosmetic(id):
		return "%s\nCosmetic  ·  %s — wear it from the Vanity tab" % [
			Cosmetics.name_of(id), Cosmetics.SLOT_NAMES.get(Cosmetics.slot_of(id), "")]
	if id == Blocks.DRILL:
		var power := float(mat.get("power", 1.0))
		return "%s Drill%s\nMining power %.1f — breaks up to Tier %d" % [
			mname, suffix, power, Blocks.max_tier_for_power(power)]
	if id == Blocks.SUIT:
		return "%s Insulated Suit%s\nHazard resist %d%%" % [
			mname, suffix, int(round(float(mat.get("resist", 0.0)) * 100.0))]
	# A seed is the one item whose whole value is what it BECOMES, and until now
	# it said only whose seed it was. Two species can sit identically in the bag
	# and be a meal and a shirt.
	if id == Blocks.SEEDS or id == Blocks.SAPLING:
		var sprops: Dictionary = slot.get("props", {})
		var key := str(sprops.get("species", ""))
		var lines := ["%s%s" % [mname, suffix]]
		if id == Blocks.SAPLING:
			lines.append("Plant on grass or dirt, and it grows into a tree")
		elif key != "":
			var g: Dictionary = Blocks.crop_growth(key)
			lines.append(Blocks.crop_use_text(key))
			lines.append("%d stages, about %ds to ripen" % [
				int(g.get("stages", 3)), int(g.get("time", 180.0))])
		var cls := str(sprops.get("class", ""))
		if cls != "":
			lines.append("From a class %s world" % cls)
		return "
".join(lines)
	if Blocks.is_ore(id):
		return "%s Ore%s\nUnidentified — refine to reveal its tier & stats" % [mname, suffix]
	if Blocks.is_refined(id):
		var tier: int = int(mat.get("tier", 0))
		var props: Dictionary = slot.get("props", {})
		var lines := ["%s Ingot%s  (%s · Tier %d)" % [mname, suffix, Blocks.TIER_NAMES[tier], tier]]
		for k in Blocks.PROP_KEYS:
			lines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(props.get(k, 0))])
		# What those two numbers MEAN, now that they decide different things. A
		# list of scores is not a decision until something says which way round
		# they cut.
		lines.append(Blocks.ore_verdict(props))
		lines.append("%d plate per ingot, %d wire per bar" % [
			Blocks.plate_yield(props), Blocks.wire_yield(props)])
		var stg := Blocks.smith_stages(props)
		lines.append("On the anvil: bar at %d blows, sheet at %d, plate at %d" % [
			int(stg[0]), int(stg[1]), int(stg[2])])
		return "\n".join(lines)
	if Blocks.is_intermediate(id):
		var itier: int = int(mat.get("tier", 0))
		var iprops: Dictionary = slot.get("props", {})
		var ilines := ["%s — %s%s  (%s · Tier %d)" % [
			Blocks.name_of(id), mname, suffix, Blocks.TIER_NAMES[itier], itier]]
		for k in Blocks.PROP_KEYS:
			ilines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(iprops.get(k, 0))])
		if Blocks.use_of(id) != "":
			ilines.append(Blocks.use_of(id))
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
			if s["count"] == 0 and int(s.get("eighths", 0)) <= 0:
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
			if s["count"] == 0 and int(s.get("eighths", 0)) <= 0:
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
			parts.append("%d Ingot%s" % [int(r["n"]), "" if int(r["n"]) == 1 else "s"])
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

const _LEFT_W := 250   # left column (blueprints/actions) width
const _MULTI_W := 40   # each of the x5 / All buttons beside a craft
## Height of the recipe column. Eight rows: the point of the list is that
## everything a bench can make is ON it, including what you cannot afford
## yet, so it is worth the height to see the lot without scrolling.
## How tall one recipe row is. The buttons, the spacing between them and the
## box they scroll in all have to agree, or the last row is clipped.
const CRAFT_ROW_H := 38
const CRAFT_LIST_H := 312
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

	# The same switch as the lever on a generator's front, for when you have
	# the panel open anyway or the generator is one you built out of blocks
	# and has no lever to pull.
	_gen_switch_btn = Button.new()
	_gen_switch_btn.position = Vector2(12, 62)
	_gen_switch_btn.custom_minimum_size = Vector2(_LEFT_W, 36)
	_gen_switch_btn.visible = false
	_gen_switch_btn.pressed.connect(func():
		if _station_open != null and is_instance_valid(_station_open):
			_throw_gen_switch(_station_open))
	_station_panel.add_child(_gen_switch_btn)

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
	# EVERYTHING this bench can make is listed, always -- a recipe you cannot
	# afford is the one you most need to see, because it is the one telling you
	# what to go and find. What changes is the order and the colour: the ones
	# you can make now come first and read normally, the rest sit under them
	# greyed. Nothing appears or disappears as you load material, so the list
	# never moves under your cursor for a reason you did not cause.
	var ready: Array = []
	var later: Array = []
	for craft in crafts:
		if st.can_make(craft):
			ready.append(craft)
		else:
			later.append(craft)
	var ordered: Array = ready + later
	var craft_top := 62.0 + (34.0 if is_smelter else 0.0)
	_craft_scroll.position = Vector2(12, craft_top)
	for b2 in _craft_multi:
		b2.queue_free()
	_craft_multi.clear()
	var by := 0.0
	var main_w := _LEFT_W - 2 * (_MULTI_W + 4)
	var planet: Planet = world.nearest_planet(global_position) if world != null else null
	for craft in ordered:
		var can: bool = st.can_make(craft)
		var out_id: int = int(craft.get("out", Blocks.AIR))
		var b := Button.new()
		b.text = " " + str(craft["label"])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# A picture of the thing, taken of the real model (see ItemIcon), so the
		# list reads as a shelf of what this bench makes rather than as prose.
		var tex := ItemIcon.of(out_id, Blocks.color_of(out_id), planet)
		if tex != null:
			b.icon = tex
			b.expand_icon = true
		b.position = Vector2(0, by)
		b.custom_minimum_size = Vector2(main_w, CRAFT_ROW_H - 4)
		b.size = Vector2(main_w, CRAFT_ROW_H - 4)
		b.clip_text = true
		b.tooltip_text = _craft_tooltip(st, craft)
		b.disabled = not can
		b.modulate = Color(1, 1, 1, 1) if can else Color(1, 1, 1, 0.45)
		b.pressed.connect(_on_station_craft.bind(craft, 1))
		_craft_row.add_child(b)
		_craft_buttons.append(b)
		# Five, and as many as what is loaded will make.
		var x := main_w + 4
		for opt in [[5, "x5", "Make five"], [0, "All", "Make as many as the loaded material allows"]]:
			var mb := Button.new()
			mb.text = str(opt[1])
			mb.tooltip_text = str(opt[2])
			mb.position = Vector2(x, by)
			mb.custom_minimum_size = Vector2(_MULTI_W, CRAFT_ROW_H - 4)
			mb.size = Vector2(_MULTI_W, CRAFT_ROW_H - 4)
			mb.disabled = not can
			mb.modulate = b.modulate
			mb.pressed.connect(_on_station_craft.bind(craft, int(opt[0])))
			_craft_row.add_child(mb)
			_craft_multi.append(mb)
			x += _MULTI_W + 4
		by += float(CRAFT_ROW_H)
	_craft_row.custom_minimum_size = Vector2(_LEFT_W, by)
	_craft_sig = _craft_signature(st)


## What the craft list currently WOULD look like: every recipe and whether it
## can be made. The list is rebuilt when this changes and at no other time --
## so it re-sorts the moment you load the last rock you needed, and never
## moves under your cursor when nothing has.
func _craft_signature(st) -> String:
	var parts: Array = []
	var key: int = Blocks.SMELTER if Blocks.is_smelter_kind(st.kind) else st.kind
	var list: Array = Blocks.STATION_CRAFTS.get(key, [])
	if st.kind == Blocks.SHAPER:
		list = _shaper_crafts(st)
	for c in list:
		parts.append("%s:%s" % [str(c.get("label", "")), "1" if st.can_make(c) else "0"])
	return "|".join(PackedStringArray(parts))


## What a recipe costs and how much of it is loaded, for the hover. Every line
## reads "have / need" so the shortfall is the thing you see, not something you
## work out.
func _craft_tooltip(st, craft: Dictionary) -> String:
	var lines: Array = [str(craft["label"])]
	var n := int(craft.get("n", 1))
	if bool(craft.get("yield_from_material", false)):
		lines.append("Makes: depends on the material")
	elif n > 1:
		lines.append("Makes %d" % n)
	lines.append("")
	if craft.has("reqs"):
		for r in craft["reqs"]:
			var need := int(r["n"])
			lines.append("%s  %d / %d" % [_req_name(r), st.req_have(r), need])
	else:
		var mtype := Blocks.primary_material_for(st.kind)
		var cost := int(craft.get("cost", 1))
		lines.append("%s  %d / %d" % [_material_name(mtype), st.primary_have(), cost])
		if craft.has("extra"):
			var ex: Dictionary = craft["extra"]
			lines.append("%s  %d / %d" % [_req_name(ex), st.req_have(ex), int(ex["n"])])
	if not st.can_make(craft):
		lines.append("")
		lines.append("Not enough loaded")
	return "\n".join(PackedStringArray(lines))


## What a requirement is called, in the words the recipe itself uses where it
## gives them.
func _req_name(r: Dictionary) -> String:
	if r.has("label"):
		return str(r["label"])
	if r.has("refined"):
		return "Refined material"
	if r.has("any"):
		var ids: Array = r["any"]
		return Blocks.name_of(int(ids[0])) if not ids.is_empty() else "Material"
	return Blocks.name_of(int(r.get("id", Blocks.AIR)))


func _material_name(mtype: String) -> String:
	match mtype:
		"refined":
			return "Refined material"
		"circuit":
			return Blocks.name_of(Blocks.CIRCUIT)
		"alloy":
			return Blocks.name_of(Blocks.ALLOY)
		_:
			return "Material"



## Labels currently shown, so a dynamic list is only torn down and rebuilt when
## it actually changed (rebuilding every frame would fight clicks and focus).
func _craft_button_labels() -> Array:
	var out: Array = []
	for b in _craft_buttons:
		out.append(b.text)
	return out


## A bed has no contents, so right-clicking one claims it instead of opening
## it. Claiming is the whole feature for now: it is the half that behaves
## identically alone and in co-op, where skipping the night has to decide whose
## night it is.
## `along` is the direction the bed's long side runs, or ZERO if unknown. You
## lie ALONG a bed, not across it, so the view turns to match it -- which is
## most of what makes it read as a bed rather than as a spot on the floor.
func _use_bed(st: Station, along: Vector3 = Vector3.ZERO) -> void:
	if world == null:
		return
	var p := world.nearest_planet(st.global_position)
	bed_planet = p.planet_name if p != null else ""
	# Stored a little above the frame so waking does not start you inside it.
	# The planet's up, not the world's. On a cube world those are the same only
	# on one face, and a bed on any other would have woken you sideways.
	var up := Vector3.UP
	if p != null:
		up = p._axis_of(p.to_local(st.global_position))
		if up == Vector3.ZERO:
			up = Vector3.UP
		up = (p.global_transform.basis * up).normalized()
	bed_pos = st.global_position + up * 1.2
	_bed_planet_now = p
	in_bed = true
	# Tipped back over the next half second rather than snapped, and only for
	# that half second -- after it you are free to look wherever you like from
	# where you are lying.
	_bed_settle = BED_SETTLE
	_bed_yaw_to = Vector3.ZERO
	if along != Vector3.ZERO:
		var up_now := global_transform.basis.y.normalized()
		# Flatten it onto the ground plane: the bed's axis and the player's
		# facing have to be compared in the same plane or the turn is wrong on
		# any slope.
		var flat := (along - up_now * along.dot(up_now)).normalized()
		if flat.length() > 0.01:
			# Either end of the bed will do. Take whichever is the shorter turn
			# from where you were already looking, so lying down never spins you
			# most of the way round.
			var fwd := -global_transform.basis.z
			_bed_yaw_to = flat if flat.dot(fwd) >= 0.0 else -flat
	velocity = Vector3.ZERO
	global_position = bed_pos
	if p != null and p.is_night():
		_open_sleep_prompt(p)
	else:
		_toast("Resting. Move to get up.")


## Night, and something to decide. During the day lying down just heals, so
## there is nothing to ask.
func _open_sleep_prompt(p: Planet) -> void:
	if _bed_panel != null:
		return
	_bed_panel = Control.new()
	_bed_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bed_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bed_panel.add_child(center)
	var box := PanelContainer.new()
	center.add_child(box)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	box.add_child(vb)
	var head := Label.new()
	head.text = "Sleep through the night?"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 18)
	vb.add_child(head)
	if world != null and world.net != null and world.net.active:
		var note := Label.new()
		note.text = "This ends the night for everyone."
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.add_theme_font_size_override("font_size", 13)
		note.modulate = Color(1, 1, 1, 0.65)
		vb.add_child(note)
	var yes := Button.new()
	yes.text = "Sleep until morning"
	yes.custom_minimum_size = Vector2(240, 38)
	yes.pressed.connect(_confirm_sleep.bind(p))
	vb.add_child(yes)
	var no := Button.new()
	no.text = "Just lie down"
	no.custom_minimum_size = Vector2(240, 32)
	no.pressed.connect(_close_sleep_prompt)
	vb.add_child(no)
	_ui_layer.add_child(_bed_panel)
	menu_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_sleep_prompt() -> void:
	if _bed_panel != null:
		_bed_panel.queue_free()
		_bed_panel = null
	menu_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _confirm_sleep(p: Planet) -> void:
	_close_sleep_prompt()
	if world != null and p != null:
		world.sleep_through_night(p)
	_get_up()
	_toast("Morning.")


## Out of bed, however it ended.
func _get_up() -> void:
	if not in_bed:
		return
	in_bed = false
	_bed_settle = 0.0
	_bed_yaw_to = Vector3.ZERO
	# Level again on the way out. Standing up still looking at the ceiling is
	# the sort of thing that has you walking into a wall.
	_pitch = clampf(_pitch, -1.45, 0.35)
	if _camera != null:
		_camera.rotation.x = _pitch
	_bed_planet_now = null
	_close_sleep_prompt()


func _open_station(st: Station) -> void:
	# A battery cradle has no inventory to open. Right-clicking it IS the
	# action: take the battery out, put one in, or swap the one in your hand
	# for the one in the bay. One click, whichever of those it turns out to be.
	if st.kind == Blocks.POWER_BAY:
		_swap_bay_battery(st)
		return
	# Likewise the anvil: nothing to open. Right-click puts a piece on it or
	# takes the piece off; the hammer does the rest.
	if st.kind == Blocks.ANVIL:
		_use_anvil(st)
		return
	_station_open = st
	st.lid_open = true
	if inv_open:
		_toggle_inventory()
	_station_title.text = st.title()
	_station_store_label.text = "%s contents  (drag to move)" % st.title()
	if st.kind == Blocks.SHAPER:
		_station_store_label.text = "Input a block, take the shapes out"
	var is_gen: bool = st.kind == Blocks.GENERATOR
	if is_gen:
		# Each bay carries its own caption (see _build_storage_cells).
		_station_store_label.text = ""
	var is_smelter: bool = Blocks.is_smelter_kind(st.kind)
	_refine_btn.visible = is_smelter
	_gen_switch_btn.visible = is_gen

	_rebuild_craft_buttons(st)
	var has_left: bool = is_smelter or not _craft_buttons.is_empty() or is_gen
	_left_header.visible = has_left
	_left_header.text = "Actions" if is_smelter else ("Switch" if is_gen else "Blueprints")

	# preview + job label sit just below the action/blueprint buttons (same spot;
	# only one shows at a time -- preview when idle, progress when working)
	# Measured from the SCROLLER, which is what actually occupies the column now:
	# the buttons inside it can be taller than the space they are shown in, and
	# the labels below have to sit under the visible box, not under the list.
	var col_h: int = mini(_craft_buttons.size() * CRAFT_ROW_H, CRAFT_LIST_H) 		if not _craft_buttons.is_empty() else 34
	_craft_scroll.custom_minimum_size = Vector2(_LEFT_W + 14, col_h)
	_craft_scroll.size = Vector2(_LEFT_W + 14, col_h)
	var left_bottom: int = int(_craft_scroll.position.y) + col_h
	_preview_label.position = Vector2(14, left_bottom + 8)
	_preview_label.visible = not _craft_buttons.is_empty() or st.kind == Blocks.SHAPER
	_job_label.position = Vector2(14, left_bottom + 8)
	if is_gen:
		# Under the switch, not under the empty recipe list.
		left_bottom = 62 + 36 + 60
		_preview_label.position = Vector2(14, 62 + 36 + 12)
		_preview_label.visible = true

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
	_fit_panel(_station_panel)

	_station_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_station_ui()


## Blow a menu up to fill most of the screen, centred. The UI is laid out in
## pixels, so on a big monitor it used to sit small in the middle; scaling the
## whole panel keeps every slot, drag and tooltip lined up with what is drawn.
const PANEL_FILL := Vector2(0.62, 0.64)
const PANEL_MAX_SCALE := 1.6

func _fit_panel(p: Control) -> void:
	if p == null or not p.is_inside_tree():
		return
	var vp := get_viewport().get_visible_rect().size
	var sz := p.size
	if sz.x <= 0.0 or sz.y <= 0.0:
		return
	var s := clampf(minf(vp.x * PANEL_FILL.x / sz.x, vp.y * PANEL_FILL.y / sz.y), 1.0, PANEL_MAX_SCALE)
	p.set_anchors_preset(Control.PRESET_TOP_LEFT)
	p.pivot_offset = Vector2.ZERO
	p.scale = Vector2.ONE * s
	p.position = ((vp - sz * s) * 0.5).round()


## A window resized while a menu is open refits it.
func _refit_panels() -> void:
	for p in [_inv_panel, _station_panel, _book_panel]:
		if p != null and (p as Control).visible:
			_fit_panel(p)


func _close_station() -> void:
	if _station_open != null and is_instance_valid(_station_open):
		_station_open.lid_open = false
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
		var cell := _make_stor_cell(idx, pl["cx"], pl["cy"])
		_station_cells.append(cell)
		if st.kind == Blocks.GENERATOR and int(pl["slot"]) < 2:
			var cap := Label.new()
			cap.text = "BATTERY" if int(pl["slot"]) == 0 else "FUEL"
			cap.modulate = Color(1, 1, 1, 0.7)
			cap.position = Vector2(0, -22)
			cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			(cell["root"] as Control).add_child(cap)
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
	elif st.kind == Blocks.GENERATOR:
		# The cradle and the hopper, set apart so they read as two bays with a
		# job each rather than a row of storage. Anything left over from when
		# this was a six-slot bunker sits on a row beneath them to be taken out.
		for slot in st.storage.size():
			if slot < 2:
				out.append({"st": st, "slot": slot, "cx": slot * 2, "cy": 0})
			else:
				out.append({"st": st, "slot": slot, "cx": (slot - 2) % _STORE_COLS,
					"cy": 1 + (slot - 2) / _STORE_COLS})
	else:
		for slot in st.storage.size():
			out.append({"st": st, "slot": slot, "cx": slot % _STORE_COLS, "cy": slot / _STORE_COLS})
	return out


func _make_stor_cell(index: int, cx: int, cy: int) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(INV_CELL, INV_CELL)
	root.size = Vector2(56, 56)
	root.position = Vector2(cx * 60, cy * 60)
	_style_slot(root, false)
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
			# Opened again, not just refilled: the list was sized for what it
			# held when the panel opened -- nothing -- so a loaded block showed
			# one option and a scrollbar instead of all of them.
			_open_station(_station_open)
			return
	# ...and every other bench re-sorts when what you can afford changes: the
	# ones you can make now belong at the top, and "now" moves as you load.
	if _station_open.kind != Blocks.SHAPER \
			and _craft_signature(_station_open) != _craft_sig:
		_rebuild_craft_buttons(_station_open)
	if _station_open.kind == Blocks.GENERATOR:
		var on: bool = _station_open.switched_on
		_gen_switch_btn.text = "ON  --  click to switch off" if on else "OFF  --  click to switch on"
		_gen_switch_btn.modulate = Color(0.75, 1.0, 0.75) if on else Color(1.0, 0.75, 0.7)
		_preview_label.text = _craft_preview_text(Blocks.GENERATOR)
		_job_label.visible = false
		return
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
		var lines: Array = ["Stored power %d%%" % int(pct)]
		if st.gen_has_battery():
			var bp: Dictionary = st.gen_battery().get("props", {})
			var bpct := int(round(float(bp.get("charge", 0.0))
				/ maxf(Blocks.battery_capacity(bp), 1.0) * 100.0))
			lines.append("Battery %d%%%s" % [bpct, "  (full)" if bpct >= 100 else ""])
		else:
			lines.append("No battery in the cradle")
		if not st.switched_on:
			lines.append("Switched off.")
		elif st.burn_t > 0.0:
			lines.append("Burning: +%.1f/s, %.0fs left on this lump" % [st.burn_rate, st.burn_t])
		elif int(st.gen_fuel().get("count", 0)) <= 0:
			lines.append("Hopper empty -- put in ore with Combustion.")
		elif st.power >= Station.POWER_MAX:
			lines.append("Full -- waiting for somewhere to put it.")
		else:
			lines.append("Idle.")
		return "\n".join(lines)
	# Every bench is just its list of what it makes. The line of instructions
	# that used to sit under it ("Load Wood, Rock, and Metal to build", the
	# loaded material's stats) went: the list already says what the bench is
	# for, and clicking one you cannot afford says what is missing.
	return ""


func _on_station_craft(craft: Dictionary, times: int = 1) -> void:
	if _station_open == null:
		return
	var r := _station_open.start_craft(craft, times)
	if r == -1:
		_toast("Busy…")
	elif r == 0:
		if craft.has("reqs"):
			_toast("Missing materials")
		else:
			var mtype := Blocks.primary_material_for(_station_open.kind)
			var mat_label: String = {"refined": "Ingots", "circuit": "Circuitry",
				"alloy": "Alloy Plating"}.get(mtype, "material")
			var msg := "Need %d %s loaded" % [int(craft["cost"]), mat_label]
			if craft.has("extra"):
				msg += ", plus " + Blocks.req_text(craft["extra"])
			_toast(msg)
	elif r > 1 and craft.has("reqs"):
		_toast("Crafting %s ×%d…" % [Blocks.name_of(int(craft["out"])), r])
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
			_target_label.text = _look_name if show_look_names else ""

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
	var tool_txt := "bare hands"
	if mine_power > 1.0:
		tool_txt = "Drill (power %.1f, T%d)" % [mine_power,
			Blocks.max_tier_for_power(mine_power)]
	else:
		# The basic tools, named so you can see at a glance what you are missing.
		var carried: Array = []
		for tid in [Blocks.PICK, Blocks.AXE, Blocks.SPADE]:
			if float(_class_power.get(str(Blocks.TOOLS[tid]["class"]), 1.0)) > 1.0:
				carried.append(str(Blocks.TOOLS[tid]["label"]))
		if not carried.is_empty():
			tool_txt = " + ".join(carried)
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
	# Which part of the world, when the world is big enough to have parts. A
	# region you can see the edge of but cannot name is scenery; a named one is
	# somewhere you can tell somebody to meet you.
	if p != null and p.has_biomes():
		var bn: String = p.biome_at(global_position)
		if bn != "":
			pname = "%s  ·  %s" % [pname, bn]
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


## Right-click a Power Bay, or a Generator's cradle. What happens depends on
## what is in each hand: a battery in yours goes in (and whatever was in the
## cradle comes out into your hand), an empty hand takes the cradle's battery,
## and an empty hand at an empty cradle says so rather than doing nothing
## silently.
func _swap_bay_battery(bay: Station) -> void:
	var is_gen: bool = bay.kind == Blocks.GENERATOR
	var held: Dictionary = inv[active_slot] if active_slot >= 0 and active_slot < inv.size() else {}
	var holding_battery: bool = Station.holds_power(int(held.get("id", Blocks.AIR))) \
		and int(held.get("count", 0)) > 0
	var in_bay: bool = bay.gen_has_battery() if is_gen else bay.bay_has_battery()
	if not holding_battery and not in_bay:
		_toast("The cradle is empty -- put a battery in it")
		return
	var giving: Dictionary = {}
	if holding_battery:
		# One battery, not the stack: the cradle holds exactly one.
		giving = held.duplicate(true)
		giving["count"] = 1
	var came_out: Dictionary = bay.gen_swap_battery(giving) if is_gen else bay.bay_swap(giving)
	if holding_battery:
		_take_one_from_active()
	if not came_out.is_empty():
		var left := _add_item(int(came_out["id"]), int(came_out.get("count", 1)),
			came_out.get("props", {}))
		if left > 0:
			# Nowhere to put it: leave it where it was rather than destroying it.
			if is_gen:
				bay.gen_swap_battery(came_out)
			else:
				bay.bay_swap(came_out)
			if holding_battery:
				_add_item(int(giving["id"]), 1, giving.get("props", {}))
			_toast("No room for the battery you are holding")
			return
	var pct := 0
	if is_gen:
		var bp: Dictionary = bay.gen_battery().get("props", {})
		pct = int(round(float(bp.get("charge", 0.0)) / maxf(Blocks.battery_capacity(bp), 1.0) * 100.0))
	else:
		pct = int(round(ShipComputer.battery_charge(bay) / maxf(ShipComputer.bay_capacity(bay), 1.0) * 100.0))
	if holding_battery and not came_out.is_empty():
		_toast("Battery swapped -- %d%%" % pct)
	elif holding_battery:
		_toast("Battery seated -- %d%%" % pct)
	else:
		_toast("Battery removed")
	_refresh_slots()


## Right-clicking a generator's MODEL means the part you clicked: the lever
## throws the switch, the cradle on top takes or gives a battery, and the
## hopper beside it takes the fuel in your hand or gives back what is in it.
## Anywhere else on it opens its panel. Returns whether a part was used.
func _use_generator_part(st: Station) -> bool:
	if st.kind != Blocks.GENERATOR or st.headless or not _ray.is_colliding():
		return false
	# Into the model's own space, which stands on the floor of its cell.
	var p: Vector3 = st.to_local(_ray.get_collision_point()) + Vector3(0, 0.5, 0)
	# The front face, to the right of the firebox window, is the lever's.
	if p.z < -0.42 and p.x > 0.12 and p.y > 0.08:
		_throw_gen_switch(st)
		return true
	if p.y < StationModels.GEN_TOP - 0.03:
		return false
	if p.x < 0.0:
		_swap_bay_battery(st)
		return true
	return _use_gen_hopper(st)


## The hopper, from the outside. Fuel in your hand goes in -- the whole
## stack, since shovelling ore in one lump at a time would be a chore -- and
## an empty hand takes back what is in there. Anything else is refused by name.
func _use_gen_hopper(st: Station) -> bool:
	var held: Dictionary = inv[active_slot] if active_slot >= 0 and active_slot < inv.size() else {}
	var hid := int(held.get("id", Blocks.AIR))
	var hopper: Dictionary = st.gen_fuel()
	var has_fuel: bool = int(hopper.get("count", 0)) > 0
	if int(held.get("count", 0)) <= 0:
		if not has_fuel:
			return false   # nothing either side: open the panel instead
		var out: Dictionary = st.gen_swap_fuel({})
		var left := _add_item(int(out["id"]), int(out["count"]), out.get("props", {}),
			out.get("src", ""), out.get("mat", {}))
		if left > 0:
			out["count"] = left
			st.gen_swap_fuel(out)
			_toast("No room for all of it")
		else:
			_toast("Took the fuel out of the hopper")
		_refresh_slots()
		return true
	if not Blocks.is_fuel(hid, held.get("props", {})):
		_toast("%s won't burn -- the hopper takes ore with Combustion" % Blocks.name_of(hid))
		return true
	if has_fuel and (int(hopper["id"]) != hid or hopper.get("src", "") != held.get("src", "")):
		# A different ore: swap them, so the one you were holding burns next.
		var giving: Dictionary = held.duplicate(true)
		var was: Dictionary = st.gen_swap_fuel(giving)
		_clear_slot(inv[active_slot])
		_copy_slot(was, inv[active_slot])
		_toast("Swapped the fuel in the hopper")
	elif has_fuel:
		hopper["count"] = int(hopper["count"]) + int(held["count"])
		_clear_slot(inv[active_slot])
		_toast("Hopper: %d %s" % [int(hopper["count"]), Blocks.name_of(hid)])
	else:
		st.gen_swap_fuel(held.duplicate(true))
		_clear_slot(inv[active_slot])
		_toast("Hopper: %d %s" % [int(st.gen_fuel()["count"]), Blocks.name_of(hid)])
	_sync_cover(active_slot)
	_refresh_slots()
	_refresh_station_ui()
	return true


## Throw a generator's switch, from its lever or its panel.
func _throw_gen_switch(st: Station) -> void:
	var on := st.gen_toggle()
	Audio.ui("ui_toggle_on" if on else "ui_toggle_off")
	if on and not st.active:
		_toast("Switched on -- but it is damaged, replace the missing block")
	elif on:
		_toast("Generator on")
	else:
		_toast("Generator off")
	_refresh_station_ui()


# --- smithing ---------------------------------------------------------------------

## Right-click an anvil.
##
## Empty, and holding something workable: one goes on the face and the rest of
## the stack is set down beside it, to be worked one after another.
##
## With a WORKED piece on it: that comes off as whatever it has been beaten
## into, and the next one slides on from the pile.
##
## With an unworked ingot on it: holding more of the same adds them to the
## pile; anything else (or nothing) takes the ingot and the pile back.
func _use_anvil(st: Station) -> void:
	var face: Vector3 = _anvil_face(st)
	var held: Dictionary = _active_item()
	var hid := int(held.get("id", Blocks.AIR))
	var hn := int(held.get("count", 0))
	var piece := st.anvil_piece()
	if not piece.is_empty():
		# Worked = struck at least once since it went on (a bar goes on already
		# at the bar's count of blows, so that is where "unworked" starts).
		var worked: bool = int(piece.get("hits", 0)) > Blocks.smith_hits_of(
			int(piece.get("id", Blocks.AIR)), piece.get("props", {}))
		if not worked and hn > 0 and st.anvil_pile_fits(held) and _same_stock(held, piece):
			var put := st.anvil_pile_add(held, hn)
			_take_from_active(put)
			Audio.at("place_metal", face)
			_toast("%d more on the pile -- %d waiting" % [put, st.anvil_pile_count()])
			_refresh_slots()
			return
		if not _anvil_take_off(st, not worked):
			return
		Audio.at("place_metal", face)
		if worked and st.anvil_feed():
			_toast(_last_took + "  --  next one on (%d left)" % st.anvil_pile_count())
		else:
			_toast(_last_took)
		_refresh_slots()
		return
	if hn <= 0:
		_toast("Put an ingot on the anvil, then strike it with a hammer")
		return
	if hid == Blocks.SCRAP:
		_toast("Scrap will not take shape -- remelt it at a smelter first")
		return
	if hid == Blocks.METAL:
		_toast("That is already plate")
		return
	if not Station.anvil_takes(hid):
		_toast("Only ingots, bars and sheets can be worked on an anvil")
		return
	st.anvil_put(held)
	var rest := st.anvil_pile_add(held, hn - 1) if st.anvil_pile_fits(held) else 0
	_take_from_active(1 + rest)
	Audio.at("place_metal", face)
	if rest > 0:
		_toast("On the anvil: %s, and %d more waiting -- strike it with a hammer" % [
			_smith_name(held), rest])
	else:
		_toast("On the anvil: %s -- strike it with a hammer" % _smith_name(held))
	_refresh_slots()


var _last_took := ""


## Take the face (and, with `and_pile`, the pile) back into the bag. All of it
## fits or none of it moves: half a stack of plates lost to a full bag would be
## the worst way to learn. Leaves what it said in _last_took.
func _anvil_take_off(st: Station, and_pile: bool) -> bool:
	var before_inv: Array = inv.duplicate(true)
	var before: Array = st.storage.duplicate(true)
	var got := st.anvil_take()
	if and_pile:
		var pile := st.anvil_pile_take()
		if not pile.is_empty():
			got.append(pile)
	var counts := {}     # name -> how many, so an ingot and its pile read as one
	var order: Array = []
	for it in got:
		var d: Dictionary = it
		if _add_item(int(d["id"]), int(d["count"]), d.get("props", {}),
				str(d.get("src", "")), d.get("mat", {})) > 0:
			inv = before_inv
			st.storage = before
			st._refresh_anvil()
			_toast("No room in your bag for it")
			Audio.ui("ui_deny")
			return false
		var nm := _smith_name(d)
		if not counts.has(nm):
			order.append(nm)
		counts[nm] = int(counts.get(nm, 0)) + int(d["count"])
	var said := PackedStringArray()
	for nm2 in order:
		said.append("%d %s" % [int(counts[nm2]), nm2])
	_last_took = ("Took back " if and_pile else "Took off ") + ", ".join(said)
	return true


## Is `a` the same metal in the same form as the piece `p` went on as?
func _same_stock(a: Dictionary, p: Dictionary) -> bool:
	return int(a.get("id", -1)) == int(p.get("id", -2)) \
		and str(a.get("src", "")) == str(p.get("src", ""))


## Take `n` off the stack in your hand.
func _take_from_active(n: int) -> void:
	for i in n:
		_take_one_from_active()


## Left-click at an anvil with something on it. With a hammer, each click is a
## blow; without one it says what you need. Either way it is not a request to
## take the anvil apart, which is what a held click on a station usually is --
## so this answers the click first and returns true when it has.
const STRIKE_CD := 0.2


func _process_anvil_strike(st: Station, lmb_pressed: bool) -> bool:
	if not is_instance_valid(st) or st.kind != Blocks.ANVIL or st.anvil_piece().is_empty():
		return false
	_look_name = _anvil_look(st)
	if not lmb_pressed:
		return true
	if _selected_id() != Blocks.HAMMER:
		_toast("Strike it with a hammer -- or right-click to take it off")
		return true
	if _attack_cd > 0.0:
		return true
	_attack_cd = STRIKE_CD
	_swing_t = 0.0
	var before := st.anvil_shape()
	if before == "scrap":
		_toast("It is scrap now -- right-click to take it off")
		return true
	var now := st.anvil_strike()
	_wear_held(1)
	var face := _anvil_face(st)
	if now == "scrap":
		Audio.at("forge_scrap", face)
		_spark_burst(face, 10, Color(0.55, 0.5, 0.45))
		_toast("Overworked -- it's scrap. Remelt it at a smelter")
		return true
	Audio.at("forge_strike", face)
	_spark_burst(face, 16 + 4 * ["ingot", "bar", "sheet", "plate", "cracking"].find(now),
		Color(1.0, 0.62, 0.18), now != before)
	if now != before:
		match now:
			"bar":
				_toast("It's a bar now")
			"sheet":
				_toast("It's a sheet now")
			"plate":
				_toast("It's plate -- right-click to take it off. More blows will crack it")
			"cracking":
				_toast("It's cracking! One more blow and it's scrap -- take it off now")
	return true


## What the look line says over an anvil: what is on it, how far it is from
## the next shape, and how many are waiting.
func _anvil_look(st: Station) -> String:
	var line := _anvil_look_piece(st)
	var n := st.anvil_pile_count()
	return line + ("   ·   %d waiting" % n if n > 0 else "")


func _anvil_look_piece(st: Station) -> String:
	var p := st.anvil_piece()
	var shape := st.anvil_shape()
	var props: Dictionary = p.get("props", {})
	var mname := str((p.get("mat", {}) as Dictionary).get("name", ""))
	var stg := Blocks.smith_stages(props)
	var hits := int(p.get("hits", 0))
	match shape:
		"ingot":
			return "%s ingot  (%d more blows to a bar)" % [mname, int(stg[0]) - hits]
		"bar":
			return "%s bar  (%d more to a sheet · right-click to take it)" % [mname, int(stg[1]) - hits]
		"sheet":
			return "%s sheet  (%d more to plate · right-click to take it)" % [mname, int(stg[2]) - hits]
		"plate":
			return "%s plate, %d pieces  (take it now -- another blow cracks it)" % [
				mname, Blocks.plate_yield(props)]
		"cracking":
			return "%s plate, CRACKING  (right-click to save it -- one more blow is scrap)" % mname
	return "Scrap  (right-click to take it off, then remelt it)"


## An item's name as smithing talks about it: "Ferrite ingot", "Ferrite bar".
func _smith_name(d: Dictionary) -> String:
	var id := int(d.get("id", Blocks.AIR))
	var mname := str((d.get("mat", {}) as Dictionary).get("name", ""))
	if id == Blocks.METAL:
		return "Hull Plate"
	var what := "Ingot" if Blocks.is_refined(id) else Blocks.name_of(id)
	return ("%s %s" % [mname, what.to_lower()]).strip_edges() if mname != "" else what


## The top of the anvil's face, in the world: where blows land and sparks fly.
func _anvil_face(st: Station) -> Vector3:
	return st.to_global(Vector3(0.02, StationModels.ANVIL_FACE - 0.5 + 0.05, 0))


## Sparks off a blow: hot streaks that fly up and out, fall the way this planet
## pulls, and cool from white through orange to red as they go -- with a flash
## of light on the blow itself. `big` is a change of shape, which deserves more.
func _spark_burst(where: Vector3, count: int, col: Color, big: bool = false) -> void:
	var ps := CPUParticles3D.new()
	# A thin rod stood along its own velocity is a streak, which is what a
	# spark looks like to the eye; a cube just looks like a crumb.
	var rod := BoxMesh.new()
	rod.size = Vector3(0.018, 0.11, 0.018)
	ps.mesh = rod
	ps.particle_flag_align_y = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	ps.material_override = mat
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.97, 0.8))
	ramp.set_color(1, Color(0.8, 0.12, 0.02))
	ramp.add_point(0.35, col)
	ps.color_ramp = ramp
	ps.amount = maxi(count, 1) * (2 if big else 1)
	ps.lifetime = 0.55
	ps.one_shot = true
	ps.explosiveness = 0.95
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	ps.emission_sphere_radius = 0.05
	var g: Vector3 = world.gravity_at(where) if world != null else Vector3.DOWN * 9.8
	var up: Vector3 = -g.normalized() if g.length() > 0.01 else Vector3.UP
	ps.direction = up
	ps.spread = 80.0
	ps.initial_velocity_min = 2.2
	ps.initial_velocity_max = 5.5 if big else 4.5
	ps.gravity = g
	ps.scale_amount_min = 0.7
	ps.scale_amount_max = 1.3
	var parent: Node = world if world != null else get_parent()
	_emit_at(ps, parent, where)
	get_tree().create_timer(1.2).timeout.connect(ps.queue_free)
	# The flash: gone in a tenth of a second, but it lights the anvil and your
	# hands, which is most of what makes a blow feel like it landed.
	var fl := OmniLight3D.new()
	fl.light_color = Color(1.0, 0.62, 0.25)
	fl.omni_range = 3.0
	fl.light_energy = 3.5 if big else 2.2
	parent.add_child(fl)
	fl.global_position = where + up * 0.15
	var tw := fl.create_tween()
	tw.tween_property(fl, "light_energy", 0.0, 0.14)
	tw.tween_callback(fl.queue_free)


## Take one off the stack in your hand, clearing the slot when it runs out.
func _take_one_from_active() -> void:
	if active_slot < 0 or active_slot >= inv.size():
		return
	var s2: Dictionary = inv[active_slot]
	var n := int(s2.get("count", 0)) - 1
	if n <= 0:
		inv[active_slot] = {"id": Blocks.AIR, "count": 0, "eighths": 0, "props": {},
			"src": "", "mat": {}}
	else:
		s2["count"] = n


## Start the coming-round tilt: eyes on the floor, head lifting to level over
## `seconds`. Called when a world opens in the wreck it began in.
func begin_wake(seconds: float, from_pitch: float) -> void:
	_rouse_len = maxf(seconds, 0.01)
	_rouse_from = from_pitch
	# Timed off the CLOCK, not off accumulated delta. The first second of a new
	# world is heavy, and physics catches up by running several steps in one
	# frame -- so a lift measured in deltas was three quarters spent before the
	# first drawn frame and nobody ever saw it.
	_rouse_end_ms = Time.get_ticks_msec() + int(_rouse_len * 1000.0)
	_rousing = true
	_pitch = from_pitch
	if _camera != null:
		_camera.rotation.x = _pitch


## Advance the coming-round tilt. True while it is still running, and while it
## is, look input is ignored: you are not in control yet.
func _tick_rouse() -> bool:
	if not _rousing:
		return false
	var left: float = maxf(float(_rouse_end_ms - Time.get_ticks_msec()) / 1000.0, 0.0)
	# Smoothstep, not ease-out: gentle at both ends with the travel in the
	# middle, which is exactly when the fade is clearing.
	var k: float = clampf(1.0 - left / _rouse_len, 0.0, 1.0)
	var e: float = k * k * (3.0 - 2.0 * k)
	_pitch = _rouse_from * (1.0 - e)
	if _camera != null:
		_camera.rotation.x = _pitch
	_look = Vector2.ZERO
	if left <= 0.0:
		_rousing = false
	return true


## Right-clicking a seat. Anything in the "ship_seat" group will do; where you
## end up is whatever it says in its `sit_at` metadata, in its own space, so a
## different chair can seat you differently without touching this.
func _try_sit() -> bool:
	if seated != null or piloting != null or eva:
		return false
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return false
	var c := _ray.get_collider()
	if c == null or not (c as Node).is_in_group("ship_seat"):
		return false
	sit_in(c as Node3D)
	return true


func sit_in(seat: Node3D) -> void:
	seated = seat
	velocity = Vector3.ZERO
	_body_shape.disabled = true
	# Sitting down turns you to face the way the chair faces. You reached it by
	# looking AT it, so without this you would sit down staring into its own
	# back -- and a pilot's seat points at the controls for a reason.
	var up: Vector3 = seat.global_transform.basis.y
	var fwd: Vector3 = -seat.global_transform.basis.z
	global_position = seat.to_global(seat.get_meta("sit_at", Vector3(0, 0.6, 0)))
	look_at(global_position + fwd, up)
	_pitch = 0.0
	if _camera != null:
		_camera.rotation.x = 0.0
	_toast("Seated -- %s to get up" % OS.get_keycode_string(
		int(binds.get("crouch", DEFAULT_BINDS["crouch"]))))


func stand_up() -> void:
	if seated == null:
		return
	# Step clear of the chair rather than standing up inside its back.
	var away: Vector3 = -seated.global_transform.basis.z
	global_position = seated.global_position + away * 0.9 + seated.global_transform.basis.y * 0.9
	seated = null
	_body_shape.disabled = false
	velocity = Vector3.ZERO


## Sitting still, in the seat's own frame so the chair can be aboard a ship that
## is moving. You keep your head: look works, walking does not.
func _sit_physics(delta: float) -> void:
	if not is_instance_valid(seated):
		seated = null
		_body_shape.disabled = false
		return
	if key_down("crouch"):
		stand_up()
		return
	# Coming round: the head lift, which also ignores look input while it runs.
	if _tick_rouse():
		pass
	var up: Vector3 = seated.global_transform.basis.y
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS * look_sensitivity)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS * look_sensitivity * _look_sign(), -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO
	# Some seats go somewhere. A chair ignores this; a boat is steered by it.
	if seated.has_method("drive"):
		var wish := _move_input()
		seated.call("drive", Vector2(wish.x, wish.y))
	var at: Vector3 = seated.get_meta("sit_at", Vector3(0, 0.6, 0))
	global_position = seated.to_global(at)
	velocity = Vector3.ZERO


## Right-click with a boat in hand, looking at water: she goes in. On land she
## does not -- a boat on a hillside is a crate, and the refusal is the lesson.
func _try_launch_boat() -> bool:
	if active_slot < 0 or active_slot >= inv.size():
		return false
	var held: Dictionary = inv[active_slot]
	if int(held.get("id", Blocks.AIR)) != Blocks.BOAT or int(held.get("count", 0)) <= 0:
		return false
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		_toast("Aim at some water")
		return true
	var at: Vector3 = tgt.get("point", global_position)
	var p := world.nearest_planet(at) if world != null else null
	if p == null or p.water_style != p.WATER_LIQUID:
		_toast("There is no water here")
		return true
	var g := world.gravity_at(at)
	var up: Vector3 = (-g).normalized() if g.length() > 0.01 else Vector3.UP
	# Find the surface at the spot you picked, searching a little either way --
	# what the crosshair lands on is usually the bed under the water, not the
	# water, so "where you pointed" has to mean "the surface above that".
	var surface = _water_surface_near(p, at, up)
	if surface == null:
		_toast("The boat needs water to float in")
		return true
	var fwd: Vector3 = -global_transform.basis.z
	var boat := world.spawn_boat((surface as Vector3) + up * 0.1, up, fwd)
	if boat == null:
		return true
	_take_one_from_active()
	_refresh_slots()
	_toast("Boat launched -- right-click to get in")
	return true


## The top of the water at a point, as a world position, or null if there is
## none within reach of it.
func _water_surface_near(p: Planet, at: Vector3, up: Vector3):
	for step in range(-2, 5):
		var probe: Vector3 = at + up * (float(step) * 1.0)
		var v := p.world_to_voxel(probe)
		if p.get_id(v) != Blocks.WATER:
			continue
		var fill: float = p.water_fill(v)
		var centre: Vector3 = p.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5))
		return centre - up * 0.5 + up * fill
	return null



## Right-click with the journal in hand. One page, the same page every time in
## this world, from the world's own seed -- it is a thing that happened here.
func _try_read_journal() -> bool:
	if active_slot < 0 or active_slot >= inv.size():
		return false
	if int(inv[active_slot].get("id", Blocks.AIR)) != Blocks.JOURNAL:
		return false
	_open_journal()
	return true


func _open_journal() -> void:
	_close_journal()
	_read_t = 0.0001   # the book in your hands starts to open (see _tick_held_anim)
	_journal_panel = Panel.new()
	_journal_panel.custom_minimum_size = Vector2(560, 500)
	_journal_panel.size = _journal_panel.custom_minimum_size
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.11, 0.08, 0.97)
	sb.border_color = Color(0.45, 0.36, 0.24, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	_journal_panel.add_theme_stylebox_override("panel", sb)
	_ui_layer.add_child(_journal_panel)
	var head := Label.new()
	head.text = "SALVAGED JOURNAL"
	head.position = Vector2(24, 20)
	head.add_theme_font_size_override("font_size", 20)
	head.modulate = Color(0.85, 0.74, 0.52)
	_journal_panel.add_child(head)
	# The page scrolls. It is written per world and a wordy planet ran off the
	# bottom of the panel and off the screen with it.
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(24, 60)
	scroll.custom_minimum_size = Vector2(512, 380)
	scroll.size = Vector2(512, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_journal_panel.add_child(scroll)
	var body := Label.new()
	# The page the journal is actually carrying -- written about the planet the
	# wreck came down on (see CrashSite.journal_text) and kept with the item, so
	# it stays true wherever you take it.
	var page := ""
	if active_slot >= 0 and active_slot < inv.size():
		page = str((inv[active_slot].get("props", {}) as Dictionary).get("text", ""))
	if page == "":
		page = "The pages are water-damaged past reading."
	body.text = page

	body.custom_minimum_size = Vector2(496, 0)
	body.size = Vector2(496, 0)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.modulate = Color(0.92, 0.88, 0.80)
	scroll.add_child(body)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(120, 34)
	close.position = Vector2(24, 452)
	close.pressed.connect(func(): Audio.ui("ui_back"))
	close.pressed.connect(_close_journal)
	_journal_panel.add_child(close)
	menu_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_fit_panel(_journal_panel)


func _close_journal() -> void:
	_read_t = 0.0
	if _journal_panel != null and is_instance_valid(_journal_panel):
		_journal_panel.queue_free()
	_journal_panel = null
	menu_open = false
	if not (inv_open or book_open or _station_open != null):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## The marker node living on a ship, if it has one.
func _ghosts_for(ship: Ship) -> RepairGhosts:
	if ship == null or not is_instance_valid(ship):
		return null
	for c in ship.get_children():
		var g := c as RepairGhosts
		if g != null:
			return g
	return null


## Clicking a line of the systems check: show that job on the hull, or stop.
func _toggle_repair_ghost(item_name: String) -> void:
	var ship := _ship_panel_ship
	var g := _ghosts_for(ship)
	if g == null:
		return
	var on := g.toggle(item_name)
	Audio.ui("ui_toggle_on" if on else "ui_toggle_off")
	_ship_panel_sig = ""        # redraw so the row shows its new state
	_refresh_ship_computer()
