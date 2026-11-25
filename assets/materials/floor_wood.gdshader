shader_type spatial;
#include "res://assets/materials/blender_voronoi.gdshaderinc"

// Light, worn floor wood (planks). Values are scene-linear.
uniform vec3 wood_light = vec3(0.62, 0.42, 0.22);
uniform vec3 wood_dark = vec3(0.34, 0.19, 0.09);
uniform vec3 worn_color = vec3(0.55, 0.45, 0.34); // bleached by foot traffic
uniform vec3 gap_color = vec3(0.06, 0.035, 0.02);
uniform float plank_count = 8.0;     // number of planks across the V direction
uniform float plank_aspect = 6.0;    // plank length / plank width
uniform float gap_width = 0.025;     // in plank widths
uniform float tint_variation = 0.15; // brightness variation between planks
uniform float wear_amount = 0.6;
uniform float roughness_min = 0.62;
uniform float roughness_max = 0.9;
uniform float bump_strength = 0.35;

void fragment() {
	// glTF flips V on export, so restore Blender's V.
	vec2 uv = vec2(UV.x, 1.0 - UV.y);

	// Plank grid (assumes a roughly square UV extent): x = along the plank, y = across.
	vec2 g = vec2(uv.x * plank_count / plank_aspect, uv.y * plank_count);
	// Stagger each row of planks randomly.
	g.x += hash_vec3_to_float(vec3(floor(g.y), 11.0, 3.0));
	vec2 cell = floor(g);
	vec2 f = fract(g);
	float seed = hash_vec3_to_float(vec3(cell, 5.0));
	float seed2 = hash_vec3_to_float(vec3(cell, 9.0));

	// Grain: stretched along the plank (coordinates in plank widths).
	vec3 gp = vec3(f.x * plank_aspect * 0.25 + seed * 37.0, f.y * 14.0, seed2 * 37.0);
	float grain = noise_fbm_d(gp, 6, 0.55, 2.0, 0.3);
	float fine = noise_fbm(vec3(f.x * plank_aspect * 0.05 + seed * 11.0, f.y * 120.0, 1.7), 2, 0.5, 2.0);
	float rings = 0.5 + 0.5 * sin(6.28318 * (f.y * 5.0 + (grain - 0.5) * 3.0 + seed * 7.0));
	float g_t = clamp(0.55 * rings + 0.45 * grain + (fine - 0.5) * 0.5, 0.0, 1.0);

	vec3 wood = mix(wood_light, wood_dark, g_t * g_t);
	wood *= 1.0 + (seed - 0.5) * 2.0 * tint_variation;

	// Wear: large soft patches, bleached and rougher.
	float wear_n = noise_fbm(vec3(g * 0.35, 2.3), 5, 0.6, 2.0);
	float wear = smoothstep(0.42, 0.72, wear_n) * wear_amount;
	wood = mix(wood, worn_color * (0.8 + 0.4 * fine), wear * 0.7);

	// Fine scratches along the planks.
	float sc_n = noise_fbm(vec3(uv.x * plank_count / plank_aspect * 3.0, uv.y * plank_count * 60.0, 4.0), 2, 0.5, 2.0);
	float scratch = smoothstep(0.62, 0.68, sc_n);
	wood = mix(wood, wood * 1.35 + 0.03, scratch * 0.5);

	// Gaps between planks (sides and ends), with dirt darkening near the edges.
	float d = min(min(f.y, 1.0 - f.y), min(f.x, 1.0 - f.x) * plank_aspect);
	float gap = 1.0 - smoothstep(gap_width, gap_width * 2.0, d);
	float edge_dirt = smoothstep(gap_width * 2.0, gap_width * 6.0, d);
	wood *= mix(0.75, 1.0, edge_dirt);
	wood = mix(wood, gap_color, gap);

	ALBEDO = wood;
	METALLIC = 0.0;
	SPECULAR = 0.35;
	float rough = mix(roughness_min, roughness_max, clamp(wear + (1.0 - g_t) * 0.15, 0.0, 1.0));
	ROUGHNESS = mix(rough, 1.0, gap);

	// Relief: grain, scratches and gaps.
	float height = 0.5 + (g_t - 0.5) * 0.25 - scratch * 0.15 - gap * 0.6;
	NORMAL = bump(bump_strength, 0.01, height, NORMAL, VERTEX);
}