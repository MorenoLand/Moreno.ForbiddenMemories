shader_type canvas_item;
render_mode blend_sub;
// A shaded Gouraud quad subtracted from what is behind it (the main menu's wall shade: draw mode abr 2). dither (0 or 1, set by
// screen_fit.gd from the F9 dithering option) applies the PS1 4x4 dither to the interpolated colour at the polygon's own pixels:
// the local coordinates are the game's pixels (the world is 320 x 240), so the pattern is the GPU's. 0 subtracts the colour as it is.
uniform float dither = 0.0;

varying vec2 local;

const float M[16] = float[16](-4.0, 0.0, -3.0, 1.0, 2.0, -2.0, 3.0, -1.0, -3.0, 1.0, -4.0, 0.0, 3.0, -1.0, 2.0, -2.0);

void vertex() {
	local = VERTEX;
}

void fragment() {
	vec4 c = COLOR;
	if (dither > 0.0) {
		int x = int(mod(floor(local.x), 4.0));
		int y = int(mod(floor(local.y), 4.0));
		vec3 c8 = clamp(floor(c.rgb * 255.0 + 0.5) + M[y * 4 + x], 0.0, 255.0);
		c.rgb = mix(c.rgb, floor(c8 / 8.0) * 8.0 / 255.0, dither);
	}
	COLOR = c;
}
