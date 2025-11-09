@tool
extends Node3D

@export var terrain_mesh_instance: MeshInstance3D
# @export var terrain_mesh: Mesh
@export var type_nodes: Array[MultiMeshInstance3D] # length 4
@export var type_meshes: Array[Mesh]              # length 4
# @export var save_path
@export var total_instances := 5000
@export var normalize_power := 3.0
#@export var grass_instance_mesh: Mesh
#@export var instance0_mesh: Mesh
#@export var instance1_mesh: Mesh
#@export var instance2_mesh: Mesh
#@export var instance3_mesh: Mesh
# @export var target_mesh: MeshInstance3D
#@export var multimesh_instance: MultiMeshInstance3D
#@export var multimesh_instance0: MultiMeshInstance3D
#@export var multimesh_instance1: MultiMeshInstance3D
#@export var multimesh_instance2: MultiMeshInstance3D
#@export var multimesh_instance3: MultiMeshInstance3D
#@export var instance_count: int = 1000
@export var scale_min: float = 0.5
@export var scale_max: float = 1.0
@export_range(0.0, 1.0) var blend_factor: float = 0.5 # vertical gradient factor when blending with target mesh
@export_range(0.0, 1.0) var vertex_color_influence: float = 1.0 # scatter randomly vs. prefer to instance on vertex colors
@export var regenerate := false
@export var baked_file_path: String = "res://grass_instances.res"

# This button appears in inspector
var _bake_instances_button: bool = false

var _last_params = {}


func _get_property_list() -> Array:
	return [{
		"name": "bake_instances",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_EDITOR,
		"hint": PROPERTY_HINT_NONE,
	}]


func _get(property: StringName) -> Variant:
	if property == "bake_instances":
		return _bake_instances_button
	return null

func _set(property: StringName, value) -> bool:
	if property == "bake_instances":
		_bake_instances_button = value
		if _bake_instances_button:
			bake_instances_to_file(baked_file_path)
			_bake_instances_button = false
		notify_property_list_changed() # Refresh inspector to reset checkbox
		return true
	return false

func _on_bake_instances_button_pressed(value):
	if value:
		bake_instances_to_file(baked_file_path)
		# reset button state so you can press again
		_bake_instances_button = false
		# notify property changed to update inspector UI
		notify_property_list_changed()

func bake_instances_to_file(path: String):
#	if type_nodes.size() == 0:
#	#if not multimesh_instance or not multimesh_instance.multimesh:
#		push_error("No MultiMeshInstance or MultiMesh assigned!")
#		return
	var data = []
	var total_baked_instances = 0
	for mmi in type_nodes.size():
		var mm_data = []
		var mm = type_nodes[mmi].multimesh
		# var instance_count = mm.instance_count
		for i in mm.instance_count:
			var xform = mm.get_instance_transform(i)
			var color = mm.get_instance_color(i)
			var custom_data = mm.get_instance_custom_data(i)
			mm_data.append({
				"origin": xform.origin,
				"basis_x": xform.basis.x,
				"basis_y": xform.basis.y,
				"basis_z": xform.basis.z,
				"color": color,
				"custom_data": custom_data,
			})
		data.append(mm_data)
		total_baked_instances += mm.instance_count
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_var(data)
	file.close()
	print("Baked ", total_baked_instances, " instances to ", path)

func load_baked_instances(path: String) -> Array:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Cannot open baked instance file: " + path)
		return []
	var data = file.get_var()
	file.close()
	return data

func step(edge, x):
	return 0 if x < edge else 1

func screen(base: Color, blend: Color) -> Color:
	return Color.WHITE - (Color.WHITE - base) * (Color.WHITE - blend)

func soft_light(base: Color, blend: Color) -> Color:
	var limit = step(0.5, blend)
	var base_squared = Color(sqrt(base.r), sqrt(base.g), sqrt(base.b), sqrt(base.a))
	var base_x2 = base * 2.0
	var blend_x2 = blend * 2.0
	return lerp(base_x2 * blend + base * base * (Color.WHITE - blend_x2), base_squared * (blend_x2 - 1.0) + (base_x2) * (Color.WHITE - blend), limit)

func _ready():
	for i in range(4): # data.size():
		# multimeshes.append(MultiMeshInstance3D.new())
		#var mmi = MultiMeshInstance3D.new()
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = type_meshes[i]
		type_nodes[i].multimesh = mm
		# mmi.multimesh = mm
		#multimeshes.append(mmi)
	var data = load_baked_instances(baked_file_path)
	if data.size() == 0:
		if Engine.is_editor_hint():
			print("No baked data loaded")
			_generate_instances()
			return
		else:
			push_error("No baked data loaded")
			return
	else:
		print("loaded [%d %d %d %d] instances" % [data[0].size(), data[1].size(), data[2].size(), data[3].size()])

	for i in range(4): # data.size():
		var count = data[i].size()
		type_nodes[i].multimesh.instance_count = count
		# set transform and attributes for each MultiMeshInstance3D
		for j in count:
			var entry = data[i][j]
			var basis = Basis(entry["basis_x"], entry["basis_y"], entry["basis_z"])
			var xform = Transform3D(basis, entry["origin"])
			var color = entry["color"]
			var custom_data = entry["custom_data"]
			type_nodes[i].multimesh.set_instance_transform(j, xform)
			type_nodes[i].multimesh.set_instance_color(j, color)
			type_nodes[i].multimesh.set_instance_custom_data(j, custom_data)

		# set shader parameters for each instance type
		var bounds = get_mesh_y_bounds(type_meshes[i])
		var mat = type_nodes[i].multimesh.mesh.surface_get_material(0)
		if mat and mat is ShaderMaterial:
			mat.set_shader_parameter("min_height", bounds.x)
			mat.set_shader_parameter("max_height", bounds.y) # * (blend_factor + 1.0))
			mat.set_shader_parameter("blend_factor", blend_factor)


func _process(_delta):
	if Engine.is_editor_hint() and regenerate:
		regenerate = false
		_generate_instances()

func get_average_color(img: Image, uv: Vector2, kernel: int = 2) -> Color:
	var size = img.get_size()
	var px = int(clamp(uv.x * size.x, 0, size.x - 1))
	var py = int(clamp(uv.y * size.y, 0, size.y - 1))
	var col = Color()
	var count = 0
	for dx in range(-kernel, kernel+1):
		for dy in range(-kernel, kernel+1):
			var sx = clamp(px + dx, 0, size.x - 1)
			var sy = clamp(py + dy, 0, size.y - 1)
			col += img.get_pixel(sx, sy)
			count += 1
	return col / float(count)

func get_mesh_y_bounds(mesh: Mesh) -> Vector2:
	var arr = mesh.surface_get_arrays(0)
	if arr.is_empty():
		return Vector2(0, 1) # fallback

	var vertices = arr[Mesh.ARRAY_VERTEX]
	if vertices.is_empty():
		return Vector2(0, 1)

	var min_y = vertices[0].y
	var max_y = vertices[0].y

	for v in vertices:
		if v.y < min_y:
			min_y = v.y
		elif v.y > max_y:
			max_y = v.y

	return Vector2(min_y, max_y)

func get_vertex_color_from_custom0(custom0: PackedFloat32Array, vertex_index: int) -> Color:
	var base = vertex_index * 4
	return Color(
		custom0[base + 0],			# R
		1.0 - custom0[base + 1],	# G
		custom0[base + 2],			# B
		1.0 - custom0[base + 3]		# A
	)

func compute_triangle_rgba_weights(mesh: Mesh) -> Array[Color]:
	var arr = mesh.surface_get_arrays(0)
	var indices = arr[Mesh.ARRAY_INDEX]
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	# var custom0 = arr[Mesh.ARRAY_CUSTOM0] if Mesh.ARRAY_CUSTOM0 in arr else null
	var custom0 = arr[Mesh.ARRAY_CUSTOM0]
	var vertex_count = verts.size()
	var triangle_count = indices.size() / 3

	var weights: Array[Color] = []
	weights.resize(triangle_count)

	var has_custom: bool = custom0.size() == vertex_count * 4
	for i in range(triangle_count):
		var i0 = indices[i * 3 + 0]
		var i1 = indices[i * 3 + 1]
		var i2 = indices[i * 3 + 2]
		var w := Color.WHITE # fallback uniform

		if has_custom:
			var c0: Color = get_vertex_color_from_custom0(custom0, i0)
			var c1: Color = get_vertex_color_from_custom0(custom0, i1)
			var c2: Color = get_vertex_color_from_custom0(custom0, i2)
			w = (c0 + c1 + c2) / 3.0
		weights[i] = w
	return weights

func _normalize_and_sharpen_rgba_weights(tri_weights: Array, power: float = 2.0) -> void:
	# In-place normalize each channel to [0..1], then apply power curve to increase contrast.
	if tri_weights.is_empty():
		return
	var min_r := 1e9; var max_r := -1e9
	var min_g := 1e9; var max_g := -1e9
	var min_b := 1e9; var max_b := -1e9
	var min_a := 1e9; var max_a := -1e9

	for w in tri_weights:
		min_r = min(min_r, w.r); max_r = max(max_r, w.r)
		min_g = min(min_g, w.g); max_g = max(max_g, w.g)
		min_b = min(min_b, w.b); max_b = max(max_b, w.b)
		min_a = min(min_a, w.a); max_a = max(max_a, w.a)

	var dr := max(max_r - min_r, 0.0001)
	var dg := max(max_g - min_g, 0.0001)
	var db := max(max_b - min_b, 0.0001)
	var da := max(max_a - min_a, 0.0001)

	for i in tri_weights.size():
		var w: Color = tri_weights[i]
		w.r = pow(clamp((w.r - min_r)/dr, 0.0, 1.0), power)
		w.r = lerp(lerp(1.0, w.r, vertex_color_influence), w.r, vertex_color_influence)
		w.g = pow(clamp((w.g - min_g)/dg, 0.0, 1.0), power)
		w.g = lerp(lerp(1.0, w.g, vertex_color_influence), w.g, vertex_color_influence)
		w.b = pow(clamp((w.b - min_b)/db, 0.0, 1.0), power)
		w.b = lerp(lerp(1.0, w.b, vertex_color_influence), w.b, vertex_color_influence)
		w.a = pow(clamp((w.a - min_a)/da, 0.0, 1.0), power)
		w.a = lerp(lerp(1.0, w.a, vertex_color_influence), w.a, vertex_color_influence)
		tri_weights[i] = w

func _sum_channel(tri_weights: Array, chan: int) -> float:
	var s := 0.0
	for w in tri_weights:
		match chan:
			0: s += w.r
			1: s += w.g
			2: s += w.b
			3: s += w.a
	return s

func _pick_triangle_index_by_channel(tri_weights: Array, chan: int, rng: RandomNumberGenerator, total_weight: float) -> int:
	# Weighted random pick among triangles for a single channel (R/G/B/A)
	if total_weight <= 0.0:
		return 0
	var r := rng.randf() * total_weight
	var accum := 0.0
	for i in tri_weights.size():
		var w: Color = tri_weights[i]
		# var v := (chan == 0) ? w.r : (chan == 1) ? w.g : (chan == 2) ? w.b : w.a
		# var v = w.r if chan == 0 else w.g if chan == 1 else w.b if chan == 2 else w.a
		match chan:
			0: accum += w.r
			1: accum += w.g
			2: accum += w.b
			3: accum += w.a
		if accum >= r:
			return i
	return tri_weights.size() - 1

func place_instances_for_type(
	terrain_mesh_instance: MeshInstance3D,
	type_mesh: Mesh,
	mm_node: MultiMeshInstance3D,
	instance_count: int,
	type_index_rgba: int, # 0=R,1=G,2=B,3=A
	tri_weights: Array,
	rng: RandomNumberGenerator
) -> void:
	var terrain_mesh = terrain_mesh_instance.mesh
	var arr := terrain_mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var vcolors: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var tri_count := indices.size() / 3

	var total := _sum_channel(tri_weights, type_index_rgba)
	if total <= 0.0 or instance_count <= 0:
		# Clear multimesh for this type
		var empty := MultiMesh.new()
		empty.transform_format = MultiMesh.TRANSFORM_3D
		empty.use_colors = true
		empty.mesh = type_mesh
		empty.instance_count = 0
		mm_node.multimesh = empty
		print("skipping %s channel" % ["R", "G", "B", "A"][type_index_rgba])
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = type_mesh
	mm.instance_count = max(instance_count, 0)
	var bounds = get_mesh_y_bounds(type_mesh)
	print(type_index_rgba, " bounds: ", bounds)
	var mat = type_mesh.surface_get_material(0)
	if mat and mat is ShaderMaterial:
		mat.set_shader_parameter("min_height", bounds.x)
		mat.set_shader_parameter("max_height", bounds.y) # * blend_factor * 1.0)
		mat.set_shader_parameter("blend_factor", blend_factor)

	var start := Time.get_ticks_msec()
	for i in instance_count:
		var tri_idx := _pick_triangle_index_by_channel(tri_weights, type_index_rgba, rng, total)

		var i0 := indices[tri_idx * 3 + 0]
		var i1 := indices[tri_idx * 3 + 1]
		var i2 := indices[tri_idx * 3 + 2]

		# random barycentric
		var a := rng.randf()
		var b := rng.randf()
		if a + b > 1.0:
			a = 1.0 - a
			b = 1.0 - b
		var c := 1.0 - a - b

		var local_pos := verts[i0] * a + verts[i1] * b + verts[i2] * c
		var world_pos := terrain_mesh_instance.global_transform * local_pos
		if i < 10:
			print("instance position: [%0.3f, %0.3f, %0.3f]" % [local_pos.x, local_pos.y, local_pos.z])

		# upright random Y rotation
		var y_rot := rng.randf() * TAU
		var xform := Transform3D(Basis(Vector3.UP, y_rot), world_pos)

		mm.set_instance_transform(i, xform)
		# Per-instance color is whatever your shader expects (often white; the shader uses INSTANCE_COLOR for blending)
		var color = screen(screen(vcolors[i0], vcolors[i1]), vcolors[i2])
		mm.set_instance_color(i, color)
		# Randomly scale instances
		var scale = rng.randf_range(scale_min, scale_max)
		# Store scale in custom data's X component (for example)
		mm.set_instance_custom_data(i, Color(scale, 0, 0, 0))

	mm_node.multimesh = mm
	var elapsed := Time.get_ticks_msec() - start
	print("generated %d instances on %s channel in %d ms" % [mm_node.multimesh.instance_count, ["R", "G", "B", "A"][type_index_rgba], elapsed])

func scatter_four_types(
	terrain_mesh_instance: MeshInstance3D,
	# terrain_mesh: Mesh,
	type_nodes: Array, # [MultiMeshInstance3D, MultiMeshInstance3D, MultiMeshInstance3D, MultiMeshInstance3D]
	type_meshes: Array, # [Mesh, Mesh, Mesh, Mesh]
	total_instances: int,
	normalize_power := 2.0 # try 2..4 for stronger contrast
) -> void:
	print("scattering instances")
	# 1) build triangle weights from custom0
	var terrain_mesh: Mesh = terrain_mesh_instance.mesh
	var tri_weights := compute_triangle_rgba_weights(terrain_mesh)

	# 2) normalize + sharpen to expand your 0.3..0.45 range
	_normalize_and_sharpen_rgba_weights(tri_weights, normalize_power)

	# 3) split counts proportionally by channel sums
	var sum_r := _sum_channel(tri_weights, 0)
	var sum_g := _sum_channel(tri_weights, 1)
	var sum_b := _sum_channel(tri_weights, 2)
	var sum_a := _sum_channel(tri_weights, 3)
	var total_sum := max(sum_r + sum_g + sum_b + sum_a, 0.0001)

	var count_r := int(round(total_instances * (sum_r / total_sum)))
	var count_g := int(round(total_instances * (sum_g / total_sum)))
	var count_b := int(round(total_instances * (sum_b / total_sum)))
	var count_a := total_instances - (count_r + count_g + count_b)

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	# 4) place each type into its own MultiMeshInstance3D
	if type_meshes[0] and type_nodes[0]:
		place_instances_for_type(terrain_mesh_instance, type_meshes[0], type_nodes[0], count_r, 0, tri_weights, rng)
	if type_meshes[1] and type_nodes[1]:
		place_instances_for_type(terrain_mesh_instance, type_meshes[1], type_nodes[1], count_g, 1, tri_weights, rng)
	if type_meshes[2] and type_nodes[2]:
		place_instances_for_type(terrain_mesh_instance, type_meshes[2], type_nodes[2], count_b, 2, tri_weights, rng)
	if type_meshes[3] and type_nodes[3]:
		place_instances_for_type(terrain_mesh_instance, type_meshes[3], type_nodes[3], count_a, 3, tri_weights, rng)

func _generate_instances():
	if not Engine.is_editor_hint():
		return
	#if not grass_instance_mesh:
	#	print("A valid instance mesh is required.")
	#	return
	if not terrain_mesh_instance:
		print("A valid target mesh is required.")
		return
	if type_nodes.size() == 0:
		print("A MultiMeshInstance3D is required.")
		return
	if not terrain_mesh_instance.mesh:
		print("terrain_mesh_instance does not contain mesh data.")
		return
	print("generating instances...")

	# -- Visibility fix --
	var was_hidden := terrain_mesh_instance.visible == false
	if was_hidden and Engine.is_editor_hint():
		terrain_mesh_instance.visible = true
		await get_tree().process_frame  # Ensure Godot updates visibility

	# var multi_nodes = [multimesh_instance0, multimesh_instance1, multimesh_instance2, multimesh_instance3]
	# var meshes_per_type = [
	# 	instance0_mesh, instance1_mesh, instance2_mesh, instance3_mesh
	# ]
	scatter_four_types(terrain_mesh_instance, type_nodes, type_meshes, total_instances, normalize_power)
	# scatter_four_types(terrain_mesh_instance, multimeshes, type_meshes, total_instances, normalize_power)
	#for type_idx in range(4):
	#	distribute_instances_across_types(target_mesh.mesh, multi_nodes, meshes_per_type, instance_count, target_mesh.global_transform)
	# -- Restore visibility if needed --
	if was_hidden:
		terrain_mesh_instance.visible = false
