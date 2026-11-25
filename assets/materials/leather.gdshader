shader_type spatial;
#include "res://assets/materials/blender_voronoi.gdshaderinc"

// Blender group "BasicLeatherProcedural" (values are scene-linear).
uniform vec3 color_a = vec3(0.20, 0.09, 0.035);
uniform vec3 color_b = vec3(0.10, 0.04, 0.015);
uniform vec3 color_c = vec3(0.14, 0.065, 0.028);
uniform float base_scale = 1.0;
uniform float leather_scale = 30.0;
uniform float noise_scale = 40.0;
uniform float roughness_value = 0.5;
uniform float noise_bump_strength = 0.06;
uniform float detail_bump_strength = 0.025;

varying vec3 obj_pos;

void vertex() {
	// Blender "Object" coordinates (Z-up) from Godot local space (Y-up).
	obj_pos = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
}

void fragment() {
	// Mapping node: scale = Base Scale
	vec3 p = obj_pos * base_scale;

	// Noise Texture: scale 40, detail 15, roughness 0.6, distortion 0.15
	vec3 nc = noise_fbm_color(p * noise_scale, 15, 0.6, 2.0, 0.15);
	float n_fac = nc.x;

	// Mix (Linear Light, fac 0.0054): coordinates + noise colour -> Voronoi vector
	vec3 pv = p + 0.00541688 * 2.0 * (nc - 0.5);

	// Voronoi (Distance to Edge), scale = Leather Scale * 20
	float edge = voronoi_distance_to_edge(pv, leather_scale * 20.0, 1.0);

	// Colour Ramp: white at 0.025 -> black at 0.15455
	float t_edge = 1.0 - clamp((edge - 0.025) / (0.15454545 - 0.025), 0.0, 1.0);

	// Mix.001 (A/B by edge ramp), Mix.002 (-> Color C by noise ramp)
	vec3 col_ab = mix(color_a, color_b, t_edge);
	float t_noise = clamp((n_fac - 0.34545454) / (0.67727273 - 0.34545454), 0.0, 1.0);
	vec3 base = mix(col_ab, color_c, t_noise);
	ALBEDO = base;

	// Colour Ramp.002 (0.521 -> 1.0) then Hue/Sat/Value "Value" = Roughness
	float lum = clamp(luma(base), 0.0, 1.0);
	ROUGHNESS = mix(0.52099, 1.0, lum) * roughness_value;
	METALLIC = 0.0;

	// Bump.002 (colour) -> Bump.001 (Noise) -> Bump (Noise.001, scale 20, detail 2)
	vec3 nrm = bump(0.25, 1.0, luma(base), NORMAL, VERTEX);
	nrm = bump(noise_bump_strength, 1.0, n_fac, nrm, VERTEX);
	float n_detail = noise_fbm(p * 20.0, 2, 0.55, 2.0);
	nrm = bump(detail_bump_strength, 1.0, n_detail, nrm, VERTEX);
	NORMAL = nrm;
}