# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A Godot 4.6 editor plugin that renders mobile-optimized grass and ground-cover vegetation using alpha-to-coverage MSAA. Targets Meta Quest 3 and other mobile/standalone XR devices. The project uses the **Mobile** rendering method (`renderer/rendering_method="mobile"` in `project.godot`).

## No build system

This is a Godot project — there is no build step, linter, or test runner. Open the project in Godot 4.6+ to run or edit it. All code is GDScript (`.gd`) and GDShader (`.gdshader`).

## Plugin structure

```
addons/mobile_optimized_grass/
  plugin.cfg                — plugin metadata
  plugin.gd                 — EditorPlugin: dock registration, node selection, 3D viewport input
  grass_instancer.gd        — @tool Node3D: scatter/bake/load at runtime and in editor
  grass_painter.gd          — @tool RefCounted: mesh utilities, brush application, preview toggle
  grass_scatter.gd          — RefCounted: stratified and Poisson disk scatter algorithms
  grass_paint_dock.gd/.tscn — bottom panel dock UI; all controls built in code
  mobile_optimized_grass.gdshader — unshaded alpha-to-coverage grass shader
  grass_preview.gdshader    — editor-only debug overlay (single-channel grayscale or composite RGBA)
  mobile_optimized_grass.tscn     — reusable scene template (GrassInstancer + 4 MultiMeshInstance3D)
demo/                 — small demo scene and materials (Demo.tscn)
large_demo/           — large field demo scene
```

## Core architecture

### Shader (`mobile_optimized_grass.gdshader`)
Uses `render_mode unshaded, alpha_to_coverage_and_one` — no per-fragment lighting; alpha is converted to MSAA coverage masks instead of blending. Key uniforms set at runtime by `grass_instancer.gd`: `min_height`, `max_height`, `blend_factor`. Per-instance scale comes from `INSTANCE_CUSTOM.r`; per-instance terrain shadow color comes from `COLOR` (the MultiMesh instance color).

### Scatter script (`grass_instancer.gd`)
The `@tool` script runs in the editor and at runtime. Responsibilities:
1. **Scatter** (`_generate_instances` → `scatter_four_types`): delegates to `GrassScatter` using the mode selected in the dock (`scatter_mode` export: 0 = stratified, 1 = Poisson disk). Per-channel instance counts are split proportionally from raw `ARRAY_CUSTOM0` density sums. Instance color comes from barycentric-interpolated `ARRAY_COLOR`; instance custom data `.r` holds random scale.
2. **Bake** (`bake_instances_to_file`): serializes all MultiMesh transforms, colors, and custom data to `res://grass_instances.bin` (or the path in `baked_file_path`). Triggered by the `Bake Instances` inspector button or the dock Bake button.
3. **Load** (`_ready` → `load_baked_instances`): at startup (editor or runtime) loads the baked file and populates the four `MultiMeshInstance3D` nodes. Falls back to `_generate_instances()` in the editor if no baked file is found.

### Scatter algorithms (`grass_scatter.gd`)
`GrassScatter extends RefCounted` provides two scatter methods, both returning `Array[Dictionary{pos, color, scale}]`:
- `scatter_stratified(mmi, channel, count, power, ...)`: divides the terrain XZ extent into a `count`-cell jittered grid. One candidate per cell is projected onto the mesh surface (XZ → triangle via spatial hash lookup) and accepted with probability `density^power`. Avoids clustering without enforcing a strict minimum distance.
- `scatter_poisson(mmi, channel, min_spacing, power, ...)`: Bridson's Poisson disk algorithm on the XZ plane. Enforces `min_spacing` between all placed instances; each candidate is also density-filtered via `density^power`. Produces blue-noise-quality placement at the cost of an unpredictable output count.

### Four plant types
`type_nodes: Array[MultiMeshInstance3D]` and `type_meshes: Array[Mesh]` are parallel arrays of length 4. Index 0 = R channel, 1 = G, 2 = B, 3 = A. Each gets its own `MultiMesh` with `use_colors = true` and `use_custom_data = true`.

## Typical editor workflow

1. Add `mobile_optimized_grass.tscn` to a scene.
2. Assign `terrain_mesh_instance`, the four `type_nodes` MultiMeshInstance3D children, and the four `type_meshes` meshes in the inspector.
3. Select the `GrassInstancer` node — the **Grass Painter** dock appears at the bottom of the editor.
4. Paint density on the terrain: choose a channel (R/G/B/A), set brush size/strength/falloff, click **Paint**, and drag across the terrain mesh. Enable the **Preview** toggle to visualize painted channels in the 3D viewport.
5. Click **Regenerate** in the dock (or check `Regenerate` in the inspector) to scatter instances using the painted density maps.
6. Click **Bake** in the dock (or the `Bake Instances` inspector button) to serialize instance data to disk.
7. The baked file (`res://grass_instances.bin` by default) is loaded automatically at runtime — no scatter runs in a shipping build.

Use **Reset RGBA** (dock Actions section) to zero all four density channels; a confirmation dialog appears first and the action is undoable with Ctrl-Z.

## Terrain mesh conventions (Blender → Godot)
- Vertex colors baked with Cycles → blurred → used as per-instance shadow tint (`ARRAY_COLOR`).
- Four vegetation density channels painted as additional vertex colors in Blender, exported as `UV3` (R/G) and `UV4` (B/A), which Godot stores in `ARRAY_CUSTOM0` as a `PackedFloat32Array` with 4 floats per vertex. All four channels are now direct reads: `0.0` = no density, `1.0` = full density.
- Blender's `+Y` = Godot's `+Z` — match light rotations when baking Cycles vertex colors.

## Blender migration note (G/A inversion removed)
Prior to the in-editor painter refactor, `get_vertex_color_from_custom0` applied `1.0 -` to the G and A channels to compensate for a Blender UV3/UV4 export artifact. This inversion has been removed — all four channels now read directly. **If you have a mesh prepared with the old Blender workflow**, its G and A scatter channels will appear inverted in the painter (painted areas will look like erased and vice versa). To fix: in Blender, invert the vertex color values on the green and alpha channels before re-exporting, or repaint those channels in the Godot painter.

## GrassPainter
`grass_painter.gd` (`GrassPainter extends RefCounted`) owns all mesh-level read/write and editor-side brush logic:
- `ensure_array_mesh(mmi)` — converts PrimitiveMesh/etc. to ArrayMesh in-place (one-time, with warning).
- `ensure_vertex_attributes(mesh)` — allocates `ARRAY_COLOR` (white) and `ARRAY_CUSTOM0` (zeroes) if absent.
- `read_surface_arrays(mesh)` / `write_surface_arrays(mesh, arrays)` — the only safe path for modifying vertex data. `write_` preserves the original surface format flags and material; the internal cache mirrors the written state so subsequent reads are cheap.
- `set_preview(enabled, composite, channel)` — applies/removes the `grass_preview.gdshader` as a surface override material on the terrain `MeshInstance3D`. Updates `active_channel` and `preview_mode` uniforms in place so switching channels while preview is on doesn't flicker.
- `reset_rgba_channels(target_node)` — zeroes every vertex's four ARRAY_CUSTOM0 floats and emits `reset_completed(mesh, before, after)` for UndoRedo registration by `plugin.gd`.
