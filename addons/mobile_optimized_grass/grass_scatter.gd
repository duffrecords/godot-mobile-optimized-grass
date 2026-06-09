@tool
class_name GrassScatter
extends RefCounted

# Maximum candidate attempts per active point in Bridson's Poisson disk algorithm.
const MAX_ATTEMPTS := 30

# ─── Public API ───────────────────────────────────────────────────────────────

## Stratified/jittered scatter.
## Divides the terrain XZ extent into a ~count-cell grid; one jittered candidate
## per cell is projected onto the mesh surface and accepted with probability
## density^power.  Returns Array of {pos:Vector3, color:Color, scale:float}.
func scatter_stratified(
		mmi: MeshInstance3D, channel: int, count: int,
		power: float, scale_min: float, scale_max: float,
		rng: RandomNumberGenerator) -> Array:
	var md := _load_mesh_data(mmi)
	if md.is_empty() or count <= 0:
		return []

	var xz_sz: Vector2 = md.xz_size
	var area := xz_sz.x * xz_sz.y
	if area <= 0.0:
		return []

	var cell_sz := sqrt(area / float(count))
	var cols    := maxi(1, ceili(xz_sz.x / cell_sz))
	var rows    := maxi(1, ceili(xz_sz.y / cell_sz))

	var results: Array = []
	for row in rows:
		for col in cols:
			var px: float = md.xz_min.x + (float(col) + rng.randf()) * cell_sz
			var pz: float = md.xz_min.y + (float(row) + rng.randf()) * cell_sz

			var hit := _find_tri(px, pz, md.verts, md.idx, md.lookup)
			if not hit.found:
				continue

			var density := _sample_density(md.custom0, channel, hit.tri_i, hit.bary, md.idx)
			if rng.randf() > _acceptance(density, power):
				continue

			var local_pos := _interp_pos(md.verts, md.idx, hit.tri_i, hit.bary)
			var color     := _interp_color(md.colors, md.idx, hit.tri_i, hit.bary)
			results.append(_make_placement(local_pos, mmi.global_transform, color, scale_min, scale_max, rng))

	return results


## Poisson disk scatter (Bridson's algorithm).
## Enforces min_spacing between all accepted instances; each candidate is also
## accepted with probability density^power.  Returns as many as the algorithm
## produces (no hard upper bound — caller may cap if needed).
func scatter_poisson(
		mmi: MeshInstance3D, channel: int, min_spacing: float,
		power: float, scale_min: float, scale_max: float,
		rng: RandomNumberGenerator) -> Array:
	var md := _load_mesh_data(mmi)
	if md.is_empty() or min_spacing <= 0.0:
		return []

	var xz_sz: Vector2 = md.xz_size
	if xz_sz.x <= 0.0 or xz_sz.y <= 0.0:
		return []

	# Background grid cell size for O(1) neighbor checks.
	var cell_sz := min_spacing / sqrt(2.0)

	# grid maps Vector2i cell → index into spatial_pts
	var grid         := {}
	var spatial_pts: Array[Vector2] = []   # all placed XZ positions (spacing enforcement)
	var active:      Array[int]     = []   # indices into spatial_pts

	var results: Array = []

	# Seed one point per connected island so every disconnected region is covered.
	var island_seeds := _find_island_seeds(md.verts, md.idx)
	if island_seeds.is_empty():
		return []

	for seed_xz: Vector2 in island_seeds:
		if not spatial_pts.is_empty() and _has_neighbor(seed_xz, spatial_pts, grid, md.xz_min, cell_sz, min_spacing):
			continue
		var seed_i := spatial_pts.size()
		spatial_pts.append(seed_xz)
		active.append(seed_i)
		grid[_cell_key(seed_xz, md.xz_min, cell_sz)] = seed_i

		var sh := _find_tri(seed_xz.x, seed_xz.y, md.verts, md.idx, md.lookup)
		if sh.found:
			var density := _sample_density(md.custom0, channel, sh.tri_i, sh.bary, md.idx)
			if rng.randf() <= _acceptance(density, power):
				var local_pos := _interp_pos(md.verts, md.idx, sh.tri_i, sh.bary)
				var color     := _interp_color(md.colors, md.idx, sh.tri_i, sh.bary)
				results.append(_make_placement(local_pos, mmi.global_transform, color, scale_min, scale_max, rng))

	while not active.is_empty():
		var pick_i := rng.randi() % active.size()
		var parent := spatial_pts[active[pick_i]]
		var placed_child := false

		for _attempt in MAX_ATTEMPTS:
			var angle  := rng.randf() * TAU
			var radius := min_spacing * (1.0 + rng.randf())   # annulus [r, 2r]
			var cand   := parent + Vector2(cos(angle), sin(angle)) * radius

			# Bounds check
			if cand.x < md.xz_min.x or cand.x > md.xz_min.x + xz_sz.x:
				continue
			if cand.y < md.xz_min.y or cand.y > md.xz_min.y + xz_sz.y:
				continue

			# Spacing check against nearby samples
			if _has_neighbor(cand, spatial_pts, grid, md.xz_min, cell_sz, min_spacing):
				continue

			# Mesh surface check
			var hit := _find_tri(cand.x, cand.y, md.verts, md.idx, md.lookup)
			if not hit.found:
				continue

			# Density acceptance
			var density := _sample_density(md.custom0, channel, hit.tri_i, hit.bary, md.idx)
			if rng.randf() > _acceptance(density, power):
				continue

			# Accept: register in spatial grid even if density rejected (preserves spacing)
			var new_i := spatial_pts.size()
			spatial_pts.append(cand)
			active.append(new_i)
			grid[_cell_key(cand, md.xz_min, cell_sz)] = new_i
			placed_child = true

			var local_pos := _interp_pos(md.verts, md.idx, hit.tri_i, hit.bary)
			var color     := _interp_color(md.colors, md.idx, hit.tri_i, hit.bary)
			results.append(_make_placement(local_pos, mmi.global_transform, color, scale_min, scale_max, rng))
			break

		if not placed_child:
			active.remove_at(pick_i)

	return results


# ─── Mesh data loader ─────────────────────────────────────────────────────────

func _load_mesh_data(mmi: MeshInstance3D) -> Dictionary:
	if mmi == null or not is_instance_valid(mmi) or mmi.mesh == null:
		return {}
	var mesh := mmi.mesh
	if mesh.get_surface_count() == 0:
		return {}
	var arr    := mesh.surface_get_arrays(0)
	var verts  := arr[Mesh.ARRAY_VERTEX]  as PackedVector3Array
	var idx    := arr[Mesh.ARRAY_INDEX]   as PackedInt32Array
	var custom := arr[Mesh.ARRAY_CUSTOM0] as PackedFloat32Array
	var colors := arr[Mesh.ARRAY_COLOR]   as PackedColorArray
	if verts == null or verts.is_empty() or idx == null or idx.is_empty():
		return {}

	var xz_min := Vector2(INF,  INF)
	var xz_max := Vector2(-INF, -INF)
	for v in verts:
		if v.x < xz_min.x: xz_min.x = v.x
		if v.z < xz_min.y: xz_min.y = v.z
		if v.x > xz_max.x: xz_max.x = v.x
		if v.z > xz_max.y: xz_max.y = v.z

	var xz_size := xz_max - xz_min
	return {
		"verts":   verts,
		"idx":     idx,
		"custom0": custom if custom != null else PackedFloat32Array(),
		"colors":  colors if colors != null else PackedColorArray(),
		"xz_min":  xz_min,
		"xz_size": xz_size,
		"lookup":  _build_tri_lookup(verts, idx, xz_min, xz_size),
	}


# ─── Triangle spatial lookup ──────────────────────────────────────────────────

func _build_tri_lookup(
		verts: PackedVector3Array, idx: PackedInt32Array,
		xz_min: Vector2, xz_size: Vector2) -> Dictionary:
	var tri_count := idx.size() / 3
	var cell_sz   := maxf(maxf(xz_size.x, xz_size.y) / maxf(sqrt(float(tri_count)), 1.0), 0.001)
	var grid      := {}

	for t in tri_count:
		var v0 := verts[idx[t * 3    ]]
		var v1 := verts[idx[t * 3 + 1]]
		var v2 := verts[idx[t * 3 + 2]]
		var min_cx := floori((minf(minf(v0.x, v1.x), v2.x) - xz_min.x) / cell_sz)
		var max_cx := floori((maxf(maxf(v0.x, v1.x), v2.x) - xz_min.x) / cell_sz)
		var min_cz := floori((minf(minf(v0.z, v1.z), v2.z) - xz_min.y) / cell_sz)
		var max_cz := floori((maxf(maxf(v0.z, v1.z), v2.z) - xz_min.y) / cell_sz)
		for cx in range(min_cx, max_cx + 1):
			for cz in range(min_cz, max_cz + 1):
				var key := Vector2i(cx, cz)
				if not grid.has(key):
					grid[key] = []
				(grid[key] as Array).append(t)

	return {"cell_sz": cell_sz, "grid": grid, "xz_min": xz_min}


func _find_tri(
		px: float, pz: float,
		verts: PackedVector3Array, idx: PackedInt32Array,
		lookup: Dictionary) -> Dictionary:
	var cell_sz: float     = lookup.cell_sz
	var grid:    Dictionary = lookup.grid
	var xz_min:  Vector2   = lookup.xz_min

	var key := Vector2i(floori((px - xz_min.x) / cell_sz),
						floori((pz - xz_min.y) / cell_sz))
	if not grid.has(key):
		return {found = false}

	var p := Vector2(px, pz)
	for t: int in grid[key]:
		var v0 := verts[idx[t * 3    ]]
		var v1 := verts[idx[t * 3 + 1]]
		var v2 := verts[idx[t * 3 + 2]]
		var bary := _bary_xz(p, v0, v1, v2)
		if bary.x >= -1e-5 and bary.y >= -1e-5 and bary.z >= -1e-5:
			return {found = true, tri_i = t, bary = bary}

	return {found = false}


# ─── Math helpers ─────────────────────────────────────────────────────────────

## Barycentric coords in the XZ plane: returns (u,v,w) s.t. u*v0+v*v1+w*v2 = p.
func _bary_xz(p: Vector2, v0: Vector3, v1: Vector3, v2: Vector3) -> Vector3:
	var e0 := Vector2(v1.x - v0.x, v1.z - v0.z)
	var e1 := Vector2(v2.x - v0.x, v2.z - v0.z)
	var ep := p - Vector2(v0.x, v0.z)
	var d00 := e0.dot(e0);  var d01 := e0.dot(e1)
	var d11 := e1.dot(e1);  var d20 := ep.dot(e0);  var d21 := ep.dot(e1)
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 1e-10:
		return Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
	var bv := (d11 * d20 - d01 * d21) / denom
	var bw := (d00 * d21 - d01 * d20) / denom
	return Vector3(1.0 - bv - bw, bv, bw)


func _sample_density(
		custom0: PackedFloat32Array, channel: int,
		tri_i: int, bary: Vector3, idx: PackedInt32Array) -> float:
	if custom0.is_empty():
		return 1.0
	var i0 := idx[tri_i * 3]; var i1 := idx[tri_i * 3 + 1]; var i2 := idx[tri_i * 3 + 2]
	return clampf(
		custom0[i0 * 4 + channel] * bary.x +
		custom0[i1 * 4 + channel] * bary.y +
		custom0[i2 * 4 + channel] * bary.z,
		0.0, 1.0)


func _interp_pos(
		verts: PackedVector3Array, idx: PackedInt32Array,
		tri_i: int, bary: Vector3) -> Vector3:
	return (verts[idx[tri_i * 3    ]] * bary.x +
			verts[idx[tri_i * 3 + 1]] * bary.y +
			verts[idx[tri_i * 3 + 2]] * bary.z)


func _interp_color(
		colors: PackedColorArray, idx: PackedInt32Array,
		tri_i: int, bary: Vector3) -> Color:
	if colors.is_empty():
		return Color.WHITE
	return (colors[idx[tri_i * 3    ]] * bary.x +
			colors[idx[tri_i * 3 + 1]] * bary.y +
			colors[idx[tri_i * 3 + 2]] * bary.z)


func _acceptance(density: float, power: float) -> float:
	return pow(density, maxf(power, 0.001))


func _make_placement(
		local_pos: Vector3, xform: Transform3D,
		color: Color, scale_min: float, scale_max: float,
		rng: RandomNumberGenerator) -> Dictionary:
	return {
		"pos":   xform * local_pos,
		"color": color,
		"scale": rng.randf_range(scale_min, scale_max),
	}


## Returns one XZ seed point per connected triangle component (island detection).
## Uses shared-edge adjacency so a road gap in the mesh produces separate seeds.
func _find_island_seeds(
		verts: PackedVector3Array, idx: PackedInt32Array) -> Array[Vector2]:
	var tri_count := idx.size() / 3
	if tri_count == 0:
		return []

	# Map each undirected edge to the first triangle that owns it; on the second
	# occurrence, link the two triangles as adjacent.
	var edge_to_tri := {}
	var adj: Array = []
	adj.resize(tri_count)
	for t in tri_count:
		adj[t] = PackedInt32Array()

	for t in tri_count:
		for k in 3:
			var va := idx[t * 3 + k]
			var vb := idx[t * 3 + (k + 1) % 3]
			var edge := Vector2i(mini(va, vb), maxi(va, vb))
			if edge_to_tri.has(edge):
				var other: int = edge_to_tri[edge]
				(adj[t] as PackedInt32Array).append(other)
				(adj[other] as PackedInt32Array).append(t)
			else:
				edge_to_tri[edge] = t

	# BFS: emit one centroid seed per connected component.
	var visited := PackedByteArray()
	visited.resize(tri_count)
	var seeds: Array[Vector2] = []

	for start in tri_count:
		if visited[start]:
			continue
		var queue := PackedInt32Array([start])
		visited[start] = 1
		var head := 0
		while head < queue.size():
			var t: int = queue[head]
			head += 1
			for nb: int in (adj[t] as PackedInt32Array):
				if not visited[nb]:
					visited[nb] = 1
					queue.append(nb)
		var v0 := verts[idx[start * 3    ]]
		var v1 := verts[idx[start * 3 + 1]]
		var v2 := verts[idx[start * 3 + 2]]
		seeds.append(Vector2((v0.x + v1.x + v2.x) / 3.0,
							 (v0.z + v1.z + v2.z) / 3.0))

	return seeds


func _cell_key(p: Vector2, xz_min: Vector2, cell_sz: float) -> Vector2i:
	return Vector2i(floori((p.x - xz_min.x) / cell_sz),
					floori((p.y - xz_min.y) / cell_sz))


func _has_neighbor(
		cand: Vector2, pts: Array,
		grid: Dictionary, xz_min: Vector2,
		cell_sz: float, min_spacing: float) -> bool:
	var radius := ceili(min_spacing / cell_sz) + 1
	var cc     := _cell_key(cand, xz_min, cell_sz)
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var key := Vector2i(cc.x + dx, cc.y + dz)
			if not grid.has(key):
				continue
			var ni: int = grid[key]
			if cand.distance_to(pts[ni]) < min_spacing:
				return true
	return false
