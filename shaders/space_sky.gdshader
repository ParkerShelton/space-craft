shader_type sky;

// Blends between black space (with stars) and a lit atmosphere sky. `atmo` (0..1)
// is driven from code based on how deep in a planet's atmosphere the player is;
// `atmo_up` is the player's local up so the sky gradient looks right anywhere on
// the planet (bright overhead, paler at the horizon).

uniform float star_density = 0.996;
uniform float star_scale = 300.0;
uniform float atmo : hint_range(0.0, 1.0) = 0.0;
uniform vec3 atmo_up = vec3(0.0, 1.0, 0.0);
uniform vec3 sky_color : source_color = vec3(0.45, 0.68, 1.0);
uniform vec3 horizon_color : source_color = vec3(0.75, 0.85, 1.0);
// Day/night. `sun_dir` points FROM the viewer TOWARD the sun, so a sun disc can
// be drawn and the sky brightened around it; `day` is 0 at night, 1 at noon.
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float day : hint_range(0.0, 1.0) = 1.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);

	// Stars fade out as the atmosphere thickens -- but they come BACK at night,
	// which is most of what sells a day/night cycle from the ground.
	float h = hash13(floor(d * star_scale));
	float star_hide = atmo * day;
	vec3 space = vec3(step(star_density, h) * (1.0 - star_hide));

	// atmosphere: bright overhead (along local up), paler toward the horizon
	float u = clamp(dot(d, normalize(atmo_up)) * 0.5 + 0.5, 0.0, 1.0);
	vec3 skycol = mix(horizon_color, sky_color, u);

	// The sun itself: a disc, with a broad glow around it that warms the sky
	// near the horizon at dawn and dusk.
	vec3 sd = normalize(sun_dir);
	float sun_d = dot(d, sd);
	float disc = smoothstep(0.9994, 0.9997, sun_d);
	float glow = pow(max(sun_d, 0.0), 220.0) * 0.5 + pow(max(sun_d, 0.0), 8.0) * 0.12;
	vec3 sun_col = mix(vec3(1.0, 0.55, 0.25), vec3(1.0, 0.96, 0.88), day);

	vec3 sky_lit = skycol + sun_col * glow * atmo;
	COLOR = mix(space, sky_lit, atmo);
	// The disc stays visible in space too, where there is no atmosphere.
	COLOR += sun_col * disc;
}
