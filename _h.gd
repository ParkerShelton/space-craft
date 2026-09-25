extends Node
var seed_value := 1
var out_dir := ""
func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--seed="): seed_value = int(str(a).substr(7))
		if str(a).begins_with("--out="): out_dir = str(a).substr(6)
	var main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(1.0).timeout
	main.set("_forced_seed", seed_value)
	var t0 := Time.get_ticks_msec()
	main.call("_start_world", false)
	var w: WorldManager = main.get("_world")
	var ship: Ship = null
	for i in 300:
		await get_tree().create_timer(0.5).timeout
		for c in w.get_children():
			if c is Ship: ship = c
		if ship != null and ship.wreck_debris.is_empty(): break
	print("HARN seed ", seed_value, " world ready after ", (Time.get_ticks_msec() - t0) / 1000.0, "s")
	await get_tree().create_timer(12.0).timeout
	var ground: Planet = w.nearest_planet(ship.global_position)
	var up: Vector3 = ship.global_transform.basis.y
	# trees near the wreck
	var c := ground.world_to_voxel(ship.global_position)
	var trees := 0
	for dx in range(-14, 15):
		for dy in range(-4, 20):
			for dz in range(-14, 15):
				var v := c + Vector3i(dx, dy, dz)
				var b := Blocks.bottom_of(ground.get_id(v))
				if Blocks.is_wood(b) or Blocks.is_leaf(b):
					var rel: Vector3 = ground.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)) - ship.global_position
					if (rel - up * rel.dot(up)).length() <= 10.0: trees += 1
	print("HARN tree voxels within 10 of the wreck: ", trees)
	# stale meshes
	var ccs := {}
	for v in ship.blocks:
		for d in [Vector3(-3,-3,-3), Vector3(3,3,3), Vector3(0,0,0)]:
			ccs[ground.chunk_of(ground.world_to_voxel(ship.to_global(Vector3(v) + d)))] = true
	var stale := 0
	for cc in ccs:
		var node = ground.loaded_chunks.get(cc)
		if node == null: continue
		var shown := 0
		var mi: MeshInstance3D = node.get("_mesh_instance")
		if mi != null and mi.mesh != null:
			for si in mi.mesh.get_surface_count():
				shown += (mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var snap: Dictionary = ground._edits_snapshot(cc)
		var fresh: Dictionary = Chunk.build_mesh_data(ground, cc, snap, ground._wlev_snapshot(snap))
		if shown != (fresh["verts"] as PackedVector3Array).size() + (fresh["wverts"] as PackedVector3Array).size(): stale += 1
	print("HARN stale chunks near the wreck: ", stale, " of ", ccs.size())
	# caches
	var spots: Array = []
	for st in w._stations:
		if is_instance_valid(st) and st.kind == Blocks.CHEST and not (st.get_parent() is Ship):
			var cv := ground.world_to_voxel(st.global_position)
			var above := ground.world_to_voxel(st.global_position + up)
			var below := ground.world_to_voxel(st.global_position - up)
			print("HARN chest cache: lid above=", Blocks.name_of(Blocks.bottom_of(ground.get_id(above))), " below=", Blocks.name_of(Blocks.bottom_of(ground.get_id(below))))
			spots.append(st.global_position)
	for dx in range(-20, 21):
		for dy in range(-6, 6):
			for dz in range(-20, 21):
				var v := c + Vector3i(dx, dy, dz)
				if Blocks.bottom_of(ground.get_id(v)) == Blocks.THRUSTER:
					var wp: Vector3 = ground.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5))
					print("HARN thruster cache: lid above=", Blocks.name_of(Blocks.bottom_of(ground.get_id(ground.world_to_voxel(wp + up)))))
					spots.append(wp)
	if out_dir == "": get_tree().quit(); return
	w.player.process_mode = Node.PROCESS_MODE_DISABLED
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false): (n as CanvasLayer).visible = false
	for n in get_tree().root.find_children("*", "Camera3D", true, false): (n as Camera3D).current = false
	var cam := Camera3D.new(); add_child(cam); cam.current = true
	var i := 0
	spots.push_front(ship.global_position)
	for sp in spots:
		var dir: Vector3 = sp - ship.global_position
		dir = (dir - up * dir.dot(up))
		dir = dir.normalized() if dir.length() > 0.1 else ship.global_transform.basis.x
		var dist := 16.0 if i == 0 else 4.0
		cam.global_position = sp + up * dist * 0.7 + dir * dist
		cam.look_at(sp, up)
		for k in 5: await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("%s/s%d_%d.png" % [out_dir, seed_value, i])
		i += 1
	get_tree().quit()
