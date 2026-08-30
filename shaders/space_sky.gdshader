shader_type sky;

// Dead simple: pure black space with sparse white star dots. No twinkle, no tint.

uniform float star_density = 0.996;  // higher = fewer stars
uniform float star_scale = 300.0;    // higher = smaller/denser grid

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = hash13(floor(d * star_scale));
	float star = step(star_density, h);
	COLOR = vec3(star);
}
