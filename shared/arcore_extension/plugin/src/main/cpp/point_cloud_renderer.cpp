#include "point_cloud_renderer.h"
#include "utils.h"

using namespace arcore_plugin;
using namespace godot;

PointCloudRenderer::PointCloudRenderer() {
}

PointCloudRenderer::~PointCloudRenderer() {
}

void PointCloudRenderer::process(ArSession &p_ar_session, ArFrame &p_ar_frame) {
	ArPointCloud *point_cloud = nullptr;
	if (ArFrame_acquirePointCloud(&p_ar_session, &p_ar_frame, &point_cloud) != AR_SUCCESS) {
		return;
	}

	int32_t num_points = 0;
	ArPointCloud_getNumberOfPoints(&p_ar_session, point_cloud, &num_points);

	if (num_points <= 0) {
		ArPointCloud_release(point_cloud);
		m_points.clear();
		m_confidences.clear();
		return;
	}

	// Data is interleaved: x, y, z, confidence per point (4 floats each)
	const float *point_data = nullptr;
	ArPointCloud_getData(&p_ar_session, point_cloud, &point_data);

	m_points.clear();
	m_confidences.clear();

	for (int32_t i = 0; i < num_points; i++) {
		float confidence = point_data[i * 4 + 3];
		if (confidence < m_confidence_threshold) continue;

		float x = point_data[i * 4 + 0];
		float y = point_data[i * 4 + 1];
		float z = point_data[i * 4 + 2];

		// ARCore uses right-handed Y-up, Godot uses right-handed Y-up
		// but ARCore's Z is towards the user, Godot's Z is also towards the user
		// Negate Z to convert from ARCore to Godot coordinate system
		m_points.push_back(Vector3(x, y, -z));
		m_confidences.push_back(confidence);
	}

	ArPointCloud_release(point_cloud);
}

void PointCloudRenderer::clear() {
	m_points.clear();
	m_confidences.clear();
}
