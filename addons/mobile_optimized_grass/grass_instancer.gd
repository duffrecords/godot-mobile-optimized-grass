@tool
class_name GrassInstancer
extends Node3D

## Terrain mesh whose vertex colors define scatter density and shadow tint.
@export var terrain_mesh_instance: MeshInstance3D:
	set(value):
		terrain_mesh_instance = value
		update_configuration_warnings()
## Four MultiMeshInstance3D children — one per plant type (R, G, B, A channels).
@export var type_nodes: Array[MultiMeshInstance3D]
## Four grass meshes — one per plant type (R, G, B, A channels).
@export var type_meshes: Array[Mesh]:
	set(value):
		type_meshes = value
		update_configuration_warnings()
## Optional per-type GrassTypeConfig resources for per-channel shader overrides.
@export var type_configs: Array[GrassTypeConfig]
## Total instances to scatter across all four channels combined.
@export var total_instances := 5000
## Power curve applied to density weights — higher values concentrate instances on the most-painted areas.
@export var normalize_power := 3.0
## Minimum random per-instance scale multiplier.
@export var scale_min: float = 0.5
## Maximum random per-instance scale multiplier.
@export var scale_max: float = 1.0
## Scatter algorithm: 0 = Stratified grid-jitter, 1 = Poisson Disk blue-noise. Controlled by the dock.
@export var scatter_mode: int = 0
## Minimum distance between instances in Poisson Disk scatter mode.
@export var min_spacing: float = 0.5
## Vertical gradient blend factor for the grass shader (0 = no blend, 1 = full gradient).
@export_range(0.0, 1.0) var blend_factor: float = 0.5
## How strongly vertex density channels bias instance placement (0 = uniform random, 1 = density-only).
@export_range(0.0, 1.0) var vertex_color_influence: float = 1.0
## Check to immediately re-scatter instances in the editor.
@export var regenerate := false
## Progress callback set by the plugin dock before triggering scatter; cleared after use.
var scatter_progress_cb: Callable
var _scatter_pending_cb: Callable
var _scatter_next_frame := false
var _scatter_in_progress := false
## Path to the binary file used for baking and loading instances at runtime.
@export var baked_file_path: String = "res://grass_instances.bin"

# This button appears in inspector
var _bake_instances_button: bool = false

var _pre_save_buffers: Array

const _GRASS_SHADER_PATH := "res://addons/mobile_optimized_grass/mobile_optimized_grass.gdshader"


func _extract_albedo_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D or mat is ORMMaterial3D:
		return mat.albedo_texture
	if mat is ShaderMaterial:
		return mat.get_shader_parameter("grass_texture")
	return null


func _ensure_grass_material(mmi: MultiMeshInstance3D, mesh: Mesh, config: GrassTypeConfig = null) -> void:
	var bounds: Vector2
	if config and config.override_height_bounds:
		bounds = Vector2(config.min_height, config.max_height)
	else:
		bounds = get_mesh_y_bounds(mesh)
	var threshold := config.alpha_scissor_threshold if config else 0.5
	var aa_edge := config.alpha_antialiasing_edge if config else 0.4
	var bf := config.blend_factor if (config and config.override_blend_factor) else blend_factor

	var existing: Material = mmi.material_override
	if existing is ShaderMaterial:
		var sm: ShaderMaterial = existing
		if sm.shader and sm.shader.resource_path == _GRASS_SHADER_PATH:
			sm.set_shader_parameter("min_height", bounds.x)
			sm.set_shader_parameter("max_height", bounds.y)
			sm.set_shader_parameter("blend_factor", bf)
			sm.set_shader_parameter("alpha_scissor_threshold", threshold)
			sm.set_shader_parameter("alpha_antialiasing_edge", aa_edge)
			return
	var albedo_tex := _extract_albedo_texture(mesh.surface_get_material(0))
	var shader := load(_GRASS_SHADER_PATH) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if albedo_tex:
		mat.set_shader_parameter("grass_texture", albedo_tex)
	mat.set_shader_parameter("alpha_scissor_threshold", threshold)
	mat.set_shader_parameter("alpha_antialiasing_edge", aa_edge)
	mat.set_shader_parameter("min_height", bounds.x)
	mat.set_shader_parameter("max_height", bounds.y)
	mat.set_shader_parameter("blend_factor", bf)
	mmi.material_override = mat


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	var root = get_tree().edited_scene_root
	if root == null:
		return
	var changed := false
	while type_nodes.size() < 4:
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "GrassType%d" % type_nodes.size()
		add_child(mmi)
		mmi.owner = root
		type_nodes.append(mmi)
		changed = true
	while type_meshes.size() < 4:
		type_meshes.append(null)
		changed = true
	if changed:
		notify_property_list_changed()


func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if not terrain_mesh_instance:
		w.append("terrain_mesh_instance must be assigned before scattering.")
	var missing_meshes := 0
	for i in 4:
		if i >= type_meshes.size() or type_meshes[i] == null:
			missing_meshes += 1
	if missing_meshes > 0:
		w.append("%d of 4 type_meshes not assigned — those channels will be skipped." % missing_meshes)
	return w


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

func bake_instances_to_file(path: String):
	var data = []
	var total_baked_instances = 0
	for mmi in type_nodes.size():
		var mm_data = []
		var mm = type_nodes[mmi].multimesh
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

func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_pre_save_buffers.clear()
		for mmi in type_nodes:
			if mmi and mmi.multimesh and mmi.multimesh.instance_count > 0:
				_pre_save_buffers.append(mmi.multimesh.get_buffer())
				mmi.multimesh.instance_count = 0
			else:
				_pre_save_buffers.append(null)
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		for i in mini(type_nodes.size(), _pre_save_buffers.size()):
			var buf = _pre_save_buffers[i]
			if buf == null:
				continue
			var mmi = type_nodes[i]
			if mmi and mmi.multimesh:
				mmi.multimesh.instance_count = buf.size() / 20
				mmi.multimesh.set_buffer(buf)
		_pre_save_buffers.clear()


func _ready():
	if type_nodes.size() < 4 or type_meshes.size() < 4:
		push_error("GrassInstancer: type_nodes and type_meshes must each have 4 entries.")
		return
	for i in range(4):
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = type_meshes[i]
		type_nodes[i].multimesh = mm
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

	for i in range(4):
		var count = data[i].size()
		type_nodes[i].multimesh.instance_count = count
		for j in count:
			var entry = data[i][j]
			var basis = Basis(entry["basis_x"], entry["basis_y"], entry["basis_z"])
			var xform = Transform3D(basis, entry["origin"])
			type_nodes[i].multimesh.set_instance_transform(j, xform)
			type_nodes[i].multimesh.set_instance_color(j, entry["color"])
			type_nodes[i].multimesh.set_instance_custom_data(j, entry["custom_data"])

		var cfg: GrassTypeConfig = type_configs[i] if i < type_configs.size() else null
		_ensure_grass_material(type_nodes[i], type_meshes[i], cfg)


func _process(_delta):
	if not Engine.is_editor_hint():
		return
	if regenerate:
		if _scatter_in_progress:
			regenerate = false  # discard: scatter already running
			return
		# Frame 1: show the bar, then let the engine render before starting scatter.
		regenerate = false
		_scatter_pending_cb = scatter_progress_cb
		scatter_progress_cb = Callable()
		if _scatter_pending_cb.is_valid():
			_scatter_pending_cb.call(0, 100)
		_scatter_next_frame = true
	elif _scatter_next_frame:
		# Frame 2: engine has rendered the bar — launch the async scatter coroutine.
		_scatter_next_frame = false
		_scatter_async(_scatter_pending_cb)

func _scatter_async(p_progress_cb: Callable) -> void:
	_scatter_in_progress = true
	if not terrain_mesh_instance or not terrain_mesh_instance.mesh:
		_scatter_in_progress = false
		return

	var was_hidden := not terrain_mesh_instance.visible
	if was_hidden:
		terrain_mesh_instance.visible = true

	print("scattering instances async (mode=%d)" % scatter_mode)

	var tri_weights := compute_triangle_rgba_weights(terrain_mesh_instance.mesh)
	var sums := [
		_sum_channel(tri_weights, 0), _sum_channel(tri_weights, 1),
		_sum_channel(tri_weights, 2), _sum_channel(tri_weights, 3),
	]
	var total_sum := maxf(sums[0] + sums[1] + sums[2] + sums[3], 0.0001)
	var counts := [
		int(round(float(total_instances) * sums[0] / total_sum)),
		int(round(float(total_instances) * sums[1] / total_sum)),
		int(round(float(total_instances) * sums[2] / total_sum)),
		0,
	]
	counts[3] = total_instances - counts[0] - counts[1] - counts[2]

	var scatter_obj := GrassScatter.new()
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for ch in 4:
		if not type_meshes[ch] or not type_nodes[ch]:
			continue

		# Update bar and yield so the engine renders that state before the scatter freeze.
		if p_progress_cb.is_valid():
			p_progress_cb.call(ch * 25, 100)
		await get_tree().process_frame

		var per_ch_cb := Callable()
		if p_progress_cb.is_valid():
			var ch_offset := ch * 25
			per_ch_cb = func(current: int, total: int) -> void:
				p_progress_cb.call(
					ch_offset + int(float(current) / float(maxi(total, 1)) * 25), 100)

		var placements: Array
		if scatter_mode == 1:
			placements = scatter_obj.scatter_poisson(
				terrain_mesh_instance, ch, min_spacing,
				normalize_power, scale_min, scale_max, rng, per_ch_cb)
			if placements.size() > counts[ch]:
				placements.resize(counts[ch])
		else:
			placements = scatter_obj.scatter_stratified(
				terrain_mesh_instance, ch, counts[ch],
				normalize_power, scale_min, scale_max, rng, per_ch_cb)
		_apply_placements(ch, placements, type_nodes[ch], type_meshes[ch])

	if was_hidden:
		terrain_mesh_instance.visible = false
	if p_progress_cb.is_valid():
		p_progress_cb.call(100, 100)
	_scatter_pending_cb = Callable()
	_scatter_in_progress = false


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
		custom0[base + 0],
		custom0[base + 1],
		custom0[base + 2],
		custom0[base + 3]
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

func _sum_channel(tri_weights: Array, chan: int) -> float:
	var s := 0.0
	for w in tri_weights:
		match chan:
			0: s += w.r
			1: s += w.g
			2: s += w.b
			3: s += w.a
	return s

func _apply_placements(
		ch: int, placements: Array,
		mm_node: MultiMeshInstance3D, type_mesh: Mesh) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = type_mesh
	mm.instance_count = placements.size()

	var cfg_ap: GrassTypeConfig = type_configs[ch] if ch < type_configs.size() else null
	_ensure_grass_material(mm_node, type_mesh, cfg_ap)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in placements.size():
		var p: Dictionary = placements[i]
		var y_rot  := rng.randf() * TAU
		var xform  := Transform3D(Basis(Vector3.UP, y_rot), p.pos)
		mm.set_instance_transform(i, xform)
		mm.set_instance_color(i, p.color)
		mm.set_instance_custom_data(i, Color(p.scale, 0.0, 0.0, 0.0))

	mm_node.multimesh = mm
	print("placed %d instances on %s channel" % [placements.size(), ["R","G","B","A"][ch]])


func scatter_four_types(
	p_terrain_mmi: MeshInstance3D,
	p_type_nodes: Array,
	p_type_meshes: Array,
	p_total_instances: int,
	p_normalize_power := 2.0,
	p_global_progress_cb: Callable = Callable()
) -> void:
	print("scattering instances (mode=%d)" % scatter_mode)

	# Proportional per-channel counts from raw density sums.
	var tri_weights := compute_triangle_rgba_weights(p_terrain_mmi.mesh)
	var sums := [
		_sum_channel(tri_weights, 0),
		_sum_channel(tri_weights, 1),
		_sum_channel(tri_weights, 2),
		_sum_channel(tri_weights, 3),
	]
	var total_sum := maxf(sums[0] + sums[1] + sums[2] + sums[3], 0.0001)
	var counts := [
		int(round(float(p_total_instances) * sums[0] / total_sum)),
		int(round(float(p_total_instances) * sums[1] / total_sum)),
		int(round(float(p_total_instances) * sums[2] / total_sum)),
		0,
	]
	counts[3] = p_total_instances - counts[0] - counts[1] - counts[2]

	var scatter := GrassScatter.new()
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for ch in 4:
		if not p_type_meshes[ch] or not p_type_nodes[ch]:
			continue

		# Map this channel's local (current, total) onto its 25-step slice of the global bar.
		var progress_cb := Callable()
		if p_global_progress_cb.is_valid():
			var ch_offset := ch * 25
			progress_cb = func(current: int, total: int) -> void:
				p_global_progress_cb.call(
					ch_offset + int(float(current) / float(maxi(total, 1)) * 25), 100)

		var placements: Array
		if scatter_mode == 1:
			placements = scatter.scatter_poisson(
				p_terrain_mmi, ch, min_spacing,
				p_normalize_power, scale_min, scale_max, rng, progress_cb)
			if placements.size() > counts[ch]:
				placements.resize(counts[ch])
		else:
			placements = scatter.scatter_stratified(
				p_terrain_mmi, ch, counts[ch],
				p_normalize_power, scale_min, scale_max, rng, progress_cb)
		_apply_placements(ch, placements, p_type_nodes[ch], p_type_meshes[ch])

func _generate_instances(global_progress_cb: Callable = Callable()) -> void:
	if not Engine.is_editor_hint():
		return
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

	var was_hidden := terrain_mesh_instance.visible == false
	if was_hidden:
		terrain_mesh_instance.visible = true
		await get_tree().process_frame

	scatter_four_types(terrain_mesh_instance, type_nodes, type_meshes, total_instances, normalize_power, global_progress_cb)
	if was_hidden:
		terrain_mesh_instance.visible = false
	if global_progress_cb.is_valid():
		global_progress_cb.call(100, 100)
