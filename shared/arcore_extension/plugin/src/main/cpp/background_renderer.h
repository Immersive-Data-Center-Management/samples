#ifndef ARCORE_PLUGING_BACKGROUND_RENDERER
#define ARCORE_PLUGING_BACKGROUND_RENDERER

#include "arcore_rgba_texture.h"
#include "godot_cpp/classes/camera_feed.hpp"
#include "include/arcore_c_api.h"

#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>  // GL_TEXTURE_EXTERNAL_OES

namespace arcore_plugin {
class BackgroundRenderer {
public:
	BackgroundRenderer();
	~BackgroundRenderer();

	void initialize(int p_width, int p_height);

	void uninitialize();

	void process(ArSession &p_ar_session, const ArFrame &p_ar_frame, bool p_enable_depth_estimation);

	/// Blit the OES camera texture → RGBA FBO texture (GPU only, no readback).
	/// Must be called once per frame after process(), passing current screen dimensions.
	void draw_background(int p_screen_w, int p_screen_h);

	int64_t getTextureId() const { return m_camera_texture_id; }

	godot::Ref<godot::CameraFeed> getFeed() const { return m_feed; }

	/// Returns the Godot Texture2D wrapping the RGBA output texture (ready after first draw_background).
	godot::Ref<godot::ARCoreRGBATexture> getRGBATexture() const { return m_rgba_texture_obj; }

private:
	godot::Ref<godot::CameraFeed> m_feed;

	// OES texture created manually (ARCore writes camera frames here).
	GLuint m_oes_tex = 0;
	int64_t m_camera_texture_id = 0;

	// Raw GL blit resources: OES → RGBA FBO.
	GLuint m_rgb_fbo     = 0;
	GLuint m_rgb_tex_gl  = 0;
	GLuint m_blit_program = 0;
	GLuint m_blit_vao    = 0;
	int    m_blit_width  = 0;
	int    m_blit_height = 0;
	bool   m_blit_ready  = false;

	// Display transform from the last process() call (screen UV → OES UV).
	godot::Transform2D m_display_transform;

	// Cached uniform locations.
	GLint m_u_oes_loc    = -1;
	GLint m_u_size_loc   = -1;
	GLint m_u_origin_loc = -1;
	GLint m_u_basis_loc  = -1;

	// Godot texture wrapper over the RGBA GL texture.
	godot::Ref<godot::ARCoreRGBATexture> m_rgba_texture_obj;
	godot::RID m_rgba_rid;

	void _init_blit_gl(int width, int height);
	void _cleanup_blit_gl();
	void _do_blit();
};
} // namespace arcore_plugin
#endif // ARCORE_PLUGING_BACKGROUND_RENDERER
