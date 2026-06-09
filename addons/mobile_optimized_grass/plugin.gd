@tool
extends EditorPlugin

var _dock: GrassPaintDock
var _painter: GrassPainter
var _target: Node3D
var _is_paint_active := false
var _confirm_reset: ConfirmationDialog


func _enter_tree() -> void:
	_painter = GrassPainter.new()
	_painter.stroke_completed.connect(_on_stroke_completed)
	_painter.reset_completed.connect(_on_reset_completed)

	_confirm_reset = ConfirmationDialog.new()
	_confirm_reset.title = "Reset RGBA Channels"
	_confirm_reset.dialog_text = "Zero all four density channels on every terrain vertex?\nThis action can be undone with Ctrl-Z."
	_confirm_reset.confirmed.connect(_on_reset_confirmed)
	EditorInterface.get_base_control().add_child(_confirm_reset)

	_dock = preload("res://addons/mobile_optimized_grass/grass_paint_dock.tscn").instantiate() as GrassPaintDock
	add_control_to_bottom_panel(_dock, "Grass Painter")

	_dock.tool_changed.connect(_on_tool_changed)
	_dock.brush_size_changed.connect(    func(v: float) -> void: _painter.brush_radius   = v)
	_dock.brush_strength_changed.connect(func(v: float) -> void: _painter.brush_strength = v)
	_dock.brush_falloff_changed.connect( func(v: int)   -> void: _painter.brush_falloff  = v)
	_dock.channel_selected.connect(func(i: int) -> void:
			_painter.active_channel = i
			if _dock.preview_enabled:
				_painter.set_preview(true, _dock.preview_composite, i))
	_dock.tint_color_changed.connect(    func(c: Color) -> void: _painter.tint_color     = c)
	_dock.preview_toggled.connect(_on_preview_toggled)
	_dock.regenerate_requested.connect(_on_regenerate_requested)
	_dock.bake_requested.connect(_on_bake_requested)
	_dock.reset_requested.connect(_on_reset_requested)
	_dock.total_instances_changed.connect(func(v: int)   -> void: if is_instance_valid(_target): _target.set("total_instances", v))
	_dock.normalize_power_changed.connect(func(v: float) -> void: if is_instance_valid(_target): _target.set("normalize_power", v))
	_dock.scatter_mode_changed.connect(   func(m: int)   -> void: if is_instance_valid(_target): _target.set("scatter_mode", m))
	_dock.min_spacing_changed.connect(    func(v: float) -> void: if is_instance_valid(_target): _target.set("min_spacing", v))


func _exit_tree() -> void:
	if is_instance_valid(_dock):
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
	if is_instance_valid(_confirm_reset):
		_confirm_reset.queue_free()
	_dock          = null
	_painter       = null
	_target        = null
	_confirm_reset = null


func _handles(object: Object) -> bool:
	if not object is Node:
		return false
	var script = (object as Node).get_script()
	return script is GDScript \
		and (script as GDScript).resource_path.ends_with("grass_instancer.gd")


func _edit(object: Object) -> void:
	_target = object as Node3D if object is Node3D else null
	if is_instance_valid(_dock):
		_dock.set_target(_target)
	_painter.set_target(_target)


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_dock) and visible:
		make_bottom_panel_item_visible(_dock)


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not _is_paint_active or not is_instance_valid(_target):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var result := _painter.on_gui_input(viewport_camera, event)
	update_overlays()   # keep brush circle current on every input event
	return result


func _forward_3d_draw_over_viewport(viewport_control: Control) -> void:
	if not _is_paint_active:
		return
	_painter.draw_overlay(viewport_control)


# — Signal handlers ——————————————————————————————————————————————————————

func _on_tool_changed(tool: int) -> void:
	_is_paint_active = tool >= 0
	if tool >= 0:
		_painter.brush_tool = tool
	update_overlays()


func _on_stroke_completed(mesh: ArrayMesh, before: Array, after: Array) -> void:
	var ur := get_undo_redo()
	ur.create_action("Paint grass vertex colors", UndoRedo.MERGE_DISABLE, _target)
	ur.add_do_method(_painter, "_apply_arrays_to_mesh", mesh, after)
	ur.add_undo_method(_painter, "_apply_arrays_to_mesh", mesh, before)
	ur.commit_action(false)   # already applied; register for undo only


func _on_preview_toggled(enabled: bool, composite: bool) -> void:
	_painter.set_preview(enabled, composite, _dock.active_channel)


func _on_regenerate_requested() -> void:
	if is_instance_valid(_target) and "regenerate" in _target:
		_target.set("regenerate", true)


func _on_bake_requested() -> void:
	if is_instance_valid(_target):
		var path: String = _target.get("baked_file_path")
		_target.call("bake_instances_to_file", path)


func _on_reset_requested() -> void:
	if is_instance_valid(_target):
		_confirm_reset.popup_centered()


func _on_reset_confirmed() -> void:
	if is_instance_valid(_target):
		_painter.reset_rgba_channels(_target)


func _on_reset_completed(mesh: ArrayMesh, before: Array, after: Array) -> void:
	var ur := get_undo_redo()
	ur.create_action("Reset grass RGBA channels", UndoRedo.MERGE_DISABLE, _target)
	ur.add_do_method(_painter, "_apply_arrays_to_mesh", mesh, after)
	ur.add_undo_method(_painter, "_apply_arrays_to_mesh", mesh, before)
	ur.commit_action(false)
