// grass_preview.gdshader — editor-only debug overlay for the Grass Painter dock.
// Displays ARRAY_CUSTOM0 density data and ARRAY_COLOR ground tint on the terrain mesh.
//
// Uniforms:
//   active_channel  0–3 = CUSTOM0 density channel (R/G/B/A), 4 = ARRAY_COLOR ground tint
//   preview_mode    0 = single-channel grayscale, 1 = composite RGBA colour overlay

shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, ambient_light_disabled, fog_disabled;

uniform int active_channel : hint_range(0, 4) = 0;
uniform int preview_mode   : hint_range(0, 1) = 0;

varying vec4 v_density; // CUSTOM0 — packed R/G/B/A scatter-density channels
varying vec4 v_tint;    // COLOR   — ARRAY_COLOR ground tint

void vertex() {
	v_density = CUSTOM0;
	v_tint    = COLOR;
}

void fragment() {
	if (active_channel == 4) {
		// Ground-tint view: show ARRAY_COLOR directly
		ALBEDO = v_tint.rgb;

	} else if (preview_mode == 1) {
		// Composite: all four density channels as additive colour blobs
		//   R → red   G → green   B → blue   A → purple
		vec3 col = vec3(0.0);
		col += v_density.r * vec3(1.00, 0.25, 0.25);
		col += v_density.g * vec3(0.25, 1.00, 0.25);
		col += v_density.b * vec3(0.25, 0.50, 1.00);
		col += v_density.a * vec3(0.80, 0.40, 1.00);
		ALBEDO = clamp(col, 0.0, 1.0);

	} else {
		// Single-channel grayscale
		float value = 0.0;
		if      (active_channel == 0) value = v_density.r;
		else if (active_channel == 1) value = v_density.g;
		else if (active_channel == 2) value = v_density.b;
		else                          value = v_density.a;
		ALBEDO = vec3(value);
	}
}
