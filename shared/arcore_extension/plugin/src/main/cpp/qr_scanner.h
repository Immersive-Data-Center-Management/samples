#ifndef ARCORE_PLUGIN_QR_SCANNER_H
#define ARCORE_PLUGIN_QR_SCANNER_H

#include "arcore_features.h"

#if ARCORE_FEATURE_QR_SCANNER

#include "include/arcore_c_api.h"
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/string.hpp>
#include <jni.h>

namespace arcore_plugin {

struct QRDetection {
	godot::String data;
	godot::String format;
	int bounds_left;
	int bounds_top;
	int bounds_right;
	int bounds_bottom;
	int frame_detected;
	godot::Ref<godot::Image> cropped_image;
};

class QRScanner {
public:
	QRScanner();
	~QRScanner();

	void initialize(JNIEnv *p_env, jobject p_activity);
	void uninitialize();

	void start();
	void stop();
	bool is_scanning() const { return m_scanning; }

	/// Called each frame from ARCoreInterface::_process().
	/// Returns true if new QR codes were detected this frame.
	bool process(ArSession &p_ar_session, ArFrame &p_ar_frame);

	/// Get the cropped camera image of a detected QR code.
	/// Returns null if the code is not in the active detections cache.
	godot::Ref<godot::Image> get_detected_image(const godot::String &p_qr_data);

	/// Get the last detected screen-space bounds of a QR code in camera-image pixels.
	/// Returns an empty rect if the code is not in the active detections cache.
	godot::Rect2 get_detected_bounds(const godot::String &p_qr_data) const;

	/// Enable or disable capturing cropped camera images for detections.
	/// Disabled by default to avoid per-detection image allocations.
	void set_capture_detected_images(bool p_enabled);
	bool get_capture_detected_images() const { return m_capture_detected_images; }

	/// Set how many frames to skip between scans (throttling).
	void set_scan_interval(int p_frames);
	int get_scan_interval() const { return m_scan_interval; }

	/// Set timeout in seconds before emitting qr_code_lost.
	void set_lost_timeout(float p_seconds);
	float get_lost_timeout() const { return m_lost_timeout_seconds; }

	/// Returns newly found codes since last call (consumed on read).
	const godot::Vector<QRDetection> &get_new_detections() const { return m_new_detections; }

	/// Returns codes lost since last call (consumed on read).
	const godot::Vector<godot::String> &get_lost_codes() const { return m_lost_codes; }

	/// Clear the consumed new/lost buffers (called after signals are emitted).
	void clear_frame_events();

private:
	bool m_scanning = false;
	bool m_initialized = false;
	int m_scan_interval = 5; // scan every N frames
	int m_frame_counter = 0;
	int m_current_frame = 0;
	float m_lost_timeout_seconds = 2.0f;
	bool m_capture_detected_images = false;

	// JNI references to the Java bridge
	jclass m_bridge_class = nullptr;
	jobject m_bridge_instance = nullptr;
	jmethodID m_scan_method = nullptr;

	// Active detections: qr_data -> detection info
	godot::HashMap<godot::String, QRDetection> m_active_detections;

	// Frame event buffers
	godot::Vector<QRDetection> m_new_detections;
	godot::Vector<godot::String> m_lost_codes;

	void _scan_frame(ArSession &p_ar_session, ArFrame &p_ar_frame);
	godot::Ref<godot::Image> _crop_image_region(const uint8_t *p_yuv_data, int p_width, int p_height,
			int p_left, int p_top, int p_right, int p_bottom);
};

} // namespace arcore_plugin

#else // !ARCORE_FEATURE_QR_SCANNER

// Empty stub when QR Scanner is disabled
namespace arcore_plugin {

struct QRDetection {
	godot::String data;
	godot::String format;
};

class QRScanner {
public:
	void initialize(JNIEnv *, jobject) {}
	void uninitialize() {}
	void start() {}
	void stop() {}
	bool is_scanning() const { return false; }
	bool process(ArSession &, ArFrame &) { return false; }
	godot::Ref<godot::Image> get_detected_image(const godot::String &) { return godot::Ref<godot::Image>(); }
	godot::Rect2 get_detected_bounds(const godot::String &) const { return godot::Rect2(); }
	void set_capture_detected_images(bool) {}
	bool get_capture_detected_images() const { return false; }
	void set_scan_interval(int) {}
	int get_scan_interval() const { return 5; }
	void set_lost_timeout(float) {}
	float get_lost_timeout() const { return 2.0f; }
	const godot::Vector<QRDetection> &get_new_detections() const { return m_empty_detections; }
	const godot::Vector<godot::String> &get_lost_codes() const { return m_empty_lost; }
	void clear_frame_events() {}

private:
	godot::Vector<QRDetection> m_empty_detections;
	godot::Vector<godot::String> m_empty_lost;
};

} // namespace arcore_plugin

#endif // ARCORE_FEATURE_QR_SCANNER

#endif // ARCORE_PLUGIN_QR_SCANNER_H
