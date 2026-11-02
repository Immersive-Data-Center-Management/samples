#pragma once

#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

/// A Texture2D that wraps a RenderingServer RID created from a native (GL) texture handle.
/// _get_rid() is overridden so the sky shader samples our RGBA GL texture directly —
/// no CPU readback required.
class ARCoreRGBATexture : public Texture2D {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
    GDCLASS(ARCoreRGBATexture, Texture2D);
#pragma clang diagnostic pop

    RID  m_rid;
    int  m_width  = 0;
    int  m_height = 0;

protected:
    static void _bind_methods() {}

public:
    ARCoreRGBATexture()  = default;
    ~ARCoreRGBATexture() = default;

    void setup(RID p_rid, int p_width, int p_height) {
        m_rid    = p_rid;
        m_width  = p_width;
        m_height = p_height;
    }

    // Called by Godot's rendering system to get the texture RID for binding.
    virtual RID _get_rid() const override { return m_rid; }

    virtual int32_t _get_width()  const override { return m_width;  }
    virtual int32_t _get_height() const override { return m_height; }
};

} // namespace godot
