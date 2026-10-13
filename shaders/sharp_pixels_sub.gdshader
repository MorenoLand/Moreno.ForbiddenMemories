shader_type canvas_item;
render_mode blend_sub;
// The same picture sampling as sharp_pixels.gdshader (filter_mode, crt), subtracted from what is behind (the name plates the card view takes from the frame).
uniform int filter_mode : hint_range(0, 2) = 1;
uniform float crt = 0.0;

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
	if (crt > 0.0) {
		float within = fract(UV.y * size.y);
		c.rgb *= 1.0 - crt * 0.22 * (0.5 + 0.5 * cos(6.2831853 * within));
	}
	COLOR = c * tint;
}
