@tool
class_name GrassTypeConfig
extends Resource

@export_group("Alpha")
@export_range(0.0, 1.0) var alpha_scissor_threshold: float = 0.5
@export_range(0.0, 1.0) var alpha_antialiasing_edge: float = 0.4

@export_group("Blend")
@export var override_blend_factor: bool = false
@export_range(0.0, 1.0) var blend_factor: float = 0.5

@export_group("Height Bounds")
@export var override_height_bounds: bool = false
@export var min_height: float = 0.0
@export var max_height: float = 1.0
