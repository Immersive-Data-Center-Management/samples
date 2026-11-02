#include "background_renderer.h"
#include "include/arcore_c_api.h"
#include "utils.h"
#include <godot_cpp/classes/camera_server.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

using namespace arcore_plugin;
using namespace godot;

// ---------------------------------------------------------------------------
// GLSL shader sources for OES → RGBA blit
// The vertex shader generates a fullscreen triangle using gl_VertexID (no VBO needed,
// but a bound VAO is still required in GLES3).
// The fragment shader explicitly enables GL_OES_EGL_image_external_essl3 — bypassing
// Godot's external_texture_supported=false code path — and applies the ARCore UV
// transform so the output RGBA texture is already in correct screen orientation.
// ---------------------------------------------------------------------------
static const char *BLIT_VERT_SRC =
        "#version 300 es\n"
        "void main() {\n"
        "    // Indices 0,1,2 → (-1,-1), (3,-1), (-1,3) — covers the full NDC square.\n"
        "    float x = (gl_VertexID == 1) ? 3.0 : -1.0;\n"
        "    float y = (gl_VertexID == 2) ? 3.0 : -1.0;\n"
        "    gl_Position = vec4(x, y, 0.0, 1.0);\n"
        "}\n";

static const char *BLIT_FRAG_SRC =
        "#version 300 es\n"
        "#extension GL_OES_EGL_image_external_essl3 : require\n"
        "precision mediump float;\n"
        "uniform samplerExternalOES u_oes;\n"
        "uniform vec2 u_size;\n"
        "uniform vec2 u_origin;\n"
        "uniform mat2 u_basis;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "    // gl_FragCoord: (0,0)=bottom-left in FBO space.\n"
        "    // Convert to screen UV where (0,0)=top-left to match the ARCore feed_transform.\n"
        "    vec2 screen_uv = gl_FragCoord.xy / u_size;\n"
        "    screen_uv.y = 1.0 - screen_uv.y;\n"
        "    vec2 oes_uv = u_origin + u_basis * screen_uv;\n"
        "    frag_color = texture(u_oes, oes_uv);\n"
        "}\n";

// ---------------------------------------------------------------------------

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[512];
        glGetShaderInfoLog(s, sizeof(buf), nullptr, buf);
        ALOGE("Godot ARCore: blit shader compile error: %s", buf);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

// ---------------------------------------------------------------------------

BackgroundRenderer::BackgroundRenderer() {
}

BackgroundRenderer::~BackgroundRenderer() {
}

void BackgroundRenderer::initialize(int p_width, int p_height) {
    // create our camera feed
    if (m_feed.is_null()) {
        ALOGV("Godot ARCore: Creating camera feed...");

        m_feed.instantiate();
        m_feed->set_name("ARCore");
        m_feed->set_active(true);

        CameraServer *cs = CameraServer::get_singleton();
        if (cs != nullptr) {
            cs->add_feed(m_feed);
            ALOGV("Godot ARCore: Feed %d added", m_feed->get_id());
        }
    }

    if (m_feed.is_valid()) {
        m_feed->set_active(true);

        // Create the OES texture that ARCore will write camera frames into.
        // We do this manually instead of calling set_external() so that Godot's
        // external_texture_supported=false code path never touches our OES texture.
        if (m_oes_tex == 0) {
            glGenTextures(1, &m_oes_tex);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, m_oes_tex);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
            m_camera_texture_id = static_cast<int64_t>(m_oes_tex);
            ALOGV("Godot ARCore: Created OES texture id=%u", m_oes_tex);
        }

        // Initialise the blit resources (deferred to draw_background on first call
        // so that the real screen dimensions are known).
        ALOGV("Godot ARCore: BackgroundRenderer initialised (%dx%d)", p_width, p_height);
    }
}

void BackgroundRenderer::_init_blit_gl(int width, int height) {
    m_blit_width  = width;
    m_blit_height = height;

    // --- Compile shader program ---
    GLuint vert = compile_shader(GL_VERTEX_SHADER,   BLIT_VERT_SRC);
    GLuint frag = compile_shader(GL_FRAGMENT_SHADER, BLIT_FRAG_SRC);
    if (!vert || !frag) {
        ALOGE("Godot ARCore: OES blit shader compilation failed");
        if (vert) glDeleteShader(vert);
        if (frag) glDeleteShader(frag);
        return;
    }
    m_blit_program = glCreateProgram();
    glAttachShader(m_blit_program, vert);
    glAttachShader(m_blit_program, frag);
    glLinkProgram(m_blit_program);
    glDeleteShader(vert);
    glDeleteShader(frag);
    {
        GLint ok = 0;
        glGetProgramiv(m_blit_program, GL_LINK_STATUS, &ok);
        if (!ok) {
            char buf[512];
            glGetProgramInfoLog(m_blit_program, sizeof(buf), nullptr, buf);
            ALOGE("Godot ARCore: OES blit shader link error: %s", buf);
            glDeleteProgram(m_blit_program);
            m_blit_program = 0;
            return;
        }
    }
    m_u_oes_loc    = glGetUniformLocation(m_blit_program, "u_oes");
    m_u_size_loc   = glGetUniformLocation(m_blit_program, "u_size");
    m_u_origin_loc = glGetUniformLocation(m_blit_program, "u_origin");
    m_u_basis_loc  = glGetUniformLocation(m_blit_program, "u_basis");

    // --- Create RGBA output texture ---
    glGenTextures(1, &m_rgb_tex_gl);
    glBindTexture(GL_TEXTURE_2D, m_rgb_tex_gl);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);

    // --- Create FBO ---
    glGenFramebuffers(1, &m_rgb_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, m_rgb_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, m_rgb_tex_gl, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        ALOGE("Godot ARCore: OES blit FBO incomplete, status=0x%x", status);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        _cleanup_blit_gl();
        return;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    // --- Create VAO (required in GLES3 even with no vertex data) ---
    glGenVertexArrays(1, &m_blit_vao);

    // --- Wrap the RGBA GL texture in a Godot Texture2D via a native handle RID ---
    RenderingServer *rs = RenderingServer::get_singleton();
    if (rs) {
        m_rgba_rid = rs->texture_create_from_native_handle(
                RenderingServer::TEXTURE_TYPE_2D,
                Image::FORMAT_RGBA8,
                static_cast<int64_t>(m_rgb_tex_gl),
                width, height,
                /*depth=*/1, /*layers=*/1,
                RenderingServer::TEXTURE_LAYERED_2D_ARRAY);

        m_rgba_texture_obj.instantiate();
        m_rgba_texture_obj->setup(m_rgba_rid, width, height);
        ALOGV("Godot ARCore: ARCoreRGBATexture created (GL id=%u, %dx%d)", m_rgb_tex_gl, width, height);
    }

    m_blit_ready = true;
    ALOGV("Godot ARCore: OES→RGBA blit GL resources ready (%dx%d)", width, height);
}

void BackgroundRenderer::_cleanup_blit_gl() {
    if (m_rgb_fbo)      { glDeleteFramebuffers(1,  &m_rgb_fbo);      m_rgb_fbo      = 0; }
    if (m_rgb_tex_gl)   { glDeleteTextures(1,      &m_rgb_tex_gl);   m_rgb_tex_gl   = 0; }
    if (m_blit_program) { glDeleteProgram(m_blit_program);           m_blit_program = 0; }
    if (m_blit_vao)     { glDeleteVertexArrays(1,  &m_blit_vao);     m_blit_vao     = 0; }

    m_rgba_texture_obj.unref();
    if (m_rgba_rid.is_valid()) {
        RenderingServer *rs = RenderingServer::get_singleton();
        if (rs) { rs->free_rid(m_rgba_rid); }
        m_rgba_rid = RID();
    }
    m_blit_ready = false;
}

void BackgroundRenderer::_do_blit() {
    // Save essential GL state so Godot's renderer sees a clean slate afterwards.
    GLint prev_fbo = 0;     glGetIntegerv(GL_FRAMEBUFFER_BINDING,  &prev_fbo);
    GLint prev_prog = 0;    glGetIntegerv(GL_CURRENT_PROGRAM,      &prev_prog);
    GLint prev_vao = 0;     glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prev_vao);
    GLint prev_active = 0;  glGetIntegerv(GL_ACTIVE_TEXTURE,       &prev_active);
    GLint prev_vp[4] = {};  glGetIntegerv(GL_VIEWPORT,              prev_vp);
    GLint prev_tex0 = 0;    glGetIntegerv(GL_TEXTURE_BINDING_2D,   &prev_tex0);
    GLboolean prev_depth = glIsEnabled(GL_DEPTH_TEST);
    GLboolean prev_blend = glIsEnabled(GL_BLEND);

    // Blit OES → RGBA FBO.
    glBindFramebuffer(GL_FRAMEBUFFER, m_rgb_fbo);
    glViewport(0, 0, m_blit_width, m_blit_height);
    glUseProgram(m_blit_program);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, m_oes_tex);
    glUniform1i(m_u_oes_loc, 0);
    glUniform2f(m_u_size_loc, static_cast<float>(m_blit_width), static_cast<float>(m_blit_height));

    // ARCore feed_transform: columns[2]=origin, columns[0]=basis_x, columns[1]=basis_y.
    const godot::Transform2D &tx = m_display_transform;
    glUniform2f(m_u_origin_loc, tx.columns[2][0], tx.columns[2][1]);
    // mat2 in GLSL is column-major: [col0.x, col0.y, col1.x, col1.y]
    float basis[4] = { tx.columns[0][0], tx.columns[0][1], tx.columns[1][0], tx.columns[1][1] };
    glUniformMatrix2fv(m_u_basis_loc, 1, GL_FALSE, basis);

    glBindVertexArray(m_blit_vao);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    // Restore all modified state.
    if (prev_depth) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
    if (prev_blend) glEnable(GL_BLEND);      else glDisable(GL_BLEND);
    glBindVertexArray(prev_vao);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    glBindTexture(GL_TEXTURE_2D, prev_tex0);
    glActiveTexture(prev_active);
    glViewport(prev_vp[0], prev_vp[1], prev_vp[2], prev_vp[3]);
    glUseProgram(prev_prog);
    glBindFramebuffer(GL_FRAMEBUFFER, prev_fbo);
}

void BackgroundRenderer::draw_background(int p_screen_w, int p_screen_h) {
    if (m_oes_tex == 0) { return; }

    // Initialise or re-initialise on dimension change.
    if (!m_blit_ready) {
        _init_blit_gl(p_screen_w, p_screen_h);
        if (!m_blit_ready) { return; }
    } else if (m_blit_width != p_screen_w || m_blit_height != p_screen_h) {
        // Resize the RGBA texture in-place so the GL texture ID, RID, and the
        // ARCoreRGBATexture held by GDScript all remain valid — no rebind needed.
        ALOGV("Godot ARCore: Resizing blit texture %dx%d -> %dx%d",
              m_blit_width, m_blit_height, p_screen_w, p_screen_h);
        m_blit_width  = p_screen_w;
        m_blit_height = p_screen_h;
        glBindTexture(GL_TEXTURE_2D, m_rgb_tex_gl);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, p_screen_w, p_screen_h,
                     0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindTexture(GL_TEXTURE_2D, 0);
        if (m_rgba_texture_obj.is_valid()) {
            m_rgba_texture_obj->setup(m_rgba_rid, p_screen_w, p_screen_h);
        }
    }

    _do_blit();
}

void BackgroundRenderer::uninitialize() {
    _cleanup_blit_gl();

    if (m_oes_tex != 0) {
        glDeleteTextures(1, &m_oes_tex);
        m_oes_tex = 0;
        m_camera_texture_id = 0;
    }

    if (m_feed.is_valid()) {
        m_feed->set_active(false);

        CameraServer *cs = CameraServer::get_singleton();
        if (cs != nullptr) {
            cs->remove_feed(m_feed);
        }
        m_feed.unref();
    }
}

static void computeDepth(ArSession &p_ar_session, const ArFrame &p_ar_frame, godot::Ref<godot::CameraFeed> p_feed) {
    int32_t is_depth_supported = 0;
    ArSession_isDepthModeSupported(&p_ar_session, AR_DEPTH_MODE_AUTOMATIC,
            &is_depth_supported);

    if (is_depth_supported) {
        ArImage *depthImage = nullptr;
        if (ArFrame_acquireDepthImage16Bits(&p_ar_session, &p_ar_frame, &depthImage) != AR_SUCCESS) {
            ALOGE("Godot ARCore: Error: Failed to acquire depth image");
            return;
        }

        int32_t width, height;
        ArImage_getWidth(&p_ar_session, depthImage, &width);
        ArImage_getHeight(&p_ar_session, depthImage, &height);

        const uint8_t *depthData = nullptr;
        int32_t depthDataSize = 0;
        ArImage_getPlaneData(&p_ar_session, depthImage, 0, reinterpret_cast<const uint8_t **>(&depthData), &depthDataSize);

        PackedByteArray array;
        array.resize(width * height * 2); // 2 bytes per pixel (16-bit)

        for (int i = 0; i < width * height * 2; ++i) {
            array[i] = *(depthData + i * sizeof(uint8_t));
        }

        ArImage_release(depthImage);

        // p_feed->set_external_depthmap(array, width, height);
    } else {
        ALOGW("Godot ARCore: Warning: Depth computation requested but not supported");
    }
}

void BackgroundRenderer::process(ArSession &p_ar_session, const ArFrame &p_ar_frame, bool p_enable_depth_estimation) {
    // Tell ARCore which OES texture to write the camera frame into.
    ArSession_setCameraTextureName(&p_ar_session, static_cast<uint32_t>(m_camera_texture_id));

    // Positions of the quad vertices in clip space (X, Y).
    static const float kVertices[] = {
            -1.0f, -1.0f, +1.0f, -1.0f, -1.0f, +1.0f, +1.0f, +1.0f,
    };

    int32_t geometry_changed = 0;
    ArFrame_getDisplayGeometryChanged(&p_ar_session, &p_ar_frame, &geometry_changed);
    if (geometry_changed != 0) {
        ALOGV("MCT Godot ARCore: changing_display_transform");
        float transformed_uvs[4 * 2];
        ArFrame_transformCoordinates2d(&p_ar_session, &p_ar_frame,
                AR_COORDINATES_2D_OPENGL_NORMALIZED_DEVICE_COORDINATES, 4, kVertices,
                AR_COORDINATES_2D_TEXTURE_NORMALIZED, transformed_uvs);

        ALOGV("Tranformed UVs pre-magic:\n[%f, %f, %f, %f]\n[%f, %f, %f, %f]\n",
                transformed_uvs[0], transformed_uvs[2], transformed_uvs[4], transformed_uvs[6],
                transformed_uvs[1], transformed_uvs[3], transformed_uvs[5], transformed_uvs[7]);

        // Build the Transform2D that maps screen UV (0,0=top-left) → OES texture UV.
        godot::Transform2D display_transform;
        display_transform.columns[0] = Vector2(transformed_uvs[2] - transformed_uvs[0], transformed_uvs[3] - transformed_uvs[1]);
        display_transform.columns[1] = Vector2(transformed_uvs[4] - transformed_uvs[0], transformed_uvs[5] - transformed_uvs[1]);
        display_transform.columns[2] = Vector2(transformed_uvs[0], transformed_uvs[1]);

        ALOGV("New display transform TRANSPOSE:\n[%f, %f, %f]\n[%f, %f, %f]\n",
                display_transform.columns[0][0], display_transform.columns[1][0], display_transform.columns[2][0],
                display_transform.columns[0][1], display_transform.columns[1][1], display_transform.columns[2][1]);

        m_display_transform = display_transform;
        m_feed->set_transform(display_transform);
    }

    if (p_enable_depth_estimation) {
        computeDepth(p_ar_session, p_ar_frame, m_feed);
    }
}
