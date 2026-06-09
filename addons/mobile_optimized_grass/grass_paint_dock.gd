@tool
class_name GrassPaintDock
extends MarginContainer

signal tool_changed(tool: int)  # -1 = off, 0=paint 1=erase 2=darken 3=lighten 4=blur
signal channel_selected(index: int)
signal brush_size_changed(value: float)
signal brush_strength_changed(value: float)
signal brush_falloff_changed(index: int)
signal tint_color_changed(color: Color)
signal preview_toggled(enabled: bool, composite: bool)
signal total_instances_changed(value: int)
signal scatter_mode_changed(mode: int)
signal min_spacing_changed(value: float)
signal normalize_power_changed(value: float)
signal plant_label_changed(index: int, label: String)
signal regenerate_requested
signal bake_requested
signal reset_requested

const CHANNEL_NAMES := ["R", "G", "B", "A", "Tint"]
const FALLOFF_NAMES := ["Constant", "Linear", "Smooth"]
const SCATTER_NAMES := ["Stratified", "Poisson Disk"]
const TOOL_NAMES    := ["Paint", "Erase", "Darken", "Lighten", "Blur"]

const CHANNEL_COLORS := [
	Color(0.75, 0.2,  0.2),   # R
	Color(0.2,  0.6,  0.25),  # G
	Color(0.2,  0.38, 0.82),  # B
	Color(0.48, 0.48, 0.52),  # A
	Color(0.78, 0.52, 0.12),  # Tint
]
const TOOL_ACTIVE_COLOR := Color(0.22, 0.52, 0.82)

const TOOL_TOOLTIPS := [
	"Add density to the selected channel",
	"Remove density from the selected channel",
	"Darken tint color on the painted area",
	"Lighten tint color on the painted area",
	"Smooth density across the painted area",
]
const CHANNEL_TOOLTIPS := [
	"Plant type 0 (R channel) density",
	"Plant type 1 (G channel) density",
	"Plant type 2 (B channel) density",
	"Plant type 3 (A channel) density",
	"Per-vertex shadow tint color",
]

var active_channel := 0
var active_tool    := -1
var brush_radius := 1.0
var brush_strength := 0.5
var brush_falloff := 2
var tint_color := Color.WHITE
var preview_enabled := false
var preview_composite := false
var scatter_mode := 0
var total_instances := 5000
var min_spacing := 0.5
var normalize_power := 3.0
var plant_labels: Array[String] = ["Plant 0", "Plant 1", "Plant 2", "Plant 3"]

var _target: Node3D

var _tool_buttons: Array[Button] = []
var _tool_group: ButtonGroup
var _channel_buttons: Array[Button] = []
var _plant_label_edits: Array[LineEdit] = []
var _tint_picker: ColorPickerButton
var _falloff_option: OptionButton
var _preview_check: CheckButton
var _preview_mode_row: HBoxContainer
var _preview_composite_btn: Button
var _instances_spin: SpinBox
var _scatter_option: OptionButton
var _min_spacing_label: Label
var _min_spacing_spin: SpinBox
var _power_slider: HSlider
var _no_selection_label: Label
var _controls_root: Control


func _ready() -> void:
	add_theme_constant_override("margin_left", 8)
	add_theme_constant_override("margin_right", 8)
	add_theme_constant_override("margin_top", 4)
	add_theme_constant_override("margin_bottom", 4)
	custom_minimum_size = Vector2(0, 110)

	_no_selection_label = Label.new()
	_no_selection_label.text = "Select a GrassInstancer node to use the Grass Painter."
	_no_selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_selection_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_no_selection_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_no_selection_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_no_selection_label)

	_controls_root = VBoxContainer.new()
	_controls_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_controls_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_controls_root.visible = false
	add_child(_controls_root)

	_build_ui()


func set_target(node: Node3D) -> void:
	_target = node
	var has_target := is_instance_valid(node)
	_no_selection_label.visible = not has_target
	_controls_root.visible = has_target
	if has_target:
		_sync_from_target()


func _sync_from_target() -> void:
	if "total_instances" in _target:
		_instances_spin.value = _target.get("total_instances")
	if "normalize_power" in _target:
		_power_slider.value = _target.get("normalize_power")
	if "scatter_mode" in _target:
		var mode: int = _target.get("scatter_mode")
		_scatter_option.selected = mode
		_on_scatter_mode_changed(mode)
	if "min_spacing" in _target:
		_min_spacing_spin.value = _target.get("min_spacing")


func _build_ui() -> void:
	_controls_root.add_child(_build_top_row())
	_controls_root.add_child(HSeparator.new())
	_controls_root.add_child(_build_bottom_row())


func _build_top_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	# — Tool selector
	var mode_vbox := VBoxContainer.new()
	_add_label(mode_vbox, "Tool")

	_tool_group = ButtonGroup.new()
	_tool_group.allow_unpress = true

	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 2)
	for i in TOOL_NAMES.size():
		var btn := Button.new()
		btn.text = TOOL_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = _tool_group
		btn.custom_minimum_size = Vector2(52, 0)
		btn.tooltip_text = TOOL_TOOLTIPS[i]
		_apply_toggle_style(btn, TOOL_ACTIVE_COLOR)
		var ti := i
		btn.toggled.connect(func(active: bool) -> void:
			if active:
				active_tool = ti
				tool_changed.emit(ti)
			elif _tool_group.get_pressed_button() == null:
				active_tool = -1
				tool_changed.emit(-1))
		_tool_buttons.append(btn)
		tool_row.add_child(btn)
	mode_vbox.add_child(tool_row)

	_tint_picker = ColorPickerButton.new()
	_tint_picker.color = tint_color
	_tint_picker.text = "Tint Color"
	_tint_picker.visible = false
	_tint_picker.custom_minimum_size = Vector2(120, 0)
	_tint_picker.tooltip_text = "Shadow tint color painted onto terrain vertices"
	_tint_picker.color_changed.connect(func(c: Color) -> void:
		tint_color = c
		tint_color_changed.emit(c))
	mode_vbox.add_child(_tint_picker)

	row.add_child(mode_vbox)
	row.add_child(VSeparator.new())

	# — Channel selector
	var ch_vbox := VBoxContainer.new()
	var ch_lbl := Label.new()
	ch_lbl.text = "Channel"
	ch_vbox.add_child(ch_lbl)

	var ch_row := HBoxContainer.new()
	ch_row.add_theme_constant_override("separation", 4)
	var ch_group := ButtonGroup.new()

	for i in 5:
		var btn := Button.new()
		btn.text = CHANNEL_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = ch_group
		btn.custom_minimum_size = Vector2(32, 0)
		btn.tooltip_text = CHANNEL_TOOLTIPS[i]
		_apply_toggle_style(btn, CHANNEL_COLORS[i])
		btn.pressed.connect(_on_channel_pressed.bind(i))
		_channel_buttons.append(btn)
		ch_row.add_child(btn)

		if i < 4:
			var edit := LineEdit.new()
			edit.text = plant_labels[i]
			edit.placeholder_text = "Plant %d" % i
			edit.custom_minimum_size = Vector2(80, 0)
			edit.tooltip_text = "Display name for plant type %d" % i
			edit.text_submitted.connect(_on_plant_label_submitted.bind(i))
			edit.focus_exited.connect(_on_plant_label_focus_exited.bind(edit, i))
			_plant_label_edits.append(edit)
			ch_row.add_child(edit)

	_channel_buttons[0].button_pressed = true
	ch_vbox.add_child(ch_row)
	row.add_child(ch_vbox)

	return row


func _build_bottom_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	# — Brush section
	var brush_vbox := VBoxContainer.new()
	_add_label(brush_vbox, "Brush")

	var size_row := _make_slider_row("Size", 0.1, 10.0, brush_radius, 0.1, true)
	var size_slider := size_row.get_child(1) as HSlider
	size_slider.tooltip_text = "Brush radius in world units"
	(size_row.get_child(2) as SpinBox).tooltip_text = "Brush radius in world units"
	size_slider.value_changed.connect(func(v: float) -> void:
		brush_radius = v
		brush_size_changed.emit(v))
	brush_vbox.add_child(size_row)

	var strength_row := _make_slider_row("Strength", 0.0, 1.0, brush_strength, 0.01, true)
	var strength_slider := strength_row.get_child(1) as HSlider
	strength_slider.tooltip_text = "Amount of density added or removed per stroke"
	(strength_row.get_child(2) as SpinBox).tooltip_text = "Amount of density added or removed per stroke"
	strength_slider.value_changed.connect(func(v: float) -> void:
		brush_strength = v
		brush_strength_changed.emit(v))
	brush_vbox.add_child(strength_row)

	var fall_row := HBoxContainer.new()
	var fall_lbl := Label.new()
	fall_lbl.text = "Falloff:"
	fall_lbl.custom_minimum_size = Vector2(56, 0)
	fall_row.add_child(fall_lbl)
	_falloff_option = OptionButton.new()
	for n in FALLOFF_NAMES:
		_falloff_option.add_item(n)
	_falloff_option.selected = brush_falloff
	_falloff_option.tooltip_text = "Brush edge falloff: Constant (flat), Linear, or Smooth (ease-in/out)"
	_falloff_option.item_selected.connect(func(idx: int) -> void:
		brush_falloff = idx
		brush_falloff_changed.emit(idx))
	fall_row.add_child(_falloff_option)
	brush_vbox.add_child(fall_row)

	row.add_child(brush_vbox)
	row.add_child(VSeparator.new())

	# — Preview section
	var prev_vbox := VBoxContainer.new()
	_add_label(prev_vbox, "Preview")

	_preview_check = CheckButton.new()
	_preview_check.text = "Vertex colors"
	_preview_check.tooltip_text = "Overlay vertex color data on the terrain mesh in the 3D viewport"
	_preview_check.toggled.connect(_on_preview_toggled)
	prev_vbox.add_child(_preview_check)

	_preview_mode_row = HBoxContainer.new()
	_preview_mode_row.visible = false
	var pv_group := ButtonGroup.new()

	var single_btn := Button.new()
	single_btn.text = "Single"
	single_btn.toggle_mode = true
	single_btn.button_group = pv_group
	single_btn.button_pressed = true
	single_btn.tooltip_text = "Preview only the active channel as grayscale"
	single_btn.toggled.connect(func(_p: bool) -> void: _emit_preview())
	_preview_mode_row.add_child(single_btn)

	_preview_composite_btn = Button.new()
	_preview_composite_btn.text = "Composite"
	_preview_composite_btn.toggle_mode = true
	_preview_composite_btn.button_group = pv_group
	_preview_composite_btn.tooltip_text = "Preview all four channels as an RGBA composite"
	_preview_composite_btn.toggled.connect(func(_p: bool) -> void: _emit_preview())
	_preview_mode_row.add_child(_preview_composite_btn)

	prev_vbox.add_child(_preview_mode_row)
	row.add_child(prev_vbox)
	row.add_child(VSeparator.new())

	# — Scatter section
	var sc_vbox := VBoxContainer.new()
	sc_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_label(sc_vbox, "Scatter")

	var sc_row1 := HBoxContainer.new()
	_add_label(sc_row1, "Instances:")
	_instances_spin = SpinBox.new()
	_instances_spin.min_value = 1
	_instances_spin.max_value = 1000000
	_instances_spin.step = 100
	_instances_spin.value = total_instances
	_instances_spin.custom_minimum_size = Vector2(90, 0)
	_instances_spin.tooltip_text = "Total grass instances to scatter across all four channels"
	_instances_spin.value_changed.connect(func(v: float) -> void:
		total_instances = int(v)
		total_instances_changed.emit(total_instances))
	sc_row1.add_child(_instances_spin)
	_add_label(sc_row1, "  Mode:")
	_scatter_option = OptionButton.new()
	for n in SCATTER_NAMES:
		_scatter_option.add_item(n)
	_scatter_option.tooltip_text = "Stratified: grid-jitter placement\nPoisson Disk: blue-noise minimum-distance placement"
	_scatter_option.item_selected.connect(_on_scatter_mode_changed)
	sc_row1.add_child(_scatter_option)
	sc_vbox.add_child(sc_row1)

	var sc_row2 := HBoxContainer.new()
	_min_spacing_label = Label.new()
	_min_spacing_label.text = "Min dist:"
	_min_spacing_label.visible = false
	sc_row2.add_child(_min_spacing_label)
	_min_spacing_spin = SpinBox.new()
	_min_spacing_spin.min_value = 0.01
	_min_spacing_spin.max_value = 20.0
	_min_spacing_spin.step = 0.1
	_min_spacing_spin.value = min_spacing
	_min_spacing_spin.custom_minimum_size = Vector2(72, 0)
	_min_spacing_spin.visible = false
	_min_spacing_spin.tooltip_text = "Minimum distance between instances in world units (Poisson Disk only)"
	_min_spacing_spin.value_changed.connect(func(v: float) -> void:
		min_spacing = v
		min_spacing_changed.emit(v))
	sc_row2.add_child(_min_spacing_spin)

	var pow_row := _make_slider_row("Power", 0.5, 8.0, normalize_power)
	_power_slider = pow_row.get_child(1) as HSlider
	_power_slider.tooltip_text = "Density sharpening power — higher values concentrate instances on the most-painted areas"
	_power_slider.value_changed.connect(func(v: float) -> void:
		normalize_power = v
		normalize_power_changed.emit(v))
	sc_row2.add_child(pow_row)
	sc_vbox.add_child(sc_row2)

	row.add_child(sc_vbox)
	row.add_child(VSeparator.new())

	# — Actions section
	var act_vbox := VBoxContainer.new()
	_add_label(act_vbox, "Actions")
	_add_button(act_vbox, "Regenerate", func() -> void: regenerate_requested.emit()).tooltip_text = \
		"Re-scatter instances using the current density maps and settings"
	_add_button(act_vbox, "Bake", func() -> void: bake_requested.emit()).tooltip_text = \
		"Serialize current instance data to disk for fast runtime loading"
	_add_button(act_vbox, "Reset RGBA", func() -> void: reset_requested.emit()).tooltip_text = \
		"Zero all four density channels on the terrain mesh (undoable with Ctrl+Z)"

	row.add_child(act_vbox)
	return row


# — Signal handlers ——————————————————————————————————————————————————————

func _on_channel_pressed(index: int) -> void:
	active_channel = index
	_tint_picker.visible = index == 4
	channel_selected.emit(index)


func _on_preview_toggled(active: bool) -> void:
	preview_enabled = active
	_preview_mode_row.visible = active
	_emit_preview()


func _emit_preview() -> void:
	preview_composite = _preview_composite_btn.button_pressed
	preview_toggled.emit(preview_enabled, preview_composite)


func _on_scatter_mode_changed(idx: int) -> void:
	scatter_mode = idx
	var is_poisson := idx == 1
	_min_spacing_label.visible = is_poisson
	_min_spacing_spin.visible = is_poisson
	scatter_mode_changed.emit(idx)


func _on_plant_label_submitted(text: String, index: int) -> void:
	plant_labels[index] = text
	plant_label_changed.emit(index, text)


func _on_plant_label_focus_exited(edit: LineEdit, index: int) -> void:
	_on_plant_label_submitted(edit.text, index)


# — Helpers ——————————————————————————————————————————————————————————————

func _make_slider_row(label_text: String, min_val: float, max_val: float, default: float, step: float = 1.0, with_spinbox: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label_text + ":"
	lbl.custom_minimum_size = Vector2(56, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = default
	slider.custom_minimum_size = Vector2(100, 0)
	row.add_child(slider)
	if with_spinbox:
		var spin := SpinBox.new()
		spin.min_value = min_val
		spin.max_value = max_val
		spin.step = step
		spin.value = default
		spin.custom_minimum_size = Vector2(60, 0)
		slider.value_changed.connect(func(v: float) -> void: spin.set_value_no_signal(v))
		spin.value_changed.connect(func(v: float) -> void: slider.value = v)
		row.add_child(spin)
	return row


func _add_label(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	parent.add_child(lbl)


func _add_button(parent: Control, text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn


func _apply_toggle_style(btn: Button, color: Color) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(3)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	btn.add_theme_stylebox_override("pressed", s)
	var h := s.duplicate() as StyleBoxFlat
	h.bg_color = color.lightened(0.15)
	btn.add_theme_stylebox_override("hover_pressed", h)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
