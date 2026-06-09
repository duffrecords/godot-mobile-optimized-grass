@tool
class_name GrassPainter
extends RefCounted

## Emitted at the end of every paint stroke so plugin.gd can register an undo action.
signal stroke_completed(mesh: ArrayMesh, before: Array, after: Array)
## Emitted after reset_rgba_channels writes zeroes so plugin.gd can register an undo action.
signal reset_completed(mesh: ArrayMesh, before: Array, after: Array)

const AFTER_GUI_INPUT_PASS := 0
const AFTER_GUI_INPUT_STOP := 1

const FALLOFF_CONSTANT := 0
const FALLOFF_LINEAR   := 1
const FALLOFF_SMOOTH   := 2

const TOOL_PAINT   := 0
const TOOL_ERASE   := 1
const TOOL_DARKEN  := 2
const TOOL_LIGHTEN := 3
const TOOL_BLUR    := 4

const _PREVIEW_SHADER := preload("res://addons/mobile_optimized_grass/grass_preview.gdshader")

# — Public properties — set by plugin.gd when dock signals fire ——————————
var brush_radius   := 1.0
var brush_strength := 0.5
var brush_falloff  := FALLOFF_SMOOTH
var active_channel := 0   # 0=R  1=G  2=B  3=A  4=Ground Tint
var brush_tool     := TOOL_PAINT
var tint_color     := Color.WHITE

# — Private state ————————————————————————————————————————————————————————
var _target: Node3D

# Preview overlay
var _preview_material:        ShaderMaterial
var _preview_active           := false
var _saved_override_material: Material

# Surface array cache — invalidated whenever the mesh reference changes or
# an external write (undo/redo) replaces the surface data.
var _cached_mesh:   ArrayMesh
var _cached_arrays: Array = []

# Per-stroke state
var _is_painting          := false
var _stroke_dirty         := false   # true if any paint was applied this stroke
var _stroke_start_arrays: Array = []

# Overlay state
var _last_camera:        Camera3D
var _last_hit_world_pos: Vector3
var _has_valid_hit       := false


func set_target(node: Node3D) -> void:
	# Remove preview override from the outgoing target before switching.
	if _preview_active:
		var old_mmi := _get_terrain_mmi()
		if old_mmi != null:
			old_mmi.set_surface_override_material(0, null)
		_preview_active = false

	_target = node
	_saved_override_material = null
	_cached_mesh = null
	_cached_arrays = []
	_is_painting = false
	_has_valid_hit = false


# ═══════════════════════════════════════════════════════════════════════════
# Mesh utilities (Phase 2)
# ═══════════════════════════════════════════════════════════════════════════

## Ensures the MeshInstance3D holds an ArrayMesh.
## Converts PrimitiveMesh / other Mesh subclasses in-place with a warning.
func ensure_array_mesh(mesh_instance: MeshInstance3D) -> ArrayMesh:
	if mesh_instance.mesh is ArrayMesh:
		return mesh_instance.mesh as ArrayMesh

	var src := mesh_instance.mesh
	if src == null:
		push_error("GrassPainter: MeshInstance3D has no mesh.")
		return null
	if not src is Mesh:
		push_error("GrassPainter: Unsupported mesh type '%s'." % src.get_class())
		return null

	push_warning(
		"GrassPainter: Converting '%s' to ArrayMesh for vertex painting. " % src.get_class()
		+ "The original mesh resource is unchanged; this MeshInstance3D now uses an ArrayMesh copy."
	)

	var array_mesh := ArrayMesh.new()
	for i in src.get_surface_count():
		var arrays := src.surface_get_arrays(i)
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := src.surface_get_material(i)
		if mat:
			array_mesh.surface_set_material(i, mat)

	mesh_instance.mesh = array_mesh
	return array_mesh


## Ensures ARRAY_COLOR (white) and ARRAY_CUSTOM0 (zeroes, 4×float/vertex)
## exist on surface 0. Allocates and writes them if absent or wrong size.
func ensure_vertex_attributes(mesh: ArrayMesh) -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		return

	var arrays := mesh.surface_get_arrays(0)
	var verts  := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	if verts == null or verts.is_empty():
		return

	var vert_count := verts.size()
	var dirty      := false

	var colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
	if colors == null or colors.size() != vert_count:
		var new_colors := PackedColorArray()
		new_colors.resize(vert_count)
		for i in vert_count:
			new_colors[i] = Color.WHITE
		arrays[Mesh.ARRAY_COLOR] = new_colors
		dirty = true

	var custom0 := arrays[Mesh.ARRAY_CUSTOM0] as PackedFloat32Array
	if custom0 == null or custom0.size() != vert_count * 4:
		var new_c0 := PackedFloat32Array()
		new_c0.resize(vert_count * 4)   # 0.0 default = no density on any channel
		arrays[Mesh.ARRAY_CUSTOM0] = new_c0
		dirty = true

	if dirty:
		write_surface_arrays(mesh, arrays)


## Returns the cached surface-0 arrays. Re-reads from the mesh only when the
## mesh reference changes (cache miss).
func read_surface_arrays(mesh: ArrayMesh) -> Array:
	if mesh == null or mesh.get_surface_count() == 0:
		return []
	if mesh == _cached_mesh and not _cached_arrays.is_empty():
		return _cached_arrays
	_cached_mesh   = mesh
	_cached_arrays = mesh.surface_get_arrays(0)
	return _cached_arrays


## Replaces surface 0 with the supplied arrays, preserving format flags and
## material. Always updates the cache to match so subsequent reads are cheap.
func write_surface_arrays(mesh: ArrayMesh, arrays: Array) -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var format   := mesh.surface_get_format(0)     # cache BEFORE surface_remove
	var material := mesh.surface_get_material(0)

	# surface_remove clears surface override materials on any MeshInstance3D
	# referencing this mesh — save and restore it.
	var mmi := _get_terrain_mmi()
	var override_mat: Material = null
	if mmi != null and mmi.mesh == mesh:
		override_mat = mmi.get_surface_override_material(0)

	mesh.surface_remove(0)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, format)
	if material:
		mesh.surface_set_material(0, material)
	if override_mat != null:
		mmi.set_surface_override_material(0, override_mat)

	_cached_mesh   = mesh
	_cached_arrays = arrays


## Called by the undo/redo system to restore a snapshot. Clears the cache
## after writing so the next stroke reads the restored state from the mesh.
func _apply_arrays_to_mesh(mesh: ArrayMesh, arrays: Array) -> void:
	write_surface_arrays(mesh, arrays)
	_cached_mesh   = null
	_cached_arrays = []


# ═══════════════════════════════════════════════════════════════════════════
# 3D viewport input (Phase 3)
# ═══════════════════════════════════════════════════════════════════════════

func on_gui_input(camera: Camera3D, event: InputEvent) -> int:
	_last_camera = camera

	var terrain_mmi := _get_terrain_mmi()
	if terrain_mmi == null:
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return AFTER_GUI_INPUT_PASS   # let right/middle click through for orbit/pan

		if mb.pressed:
			var mesh := ensure_array_mesh(terrain_mmi)
			if mesh == null:
				return AFTER_GUI_INPUT_STOP
			ensure_vertex_attributes(mesh)
			_stroke_start_arrays = read_surface_arrays(mesh).duplicate(true)
			_stroke_dirty = false
			_is_painting  = true

			var hit := _raycast(camera, mb.position, terrain_mmi)
			if hit.hit:
				_last_hit_world_pos = hit.position
				_has_valid_hit = true
				_apply_brush(mesh, terrain_mmi.global_transform)
				write_surface_arrays(mesh, _cached_arrays)
				_stroke_dirty = true
		else:
			# Stroke end — emit snapshot for undo registration
			if _is_painting and _stroke_dirty:
				var terrain_mesh := terrain_mmi.mesh as ArrayMesh
				if terrain_mesh != null:
					stroke_completed.emit(
						terrain_mesh,
						_stroke_start_arrays,
						_cached_arrays.duplicate(true)
					)
			_is_painting = false

		return AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion:
		var terrain_mesh := terrain_mmi.mesh as ArrayMesh
		var hit := _raycast(camera, event.position, terrain_mmi)
		if hit.hit:
			_last_hit_world_pos = hit.position
			_has_valid_hit = true
			if _is_painting and terrain_mesh != null:
				_apply_brush(terrain_mesh, terrain_mmi.global_transform)
				write_surface_arrays(terrain_mesh, _cached_arrays)
				_stroke_dirty = true
		else:
			_has_valid_hit = false

		return AFTER_GUI_INPUT_STOP if _is_painting else AFTER_GUI_INPUT_PASS

	return AFTER_GUI_INPUT_PASS


## Draws the brush-circle overlay into the 3D viewport overlay Control.
## Called every frame by plugin._forward_3d_draw_over_viewport.
func draw_overlay(viewport_control: Control) -> void:
	if not _has_valid_hit or _last_camera == null:
		return
	if _last_camera.is_position_behind(_last_hit_world_pos):
		return
	var screen_pos  := _last_camera.unproject_position(_last_hit_world_pos)
	var radius_px   := _world_radius_to_screen_px()
	var circle_col := _tool_cursor_color()
	viewport_control.draw_arc(screen_pos, maxf(radius_px, 2.0), 0.0, TAU, 64, circle_col, 1.5)


# ═══════════════════════════════════════════════════════════════════════════
# Internal helpers
# ═══════════════════════════════════════════════════════════════════════════

func _get_terrain_mmi() -> MeshInstance3D:
	if not is_instance_valid(_target):
		return null
	var v = _target.get("terrain_mesh_instance")
	return v as MeshInstance3D if v is MeshInstance3D else null


## Möller–Trumbore CPU ray–mesh intersection (no CollisionShape required).
## Returns {hit: bool, position: Vector3}.
func _raycast(camera: Camera3D, screen_pos: Vector2, mmi: MeshInstance3D) -> Dictionary:
	var mesh := mmi.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() == 0:
		return {hit = false}

	var arrays  := read_surface_arrays(mesh)
	var verts   := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var indices := arrays[Mesh.ARRAY_INDEX]  as PackedInt32Array
	if verts == null or verts.is_empty():
		return {hit = false}

	var xform        := mmi.global_transform
	var ray_origin   := xform.affine_inverse() * camera.project_ray_origin(screen_pos)
	var ray_dir      := xform.affine_inverse().basis * camera.project_ray_normal(screen_pos)

	var best_t   := INF
	var best_pos := Vector3.ZERO

	if indices != null and not indices.is_empty():
		var tri_count := indices.size() / 3
		for i in tri_count:
			var r := _ray_triangle(
				ray_origin, ray_dir,
				verts[indices[i * 3 + 0]],
				verts[indices[i * 3 + 1]],
				verts[indices[i * 3 + 2]]
			)
			if r[0] and r[1] < best_t:
				best_t   = r[1]
				best_pos = ray_origin + ray_dir * best_t
	else:
		var tri_count := verts.size() / 3
		for i in tri_count:
			var r := _ray_triangle(
				ray_origin, ray_dir,
				verts[i * 3 + 0], verts[i * 3 + 1], verts[i * 3 + 2]
			)
			if r[0] and r[1] < best_t:
				best_t   = r[1]
				best_pos = ray_origin + ray_dir * best_t

	if best_t == INF:
		return {hit = false}
	return {hit = true, position = xform * best_pos}


## Möller–Trumbore ray–triangle test. Returns [did_hit: bool, t: float].
func _ray_triangle(orig: Vector3, dir: Vector3,
		v0: Vector3, v1: Vector3, v2: Vector3) -> Array:
	const EPSILON := 1e-7
	var e1 := v1 - v0
	var e2 := v2 - v0
	var h  := dir.cross(e2)
	var a  := e1.dot(h)
	if abs(a) < EPSILON:
		return [false, 0.0]
	var f := 1.0 / a
	var s := orig - v0
	var u := f * s.dot(h)
	if u < 0.0 or u > 1.0:
		return [false, 0.0]
	var q := s.cross(e1)
	var v := f * dir.dot(q)
	if v < 0.0 or u + v > 1.0:
		return [false, 0.0]
	var t := f * e2.dot(q)
	return [t > EPSILON, t]


## Applies one brush stamp at _last_hit_world_pos to the cached arrays.
## Does NOT flush to mesh — caller is responsible for calling write_surface_arrays.
func _apply_brush(mesh: ArrayMesh, mesh_xform: Transform3D) -> void:
	var arrays     := read_surface_arrays(mesh)
	var verts      := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	if verts == null:
		return
	var vert_count := verts.size()

	if active_channel < 4:
		var custom0 := arrays[Mesh.ARRAY_CUSTOM0] as PackedFloat32Array
		if custom0 == null or custom0.size() != vert_count * 4:
			return

		var blur_avg := 0.0
		if brush_tool == TOOL_BLUR:
			var total_w := 0.0
			for i in vert_count:
				var dist := (mesh_xform * verts[i]).distance_to(_last_hit_world_pos)
				if dist >= brush_radius:
					continue
				var w := _falloff(dist / brush_radius)
				blur_avg += w * custom0[i * 4 + active_channel]
				total_w += w
			if total_w > 0.0:
				blur_avg /= total_w

		for i in vert_count:
			var dist := (mesh_xform * verts[i]).distance_to(_last_hit_world_pos)
			if dist >= brush_radius:
				continue
			var w   := _falloff(dist / brush_radius) * brush_strength
			var idx := i * 4 + active_channel
			match brush_tool:
				TOOL_PAINT:   custom0[idx] = clampf(custom0[idx] + w, 0.0, 1.0)
				TOOL_ERASE:   custom0[idx] = clampf(custom0[idx] - w, 0.0, 1.0)
				TOOL_DARKEN:  custom0[idx] = lerpf(custom0[idx], 0.0, w)
				TOOL_LIGHTEN:
					if custom0[idx] > 0.0:
						custom0[idx] = lerpf(custom0[idx], 1.0, w)
				TOOL_BLUR:    custom0[idx] = lerpf(custom0[idx], blur_avg, w)
		arrays[Mesh.ARRAY_CUSTOM0] = custom0
	else:
		var colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
		if colors == null or colors.size() != vert_count:
			return

		var blur_color := Color.BLACK
		if brush_tool == TOOL_BLUR:
			var total_w := 0.0
			for i in vert_count:
				var dist := (mesh_xform * verts[i]).distance_to(_last_hit_world_pos)
				if dist >= brush_radius:
					continue
				var w := _falloff(dist / brush_radius)
				blur_color.r += w * colors[i].r
				blur_color.g += w * colors[i].g
				blur_color.b += w * colors[i].b
				blur_color.a += w * colors[i].a
				total_w += w
			if total_w > 0.0:
				blur_color = Color(
					blur_color.r / total_w, blur_color.g / total_w,
					blur_color.b / total_w, blur_color.a / total_w)

		for i in vert_count:
			var dist := (mesh_xform * verts[i]).distance_to(_last_hit_world_pos)
			if dist >= brush_radius:
				continue
			var w := _falloff(dist / brush_radius) * brush_strength
			match brush_tool:
				TOOL_PAINT:   colors[i] = colors[i].lerp(tint_color, w)
				TOOL_ERASE:   colors[i] = colors[i].lerp(Color.WHITE, w)
				TOOL_DARKEN:  colors[i] = colors[i].lerp(Color.BLACK, w)
				TOOL_LIGHTEN: colors[i] = colors[i].lerp(Color.WHITE, w)
				TOOL_BLUR:    colors[i] = colors[i].lerp(blur_color, w)
		arrays[Mesh.ARRAY_COLOR] = colors


func _tool_cursor_color() -> Color:
	match brush_tool:
		TOOL_ERASE:   return Color(1.0, 0.3, 0.3, 0.9)
		TOOL_DARKEN:  return Color(0.5, 0.3, 1.0, 0.9)
		TOOL_LIGHTEN: return Color(1.0, 1.0, 0.3, 0.9)
		TOOL_BLUR:    return Color(0.3, 0.8, 1.0, 0.9)
		_:            return Color(1.0, 1.0, 1.0, 0.9)


func _falloff(t: float) -> float:
	match brush_falloff:
		FALLOFF_CONSTANT: return 1.0
		FALLOFF_LINEAR:   return 1.0 - t
		_:                return 1.0 - smoothstep(0.0, 1.0, t)


func _world_radius_to_screen_px() -> float:
	if _last_camera == null:
		return 10.0
	var screen_center := _last_camera.unproject_position(_last_hit_world_pos)
	var offset_world  := _last_hit_world_pos + _last_camera.global_transform.basis.x * brush_radius
	return screen_center.distance_to(_last_camera.unproject_position(offset_world))


# ═══════════════════════════════════════════════════════════════════════════
# Preview shader toggle
# ═══════════════════════════════════════════════════════════════════════════

func set_preview(enabled: bool, composite: bool, channel: int) -> void:
	var mmi := _get_terrain_mmi()
	if mmi == null:
		return

	if not enabled:
		mmi.set_surface_override_material(0, _saved_override_material)
		_saved_override_material = null
		_preview_active = false
		return

	if not _preview_active:
		_saved_override_material = mmi.get_surface_override_material(0)

	if _preview_material == null:
		_preview_material = ShaderMaterial.new()
		_preview_material.shader = _PREVIEW_SHADER

	_preview_material.set_shader_parameter("active_channel", channel)
	_preview_material.set_shader_parameter("preview_mode", 1 if composite else 0)
	mmi.set_surface_override_material(0, _preview_material)
	_preview_active = true


# ═══════════════════════════════════════════════════════════════════════════
# Channel reset
# ═══════════════════════════════════════════════════════════════════════════

func reset_rgba_channels(_target_node: Node3D) -> void:
	var mmi := _get_terrain_mmi()
	if mmi == null:
		return
	var mesh := ensure_array_mesh(mmi)
	if mesh == null:
		return
	ensure_vertex_attributes(mesh)

	var arrays := read_surface_arrays(mesh)
	var before := arrays.duplicate(true)

	var custom0 := arrays[Mesh.ARRAY_CUSTOM0] as PackedFloat32Array
	if custom0 == null:
		return
	custom0.fill(0.0)
	arrays[Mesh.ARRAY_CUSTOM0] = custom0
	write_surface_arrays(mesh, arrays)

	reset_completed.emit(mesh, before, _cached_arrays.duplicate(true))


