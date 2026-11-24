shader_type spatial;
#include "res://assets/materials/blender_noise.gdshaderinc"

varying vec3 obj_pos;

// Blender "Magic Texture" node, depth = 5.
vec4 magic_texture(vec3 co, float scale, float distortion) {
	vec3 p = co * scale;
	float x = sin((p.x + p.y + p.z) * 5.0);
	float y = cos((-p.x + p.y - p.z) * 5.0);
	float z = -cos((-p.x - p.y + p.z) * 5.0);

	x *= distortion; y *= distortion; z *= distortion;
	y = -cos(x - y + z);  y *= distortion;
	x = cos(x - y - z);   x *= distortion;
	z = sin(-x - y - z);  z *= distortion;
	x = -cos(-x + y - z); x *= distortion;
	y = -sin(-x + y - z); y *= distortion;

	if (distortion != 0.0) {
		float d = distortion * 2.0;
		x /= d; y /= d; z /= d;
	}
	return vec4(0.5 - x, 0.5 - y, 0.5 - z, 1.0);
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

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void vertex() {
	// Blender "Object" coordinates (Z-up) from Godot local space (Y-up).
	obj_pos = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
}

void fragment() {
	vec3 p = obj_pos; // Mapping node is identity

	// Noise.001 (scale 5, detail 10, rough 0.8) -> Mix Linear Light (fac 0.06) -> Noise
	float n_a = noise_fbm(p * 5.0, 10, 0.8, 2.0);
	vec3 p1 = p + 0.06 * 2.0 * (vec3(n_a) - 0.5);
	float n1 = noise_fbm(p1 * 6.0, 10, 0.7, 2.0); // Noise (scale 6, detail 10, rough 0.7)

	// Noise.002 (scale 6, detail 10, rough 0.55) -> Mix.001 Linear Light (fac 0.1) -> Magic
	float n2 = noise_fbm(p * 6.0, 10, 0.55, 2.0);
	vec3 p2 = p + 0.1 * 2.0 * (vec3(n2) - 0.5);
	float magic = luma(magic_texture(p2, 2.0, 5.0).rgb); // Magic: scale 2, distortion 5

	// Colour Ramp.001: 1.0 at 0.0 -> 0.0 at 0.1
	float mask = 1.0 - clamp(magic / 0.10000010579824448, 0.0, 1.0);

	// Colour Ramp: 0.5711 at 0.3227 -> 1.0 at 0.746
	float t = clamp((n1 - 0.3227272033691406) / (0.7459999918937683 - 0.3227272033691406), 0.0, 1.0);
	float ramp = mix(0.5711, 1.0, t);

	// Mix.002 (Lighten, fac = mask, B = 0.8388); Hue/Sat/Value is identity
	float rough = max(ramp, 0.8387992978096008 * mask);

	ALBEDO = vec3(0.0);
	METALLIC = 0.0;
	ROUGHNESS = rough;

	// Bump (height = Noise) -> Bump.001 (height = Colour Ramp.001) -> Normal
	vec3 nrm = bump(0.04, 0.001, n1, NORMAL, VERTEX);
	nrm = bump(0.02, 0.001, mask, nrm, VERTEX);
	NORMAL = nrm;
}