shader_type spatial;

varying float red;
varying float green;
varying float blue;
varying float alpha;

void vertex() {
	// Called for every vertex the material is visible on.
	red = CUSTOM0.r;
	green = CUSTOM0.g;
	blue = CUSTOM0.b;
	alpha = CUSTOM0.a;
}

void fragment() {
	// Called for every pixel the material is visible on.
	ALBEDO = vec3(red, 1.0-green, blue);
	ALPHA = 1.0 - alpha;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
