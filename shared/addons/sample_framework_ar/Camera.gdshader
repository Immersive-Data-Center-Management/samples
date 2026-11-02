shader_type sky;
uniform sampler2D camera_texture : source_color, repeat_disable;
uniform vec2 viewport_size = vec2(512, 512);
void sky() {
	if (AT_CUBEMAP_PASS) { COLOR = vec3(0.0); }
	else {
		vec2 uv = FRAGCOORD.xy / viewport_size;
		COLOR.rgb = texture(camera_texture, uv).rgb;
	}
}