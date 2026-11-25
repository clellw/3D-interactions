shader_type spatial;
#include "res://assets/materials/blender_noise.gdshaderinc"

// Blender "Wave Texture" node: Bands, Sin profile, detail 15, detail scale 5, detail roughness 0.5.
// "p" is the UV vector (Mapping is identity); "scale" is the node Scale.
float wave_bands(vec3 p, float scale, bool along_x, float distortion) {
	p *= scale;
	// Same precision guard as Blender's kernel.
	p = (p + 0.000001) * 0.999999;

	float n = (along_x ? p.x : p.y) * 20.0;

	if (distortion != 0.0) {
		n += distortion * (noise_fbm(p * 5.0, 15, 0.5, 2.0) * 2.0 - 1.0);
	}

	// Sine profile.
	return 0.5 + 0.5 * sin(n - 1.5707963267948966);
}

// Blender "Bump" node (derivative based, EEVEE style).
vec3 bump(float strength, float dist, float height, vec3 n, vec3 pos) {
	n = normalize(n);
	vec3 dPdx = dFdx(pos);
	vec3 dPdy = dFdy(pos);
	vec3 Rx = cross(dPdy, n);
	vec3 Ry = cross(n, dPdx);
	float det = dot(dPdx, Rx);
	float absdet = abs(det);
	vec3 surfgrad = dFdx(height) * Rx + dFdy(height) * Ry;
	vec3 bumped = normalize(absdet * n - dist * sign(det) * surfgrad);
	return normalize(mix(n, bumped, max(strength, 0.0)));
}

void fragment() {
	// glTF flips V on export, so restore Blender's V.
	vec2 uv = vec2(UV.x, 1.0 - UV.y);
	vec3 p = vec3(uv, 0.0); // Mapping node is identity

	// Wave Texture (bands X, scale 25) -> Colour Ramp.001 (0.39773 -> 0.82273)
	float w1 = wave_bands(p, 25.0, true, 3.5);
	float a = clamp((w1 - 0.3977272808551788) / (0.8227272629737854 - 0.3977272808551788), 0.0, 1.0);

	// Wave Texture.001 (bands Y, scale 22) -> Colour Ramp (0 -> 1, identity)
	float b = wave_bands(p, 22.0, false, 3.5);

	// Mix (factor 0.5, A = ramp.001, B = ramp)
	float m = mix(a, b, 0.5);

	// Mix.001 -> Base Color (factor = m, values are scene-linear)
	ALBEDO = mix(
		vec3(0.02217, 0.01096, 0.00402),
		vec3(0.29614, 0.17144, 0.07421),
		m
	);

	// Colour Ramp.002 -> Roughness (0.5972 -> 1.0)
	ROUGHNESS = mix(0.5972, 1.0, m);
	METALLIC = 0.0;

	// Bump (strength 0.15, distance 0.001, height = Mix)
	NORMAL = bump(0.15, 0.001, m, NORMAL, VERTEX);
}