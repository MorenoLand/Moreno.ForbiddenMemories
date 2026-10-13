shader_type canvas_item;
// The game's picture shader (scripts/system/screen_fit.gd). The player picks one sampling with F5 (Pixel, Sharp, Smooth):
//   0 pixel:  nearest texel, hard edges (the texel centre is sampled, the screen pixel takes its colour)
//   1 sharp:  sharp bilinear, nearest texels with about one screen pixel of blend on their edges (the default)
//   2 smooth: plain bilinear
// crt (F6) darkens the texel seams a little (faint scanlines, off by default). deblock (the opening movie only) blends the 8-pixel
// block seams of the movie's MDEC frames with their neighbour across the seam; 0 leaves the picture as it is.
uniform int filter_mode : hint_range(0, 2) = 1;
uniform float crt = 0.0;
uniform float deblock = 0.0;
// dither (0 or 1; set only on a shaded picture, the duel's 3D board, by screen_fit.gd when the F9 dithering option is on): the
// PS1 4x4 dither of the GPU (ps1_dither) at each colour step. 0 leaves the picture as it is (flat sprites never dither).
uniform float dither = 0.0;

// The PS1 GPU's 4x4 dither matrix (row-major, indexed by the screen pixel's x and y modulo 4). The GPU adds it to each 8-bit channel,
// then keeps the top five bits of the result.
float ps1_offset(int x, int y) {
	const float M[16] = float[16](-4.0, 0.0, -3.0, 1.0, 2.0, -2.0, 3.0, -1.0, -3.0, 1.0, -4.0, 0.0, 3.0, -1.0, 2.0, -2.0);
	return M[y * 4 + x];
}

// rgb quantised the PS1 way at the grid pixel grid (the picture's own pixel, not the window's).
vec3 ps1_dither(vec3 rgb, vec2 grid) {
	int x = int(mod(floor(grid.x), 4.0));
	int y = int(mod(floor(grid.y), 4.0));
	vec3 c8 = clamp(floor(rgb * 255.0 + 0.5) + ps1_offset(x, y), 0.0, 255.0);
	return floor(c8 / 8.0) * 8.0 / 255.0;
}

varying vec4 tint;

void vertex() {
	tint = COLOR;   // the vertex colour carries the modulate; in fragment() COLOR already holds the texel
}

void fragment() {
	vec2 size = vec2(textureSize(TEXTURE, 0));
	vec2 pos = UV * size;
	vec4 c;
	if (filter_mode == 2) {
		c = texture(TEXTURE, UV);
	} else if (filter_mode == 0) {
		c = texture(TEXTURE, (floor(pos) + 0.5) / size);
	} else {
		vec2 p = pos - 0.5;
		vec2 base = floor(p);
		vec2 f = fract(p);
		vec2 ratio = vec2(1.0) / max(fwidth(pos), vec2(0.0001));
		f = clamp((f - 0.5) * max(ratio, vec2(1.0)) + 0.5, 0.0, 1.0);
		c = texture(TEXTURE, (base + 0.5 + f) / size);
	}
	if (deblock > 0.0) {
		// the seam between texel columns 7|8 (and rows): the texel on the seam side takes half of its neighbour across it
		vec2 texel = floor(UV * size);
		float left = mod(texel.x, 8.0) == 0.0 ? -1.0 : (mod(texel.x, 8.0) == 7.0 ? 1.0 : 0.0);
		float up = mod(texel.y, 8.0) == 0.0 ? -1.0 : (mod(texel.y, 8.0) == 7.0 ? 1.0 : 0.0);
		if (left != 0.0) {
			vec4 n = texture(TEXTURE, (vec2(texel.x + left, texel.y) + 0.5) / size);
			c = mix(c, (c + n) * 0.5, deblock);
		}
		if (up != 0.0) {
			vec4 n = texture(TEXTURE, (vec2(texel.x, texel.y + up) + 0.5) / size);
			c = mix(c, (c + n) * 0.5, deblock);
		}
	}
	if (crt > 0.0) {
		// one dark seam per texel row: the fragment's place inside its texel (not the snapped one), so the pixel mode shows it too
		float within = fract(UV.y * size.y);
		c.rgb *= 1.0 - crt * 0.22 * (0.5 + 0.5 * cos(6.2831853 * within));
	}
	COLOR = c * tint;
	if (dither > 0.0) {
		// the pixel grid of the 320-wide picture: a picture drawn k times larger (the 3D board's viewport) has k texels a PS1 pixel
		float k = max(1.0, floor(size.x / 320.0));
		COLOR.rgb = mix(COLOR.rgb, ps1_dither(COLOR.rgb, pos / k), dither);
	}
}
