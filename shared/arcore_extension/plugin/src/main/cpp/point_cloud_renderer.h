#ifndef ARCORE_PLUGING_POINT_CLOUD_RENDERER
#define ARCORE_PLUGING_POINT_CLOUD_RENDERER

#include "include/arcore_c_api.h"
#include <godot_cpp/classes/immediate_mesh.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>

namespace arcore_plugin {
class PointCloudRenderer {
public:
	PointCloudRenderer();
	~PointCloudRenderer();

	void clear();
	void process(ArSession &p_ar_session, ArFrame &p_ar_frame);

	/// Get the current point cloud data as PackedVector3Array.
	godot::PackedVector3Array get_points() const { return m_points; }

	/// Get the confidence values (0-1) per point.
	godot::PackedFloat32Array get_confidences() const { return m_confidences; }

	/// Set minimum confidence threshold for points (0.0 - 1.0).
	void set_confidence_threshold(float p_threshold) { m_confidence_threshold = p_threshold; }
	float get_confidence_threshold() const { return m_confidence_threshold; }

private:
	godot::PackedVector3Array m_points;
	godot::PackedFloat32Array m_confidences;
	float m_confidence_threshold = 0.3f;
};
} // namespace arcore_plugin

#endif // ARCORE_PLUGING_POINT_CLOUD_RENDERER
