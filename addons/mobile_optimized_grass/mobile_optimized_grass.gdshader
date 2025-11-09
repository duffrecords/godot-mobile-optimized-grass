shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, alpha_to_coverage_and_one, ambient_light_disabled, fog_disabled, shadows_disabled;

uniform sampler2D grass_texture : source_color;
uniform float alpha_scissor_threshold : hint_range(0,1) = 0.25;
uniform float alpha_antialiasing_edge : hint_range(0, 1) = 0.15;

uniform float min_height = 0.0;
uniform float max_height = 1.0;
uniform float blend_factor : hint_range(0.0, 1.0) = 0.5;

//varying vec4 instance_color;
//varying vec3 world_pos;
// Pass blend factor from vertex to fragment
varying float height_factor;
varying vec3 linear_instance_color;

varying float v_blend;
varying vec3 v_inst_lin;

vec3 to_linear(vec3 c) {
	return pow(c, vec3(2.2));
}

vec3 srgb_to_linear(vec3 color) {
	return mix(
		pow((color.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),
		color.rgb * (1.0 / 12.92),
		lessThan(color.rgb, vec3(0.04045))
	);
}

vec3 linear_to_srgb(vec3 color) {
	// If going to srgb, clamp from 0 to 1.
	color = clamp(color, vec3(0.0), vec3(1.0));
	const vec3 a = vec3(0.055f);
	return mix(
		(vec3(1.0f) + a) * pow(color.rgb, vec3(1.0f / 2.4f)) - a,
		12.92f * color.rgb,
		lessThan(color.rgb, vec3(0.0031308f))
	);
}

void vertex() {
	// instance_color = COLOR; // Per-instance color for MultiMesh
	// linearize per-instance color once in the vertex stage
	linear_instance_color = to_linear(COLOR.rgb);
	// world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Read scale from CUSTOM_DATA.x
	float scale = INSTANCE_CUSTOM.r;

	// Calculate normalized height of the vertex inside the mesh
	float vertex_height = max(VERTEX.y - min_height, 0.0);
	float total_height = max(max_height - min_height, 0.0);
	height_factor = clamp(vertex_height / (total_height), 0.0, 1.0);
	//blend_factor = smoothstep(0.0, 1.0, (VERTEX.y - min_height) / (max_height - min_height));
	// per-vertex vertical gradient
	v_blend = clamp((VERTEX.y - min_height) / max(max_height - min_height, 1e-5), 0.0, 1.0);

	// Apply uniform scale to instance transform's basis
	VERTEX *= scale;

}

void fragment() {
	vec4 tex = texture(grass_texture, UV);
	// Slide the gradient: map coverage [0,1] -> shift [-1,1]
	float shift = blend_factor * 2.0 - 1.0;
	// Offset and clamp. Result 0→1 will be used to mix texture→instance color
	float adjusted = clamp(v_blend + shift, 0.0, 1.0);

	// Sharpen alpha for MSAA alpha-to-coverage
	tex.a = (tex.a - alpha_scissor_threshold) / max(fwidth(tex.a), 0.0001) + 0.5;

	vec3 final_color = mix(tex.rgb, linear_instance_color.rgb, blend_factor);
	ALBEDO = final_color;
	//ALBEDO = vec3(clamp(height_factor, 0.0, 1.0-blend_factor));
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
	ALPHA_ANTIALIASING_EDGE = alpha_antialiasing_edge;
}
