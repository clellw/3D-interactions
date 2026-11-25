shader_type spatial;
#include "res://assets/materials/blender_voronoi.gdshaderinc"

// Blender "Metals with imperfections generator" (Silver). Values are scene-linear.
uniform vec3 main_color = vec3(0.96469, 0.94731, 0.92158); // Metals colors > Silver
uniform vec3 rim_color = vec3(0.0302668, 0.0302668, 0.0302668);
uniform float rim_size = 0.2;
uniform float roughness_base = 0.6;
uniform float metallic_value = 0.85;
uniform float dirt_strength = 0.2;
uniform float dirt_size = 20.0;
uniform float scratches_depth = 0.0746448;
uniform float scratches_size = 6.6;

// Bounding box of the mesh in Blender local space (for "Generated" coordinates).
// Values for the "Cube" object of sword.blend.
uniform vec3 bbox_min = vec3(-1.1702, -1.038, -1.0);
uniform vec3 bbox_size = vec3(2.3405, 2.076, 5.1324);

varying vec3 obj_pos;

void vertex() {
	// Blender "Object" coordinates (Z-up) from Godot local space (Y-up).
	obj_pos = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
}

void fragment() {
	// Blender "Generated" coordinates.
	vec3 gen = (obj_pos - bbox_min) / bbox_size;
	vec3 n0 = normalize(NORMAL);

	// --- Dirt: Noise (scale DirtSize, detail 7, rough 0.5, distortion 0.4) -> Separate HSV (H)
	vec3 dirt_col = noise_fbm_color(gen * dirt_size, 7, 0.5, 2.0, 0.4);
	float hue = rgb_to_hsv(dirt_col).x;
	// Mix.001 (fac 0.913): vec3(H) -> Generated -> Noise.001 (scale 8, detail 2, rough 0.5)
	vec3 q = mix(vec3(hue), gen, 0.913);
	float dirt = noise_fbm(q * 8.0, 2, 0.5, 2.0) * dirt_strength;

	// Mix.002 (Add): Roughness + dirt
	float rough = clamp(roughness_base + dirt, 0.0, 1.0);

	// --- Scratches: 3 stretched noises (Object coords), thresholded then Darken (min)
	vec3 po = obj_pos * scratches_size;
	float s0 = step(0.20909091, noise_fbm_d(po * vec3(200.0, 1.0, 1.0), 0, 0.5, 2.0, 2.5));
	float s1 = step(0.20909091, noise_fbm_d(po * vec3(1.0, 200.0, 1.0), 0, 0.5, 2.0, 2.5));
	float s2 = step(0.20909091, noise_fbm_d(po * vec3(1.0, 1.0, 200.0), 0, 0.5, 2.0, 2.5));
	float height = min(min(s0, s1), s2);

	// --- Rim colour (Layer Weight, Facing, Blend = RimSize)
	float facing = layer_weight_facing(rim_size, n0, VIEW);

	ALBEDO = mix(main_color, rim_color, facing);
	METALLIC = metallic_value;
	ROUGHNESS = rough;
	// Bump (strength ScratchesDepth, distance 0.1)
	NORMAL = bump(scratches_depth, 0.1, height, NORMAL, VERTEX);
}