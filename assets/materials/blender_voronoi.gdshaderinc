// Second Blender-node include: distorted noise, Voronoi, White Noise and
// small shader-node helpers (Bump, Layer Weight, Fresnel, HSV...).
// Ported from Blender's GLSL sources (hash, tex_noise, tex_voronoi).
#include "res://assets/materials/blender_noise.gdshaderinc"

// ---------------------------------------------------------------------------
// Extra hashing (Jenkins, same as Blender's gpu_shader_common_hash.glsl)
// ---------------------------------------------------------------------------

uint hash_uint4(uint kx, uint ky, uint kz, uint kw) {
	// 0xdeadbeef + (4 << 2) + 13
	uint init = 3735928588u;
	uint a = init + kx;
	uint b = init + ky;
	uint c = init + kz;
	a -= c; a ^= rot32(c, 4u);  c += b;
	b -= a; b ^= rot32(a, 6u);  a += c;
	c -= b; c ^= rot32(b, 8u);  b += a;
	a -= c; a ^= rot32(c, 16u); c += b;
	b -= a; b ^= rot32(a, 19u); a += c;
	c -= b; c ^= rot32(b, 4u);  b += a;
	a += kw;
	c ^= b; c -= rot32(b, 14u);
	a ^= c; a -= rot32(c, 11u);
	b ^= a; b -= rot32(a, 25u);
	c ^= b; c -= rot32(b, 16u);
	a ^= c; a -= rot32(c, 4u);
	b ^= a; b -= rot32(a, 14u);
	c ^= b; c -= rot32(b, 24u);
	return c;
}

float hash_vec3_to_float(vec3 k) {
	return float(hash_uint3(floatBitsToUint(k.x), floatBitsToUint(k.y), floatBitsToUint(k.z))) / 4294967296.0;
}

float hash_vec4_to_float(vec4 k) {
	return float(hash_uint4(floatBitsToUint(k.x), floatBitsToUint(k.y), floatBitsToUint(k.z), floatBitsToUint(k.w))) / 4294967296.0;
}

vec3 hash_vec3_to_vec3(vec3 k) {
	return vec3(hash_vec3_to_float(k),
				hash_vec4_to_float(vec4(k, 1.0)),
				hash_vec4_to_float(vec4(k, 2.0)));
}

// ---------------------------------------------------------------------------
// Noise Texture node: fBM, 3D, with Distortion, Color output and float Detail
// ---------------------------------------------------------------------------

// Fractional detail + optional normalization (Blender "Normalize" checkbox).
float noise_fbm_full(vec3 p, float detail, float roughness, float lacunarity, bool do_normalize) {
	float fscale = 1.0;
	float amp = 1.0;
	float maxamp = 0.0;
	float sum = 0.0;
	for (int i = 0; i <= int(detail); i++) {
		sum += noise_snoise(fscale * p) * amp;
		maxamp += amp;
		amp *= roughness;
		fscale *= lacunarity;
	}
	float rmd = detail - floor(detail);
	if (rmd != 0.0) {
		float sum2 = sum + noise_snoise(fscale * p) * amp;
		if (do_normalize) {
			return mix(0.5 * sum / maxamp + 0.5, 0.5 * sum2 / (maxamp + amp) + 0.5, rmd);
		}
		return mix(sum, sum2, rmd);
	}
	return do_normalize ? 0.5 * (sum / maxamp) + 0.5 : sum;
}

// Blender's distortion: p += snoise(p + random_vec3_offset(i)) * distortion.
// Offsets are Blender's random_vec3_offset(0..4), precomputed.
vec3 noise_distort(vec3 p, float distortion) {
	if (distortion != 0.0) {
		p += vec3(noise_snoise(p + vec3(186.0313, 114.9560, 154.4475)),
				  noise_snoise(p + vec3(199.8400, 162.2926, 154.0482)),
				  noise_snoise(p + vec3(111.6338, 157.3694, 199.0881))) * distortion;
	}
	return p;
}

// Noise Texture "Fac" output (normalize on), "p" already multiplied by Scale.
float noise_fbm_d(vec3 p, int detail, float roughness, float lacunarity, float distortion) {
	return noise_fbm(noise_distort(p, distortion), detail, roughness, lacunarity);
}

// Noise Texture "Color" output (normalize on), "p" already multiplied by Scale.
vec3 noise_fbm_color(vec3 p, int detail, float roughness, float lacunarity, float distortion) {
	p = noise_distort(p, distortion);
	return vec3(noise_fbm(p, detail, roughness, lacunarity),
				noise_fbm(p + vec3(165.4453, 162.7682, 193.4084), detail, roughness, lacunarity),
				noise_fbm(p + vec3(155.5809, 177.1546, 138.1400), detail, roughness, lacunarity));
}

// ---------------------------------------------------------------------------
// White Noise Texture node (3D)
// ---------------------------------------------------------------------------

float white_noise_3d(vec3 p) {
	return hash_vec3_to_float(p);
}

// ---------------------------------------------------------------------------
// Voronoi Texture node (3D, Euclidean, Detail 0)
// ---------------------------------------------------------------------------

struct VoronoiResult {
	float dist;
	vec3 color;
	vec3 pos;
};

// Feature "Smooth F1". "smoothness" is the node's Smoothness socket (0..1, must be > 0).
VoronoiResult voronoi_smooth_f1(vec3 coord, float scale, float smoothness, float randomness) {
	float sm = clamp(smoothness / 2.0, 0.0, 0.5);
	float rnd = clamp(randomness, 0.0, 1.0);
	coord *= scale;

	vec3 cell = floor(coord);
	vec3 local = coord - cell;

	float smooth_dist = 0.0;
	vec3 smooth_col = vec3(0.0);
	vec3 smooth_pos = vec3(0.0);
	float h = -1.0;
	for (int k = -2; k <= 2; k++) {
		for (int j = -2; j <= 2; j++) {
			for (int i = -2; i <= 2; i++) {
				vec3 offs = vec3(float(i), float(j), float(k));
				vec3 cell_hash = hash_vec3_to_vec3(cell + offs);
				vec3 point_pos = offs + cell_hash * rnd;
				float d = distance(point_pos, local);
				h = (h == -1.0) ? 1.0 : smoothstep(0.0, 1.0, 0.5 + 0.5 * (smooth_dist - d) / sm);
				float correction = sm * h * (1.0 - h);
				smooth_dist = mix(smooth_dist, d, h) - correction;
				correction /= 1.0 + 3.0 * sm;
				smooth_col = mix(smooth_col, cell_hash, h) - correction;
				smooth_pos = mix(smooth_pos, point_pos, h) - correction;
			}
		}
	}

	VoronoiResult r;
	r.dist = smooth_dist;
	r.color = smooth_col;
	r.pos = (cell + smooth_pos) / scale;
	return r;
}

// Feature "Distance to Edge".
float voronoi_distance_to_edge(vec3 coord, float scale, float randomness) {
	float rnd = clamp(randomness, 0.0, 1.0);
	coord *= scale;

	vec3 cell = floor(coord);
	vec3 local = coord - cell;

	vec3 to_closest = vec3(0.0);
	float min_d = 1.0e10;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec3 offs = vec3(float(i), float(j), float(k));
				vec3 to_point = offs + hash_vec3_to_vec3(cell + offs) * rnd - local;
				float d = dot(to_point, to_point);
				if (d < min_d) {
					min_d = d;
					to_closest = to_point;
				}
			}
		}
	}

	min_d = 1.0e10;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec3 offs = vec3(float(i), float(j), float(k));
				vec3 to_point = offs + hash_vec3_to_vec3(cell + offs) * rnd - local;
				vec3 perp = to_point - to_closest;
				if (dot(perp, perp) > 0.0001) {
					float d_edge = dot((to_closest + to_point) / 2.0, normalize(perp));
					min_d = min(min_d, d_edge);
				}
			}
		}
	}
	return min_d;
}

// ---------------------------------------------------------------------------
// Small shader-node helpers
// ---------------------------------------------------------------------------

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
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

// Blender "Fresnel" / Layer Weight maths. "incoming" points towards the camera.
float fresnel_dielectric(vec3 incoming, vec3 n, float eta) {
	float c = abs(dot(incoming, n));
	float g = eta * eta - 1.0 + c * c;
	if (g > 0.0) {
		g = sqrt(g);
		float A = (g - c) / (g + c);
		float B = (c * (g + c) - 1.0) / (c * (g - c) + 1.0);
		return 0.5 * A * A * (1.0 + B * B);
	}
	return 1.0;
}

// Blender "Fresnel" node.
float fresnel_node(float ior, vec3 n, vec3 incoming, bool front_facing) {
	float eta = max(ior, 0.00001);
	return fresnel_dielectric(incoming, normalize(n), front_facing ? eta : 1.0 / eta);
}

// Blender "Layer Weight" node, Fresnel output.
float layer_weight_fresnel(float blend, vec3 n, vec3 incoming, bool front_facing) {
	float eta = max(1.0 - blend, 0.00001);
	return fresnel_dielectric(incoming, normalize(n), front_facing ? 1.0 / eta : eta);
}

// Blender "Layer Weight" node, Facing output.
float layer_weight_facing(float blend, vec3 n, vec3 incoming) {
	float facing = abs(dot(incoming, normalize(n)));
	if (blend != 0.5) {
		blend = clamp(blend, 0.0, 0.99999);
		blend = (blend < 0.5) ? 2.0 * blend : 0.5 / (1.0 - blend);
		facing = pow(facing, blend);
	}
	return 1.0 - facing;
}

// Blender "Brightness/Contrast" node.
float brightness_contrast(float v, float bright, float contrast) {
	return max((1.0 + contrast) * v + (bright - contrast * 0.5), 0.0);
}

vec3 rgb_to_hsv(vec3 c) {
	float cmax = max(c.r, max(c.g, c.b));
	float cmin = min(c.r, min(c.g, c.b));
	float cdelta = cmax - cmin;
	float h = 0.0;
	float s = 0.0;
	float v = cmax;
	if (cmax != 0.0) {
		s = cdelta / cmax;
	}
	if (s != 0.0) {
		vec3 cc = (vec3(cmax) - c) / cdelta;
		if (c.r == cmax) {
			h = cc.b - cc.g;
		} else if (c.g == cmax) {
			h = 2.0 + cc.r - cc.b;
		} else {
			h = 4.0 + cc.g - cc.r;
		}
		h /= 6.0;
		if (h < 0.0) {
			h += 1.0;
		}
	}
	return vec3(h, s, v);
}

vec3 hsv_to_rgb(vec3 hsv) {
	float nr = clamp(abs(hsv.x * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	float ng = clamp(2.0 - abs(hsv.x * 6.0 - 2.0), 0.0, 1.0);
	float nb = clamp(2.0 - abs(hsv.x * 6.0 - 4.0), 0.0, 1.0);
	return ((vec3(nr, ng, nb) - 1.0) * hsv.y + 1.0) * hsv.z;
}

// Blender "Hue/Saturation/Value" node (Fac = 1).
vec3 hue_sat_value(vec3 c, float hue, float sat, float val) {
	vec3 hsv = rgb_to_hsv(c);
	hsv.x = fract(hsv.x + hue + 0.5);
	hsv.y = clamp(hsv.y * sat, 0.0, 1.0);
	hsv.z *= val;
	return max(hsv_to_rgb(hsv), vec3(0.0));
}