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


void vertex() {
	linear_instance_color = COLOR.rgb;
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
