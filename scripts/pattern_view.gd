class_name PatternView
extends SubViewportContainer
## A build pattern as a live 3D model in the Recipe Book: turning slowly on its
## own, and turned by hand when dragged.
##
## PatternPicture's still image showed the finished build well enough, but a
## still of a 3D thing reads as a drawing -- it is the movement that makes it
## plainly a model you can walk round. Only made while the book is open and
## only rendered while visible, so a closed book costs nothing.

const VIEW_SIZE := Vector2i(200, 150)
## Radians a second when left alone.
const SPIN := 0.55
const PITCH := 0.55

var _pivot: Node3D
var _cam: Camera3D
var _dragging := false
var _yaw := 0.7
var _pitch := PITCH
var _idle := 0.0          # seconds since the last drag; the spin resumes after


func _init(def: Dictionary) -> void:
	stretch = true
	custom_minimum_size = Vector2(VIEW_SIZE)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Drag to turn it"
	var vp := SubViewport.new()
	vp.size = VIEW_SIZE
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.9
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 30, 0)
	sun.light_energy = 0.6
	vp.add_child(sun)

	var built := PatternPicture._build_mesh(def)
	var lo: Vector3 = built[1]
	var hi: Vector3 = built[2]
	_pivot = Node3D.new()
	vp.add_child(_pivot)
	var mi := MeshInstance3D.new()
	mi.mesh = built[0]
	# Centred on the pivot, so it turns about its own middle.
	mi.position = -(lo + hi) * 0.5
	_pivot.add_child(mi)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.near = 0.01
	_cam.far = 60.0
	# Sized for the longest the model can be from any side it turns to.
	_cam.size = maxf((hi - lo).length() * 1.05, 0.5)
	vp.add_child(_cam)
	_place_camera()


func _place_camera() -> void:
	var dist := _cam.size + 6.0
	var dir := Vector3(0.0, sin(_pitch), cos(_pitch))
	_cam.look_at_from_position(dir * dist, Vector3.ZERO, Vector3.UP)
	_pivot.rotation = Vector3(0.0, _yaw, 0.0)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	if _dragging:
		return
	_idle += delta
	# A pause after letting go, so the side you turned it to stays long enough
	# to look at.
	if _idle > 1.5:
		_yaw += SPIN * delta
		_place_camera()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_idle = 0.0
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_yaw += event.relative.x * 0.012
		_pitch = clampf(_pitch + event.relative.y * 0.01, 0.05, 1.45)
		_idle = 0.0
		_place_camera()
		accept_event()
