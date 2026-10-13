shader_type canvas_item;
// A speaker bust layer. Each texel's class is its alpha (tools/extract.py bust_frame): 255 an opaque colour, 128 a colour
// whose palette entry has the semi-transparency bit (the average of what is behind and the colour), 64 a texel of index not 0
// whose colour is 0, 32 a texel of index 0 inside a cell (its RGB is the palette's second-row entry 0), 0 nothing.
// mode 0: the layer as drawn; the class 128 texels average with what is behind.
// mode 1: the additive copy: the second palette row, every texel semi-transparent, so what is behind plus the colour.
// mode 2: the subtractive copy: the white palette row, every texel that is not index 0, so what is behind less the tint.
// tint is the colour multiplier of the layer (0x80 is neutral, so 1.0). The texels are read exactly (no filtering).
uniform int mode = 0;
uniform float tint = 1.0;
uniform sampler2D backdrop : hint_screen_texture, filter_nearest, repeat_disable;

void fragment() {
	ivec2 size = textureSize(TEXTURE, 0);
	ivec2 texel = clamp(ivec2(floor(UV * vec2(size))), ivec2(0), size - ivec2(1));
	vec4 t = texelFetch(TEXTURE, texel, 0);
	int cls = int(floor(t.a * 255.0 + 0.5));
	vec3 front = t.rgb * tint;
	vec3 behind = textureLod(backdrop, SCREEN_UV, 0.0).rgb;
	vec3 result = vec3(0.0);
	bool drawn = false;
	if (mode == 0) {
		if (cls == 255) {
			result = front;
			drawn = true;
		} else if (cls == 128) {
			result = (behind + front) * 0.5;
			drawn = true;
		}
	} else if (mode == 1) {
		if (cls == 255 || cls == 128 || cls == 32) {
			result = clamp(behind + front, 0.0, 1.0);
			drawn = true;
		}
	} else {
		if (cls == 255 || cls == 128 || cls == 64) {
			result = clamp(behind - vec3(tint), 0.0, 1.0);
			drawn = true;
		}
	}
	COLOR = drawn ? vec4(result, 1.0) : vec4(0.0);
}
