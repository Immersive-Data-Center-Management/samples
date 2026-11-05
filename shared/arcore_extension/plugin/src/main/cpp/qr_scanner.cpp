#include "qr_scanner.h"

#if ARCORE_FEATURE_QR_SCANNER

#include "arcore_wrapper.h"
#include "utils.h"
#include <godot_cpp/classes/image.hpp>

using namespace arcore_plugin;
using namespace godot;

QRScanner::QRScanner() {
}

QRScanner::~QRScanner() {
	uninitialize();
}

void QRScanner::initialize(JNIEnv *p_env, jobject p_activity) {
	if (m_initialized) {
		ALOGV("Godot ARCore QR: initialize() called but already initialized");
		return;
	}

	ALOGV("Godot ARCore QR: Starting QRScanner initialization with env=%p, activity=%p", p_env, p_activity);

	// Find the Java bridge class
	jclass local_class = p_env->FindClass("org/godotengine/plugin/android/arcore/QRScannerBridge");
	if (!local_class) {
		ALOGE("Godot ARCore QR: Cannot find QRScannerBridge class");
		if (p_env->ExceptionCheck()) {
			ALOGE("Godot ARCore QR: JNI Exception during FindClass");
			p_env->ExceptionDescribe();
			p_env->ExceptionClear();
		}
		return;
	}
	m_bridge_class = (jclass)p_env->NewGlobalRef(local_class);
	p_env->DeleteLocalRef(local_class);
	ALOGV("Godot ARCore QR: Found QRScannerBridge class: %p", m_bridge_class);

	// Get the constructor and create an instance
	jmethodID constructor = p_env->GetMethodID(m_bridge_class, "<init>", "(Landroid/content/Context;)V");
	if (!constructor) {
		ALOGE("Godot ARCore QR: Cannot find QRScannerBridge constructor");
		if (p_env->ExceptionCheck()) {
			ALOGE("Godot ARCore QR: JNI Exception during GetMethodID(constructor)");
			p_env->ExceptionDescribe();
			p_env->ExceptionClear();
		}
		return;
	}
	ALOGV("Godot ARCore QR: Found constructor: %p", constructor);

	jobject local_instance = p_env->NewObject(m_bridge_class, constructor, p_activity);
	if (!local_instance) {
		ALOGE("Godot ARCore QR: Failed to create QRScannerBridge instance");
		if (p_env->ExceptionCheck()) {
			ALOGE("Godot ARCore QR: JNI Exception during NewObject");
			p_env->ExceptionDescribe();
			p_env->ExceptionClear();
		}
		return;
	}
	m_bridge_instance = p_env->NewGlobalRef(local_instance);
	p_env->DeleteLocalRef(local_instance);
	ALOGV("Godot ARCore QR: Created bridge instance: %p", m_bridge_instance);

	// Cache the async scan methods
	m_submit_method = p_env->GetMethodID(m_bridge_class, "submitImage", "([BIII)Z");
	m_poll_method = p_env->GetMethodID(m_bridge_class, "pollResult", "()[B");
	if (!m_submit_method || !m_poll_method) {
		ALOGE("Godot ARCore QR: Cannot find submitImage/pollResult methods");
		if (p_env->ExceptionCheck()) {
			p_env->ExceptionDescribe();
			p_env->ExceptionClear();
		}
		return;
	}

	m_initialized = true;
	ALOGV("Godot ARCore QR: QRScanner initialized successfully");
}

void QRScanner::uninitialize() {
	if (!m_initialized) return;

	JNIEnv *env = ARCoreWrapper::get_env_for_current_thread();
	if (env) {
		if (m_bridge_instance) {
			env->DeleteGlobalRef(m_bridge_instance);
			m_bridge_instance = nullptr;
		}
		if (m_bridge_class) {
			env->DeleteGlobalRef(m_bridge_class);
			m_bridge_class = nullptr;
		}
	}
	m_submit_method = nullptr;
	m_poll_method = nullptr;
	m_scan_in_flight = false;
	m_initialized = false;
}

void QRScanner::start() {
	ALOGV("Godot ARCore QR: start() called, m_initialized=%d", m_initialized);
	if (!m_initialized) {
		ALOGE("Godot ARCore QR: Cannot start scanning, NOT INITIALIZED! initialize() may have failed");
		return;
	}
	m_scanning = true;
	m_frame_counter = 0;
	ALOGV("Godot ARCore QR: Scanning STARTED successfully, m_scanning now true");
}

void QRScanner::stop() {
	m_scanning = false;
	m_discard_result = m_scan_in_flight; // its result belongs to the stopped session
	m_active_detections.clear();
	ALOGV("Godot ARCore QR: Scanning stopped");
}

void QRScanner::set_scan_interval(int p_frames) {
	m_scan_interval = p_frames > 0 ? p_frames : 1;
}

void QRScanner::set_lost_timeout(float p_seconds) {
	m_lost_timeout_seconds = p_seconds > 0.0f ? p_seconds : 0.1f;
}

void QRScanner::set_capture_detected_images(bool p_enabled) {
	m_capture_detected_images = p_enabled;
	if (!m_capture_detected_images) {
		for (godot::HashMap<godot::String, QRDetection>::Iterator it = m_active_detections.begin();
				it != m_active_detections.end(); ++it) {
			it->value.cropped_image.unref();
		}
	}
}

bool QRScanner::process(ArSession &p_ar_session, ArFrame &p_ar_frame) {
	if (!m_scanning || !m_initialized) {
		if (!m_scanning) ALOGV("Godot ARCore QR: process() called but m_scanning=false");
		if (!m_initialized) ALOGV("Godot ARCore QR: process() called but m_initialized=false");
		return false;
	}

	m_current_frame++;
	m_new_detections.clear();
	m_lost_codes.clear();

	if (m_scan_in_flight) {
		_poll_result(p_ar_session, p_ar_frame);
	}

	// Throttle: only scan every N frames, and only when ML Kit is free
	m_frame_counter++;
	if (m_frame_counter >= m_scan_interval && !m_scan_in_flight) {
		m_frame_counter = 0;
		ALOGV("Godot ARCore QR: Scanning frame %d", m_current_frame);
		_scan_frame(p_ar_session, p_ar_frame);
	}

	// Check for lost codes (not seen for lost_timeout)
	// Approximate: assume 30 fps, convert timeout to frames
	int lost_frame_threshold = (int)(m_lost_timeout_seconds * 30.0f);
	godot::Vector<godot::String> to_remove;

	for (godot::HashMap<godot::String, QRDetection>::Iterator it = m_active_detections.begin();
			it != m_active_detections.end(); ++it) {
		if (m_current_frame - it->value.frame_detected > lost_frame_threshold) {
			m_lost_codes.push_back(it->key);
			to_remove.push_back(it->key);
		}
	}
	for (int i = 0; i < to_remove.size(); i++) {
		m_active_detections.erase(to_remove[i]);
	}

	if (m_new_detections.size() > 0) {
		ALOGV("Godot ARCore QR: Found %zu new detections", m_new_detections.size());
	}
	if (m_lost_codes.size() > 0) {
		ALOGV("Godot ARCore QR: Lost %zu codes", m_lost_codes.size());
	}

	return m_new_detections.size() > 0 || m_lost_codes.size() > 0;
}

void QRScanner::_scan_frame(ArSession &p_ar_session, ArFrame &p_ar_frame) {
	ALOGV("Godot ARCore QR: _scan_frame() called");
	
	// Get pointers from references for proper ARCore C API usage
	ArSession *ar_session_ptr = &p_ar_session;
	ArFrame *ar_frame_ptr = &p_ar_frame;
	
	// Acquire CPU camera image
	ArImage *ar_image = nullptr;
	if (ArFrame_acquireCameraImage(ar_session_ptr, ar_frame_ptr, &ar_image) != AR_SUCCESS) {
		ALOGE("Godot ARCore QR: Failed to acquire camera image");
		return;
	}
	
	if (!ar_image) {
		ALOGE("Godot ARCore QR: ar_image is null after acquireCameraImage");
		return;
	}

	// Get image dimensions
	int32_t width, height;
	ArImage_getWidth(ar_session_ptr, ar_image, &width);
	ArImage_getHeight(ar_session_ptr, ar_image, &height);
	ALOGV("Godot ARCore QR: Camera image dimensions: %dx%d", width, height);

	if (width <= 0 || height <= 0) {
		ALOGE("Godot ARCore QR: Invalid image dimensions: %dx%d", width, height);
		ArImage_release(ar_image);
		return;
	}

	// Get YUV plane 0 (Y channel)
	const uint8_t *y_data = nullptr;
	int32_t y_data_length = 0;
	ArImage_getPlaneData(ar_session_ptr, ar_image, 0, &y_data, &y_data_length);

	if (!y_data || y_data_length <= 0) {
		ALOGE("Godot ARCore QR: Invalid Y plane data: ptr=%p, len=%d", y_data, (int)y_data_length);
		ArImage_release(ar_image);
		return;
	}

	// Get YUV plane 1 (UV interleaved - required for NV21 format)
	const uint8_t *uv_data = nullptr;
	int32_t uv_data_length = 0;
	ArImage_getPlaneData(ar_session_ptr, ar_image, 1, &uv_data, &uv_data_length);

	if (!uv_data || uv_data_length <= 0) {
		ALOGE("Godot ARCore QR: Invalid UV plane data: ptr=%p, len=%d", uv_data, (int)uv_data_length);
		ArImage_release(ar_image);
		return;
	}

	// For NV21 format, calculate expected sizes
	int expected_y_size = width * height;
	int expected_uv_size = (width * height) / 2;
	int expected_total = expected_y_size + expected_uv_size;
	
	ALOGV("Godot ARCore QR: Y plane: actual=%d, expected=%d; UV plane: actual=%d, expected=%d; total: actual=%d, expected=%d",
		(int)y_data_length, expected_y_size, (int)uv_data_length, expected_uv_size,
		(int)(y_data_length + uv_data_length), expected_total);

	// Call Java bridge to scan
	JNIEnv *env = ARCoreWrapper::get_env_for_current_thread();
	if (!env || !m_bridge_instance || !m_submit_method) {
		ArImage_release(ar_image);
		return;
	}

	// Create Java byte array with complete NV21 data (Y + UV planes)
	// Use expected size, not actual, to account for ARCore plane stride mismatches
	jbyteArray j_data = env->NewByteArray(expected_total);
	if (!j_data) {
		ArImage_release(ar_image);
		return;
	}

	// Copy Y plane
	env->SetByteArrayRegion(j_data, 0, y_data_length, reinterpret_cast<const jbyte *>(y_data));

	// Check for JNI exceptions
	if (env->ExceptionCheck()) {
		env->ExceptionClear();
		env->DeleteLocalRef(j_data);
		ArImage_release(ar_image);
		return;
	}

	// Copy UV plane right after Y plane, and pad if necessary
	env->SetByteArrayRegion(j_data, y_data_length, uv_data_length, reinterpret_cast<const jbyte *>(uv_data));
	
	// If UV plane is short, pad with zeros to match expected size
	if (uv_data_length < expected_uv_size) {
		int padding = expected_uv_size - uv_data_length;
		uint8_t zero_padding[256] = {0};  // Stack buffer for small padding
		for (int offset = 0; offset < padding; offset += sizeof(zero_padding)) {
			int to_write = (padding - offset < (int)sizeof(zero_padding)) ? (padding - offset) : (int)sizeof(zero_padding);
			env->SetByteArrayRegion(j_data, y_data_length + uv_data_length + offset, to_write, (const jbyte *)zero_padding);
		}
		ALOGV("Godot ARCore QR: Padded UV plane with %d zero bytes", padding);
	}

	// Hand the image to ML Kit and return at once; the result is picked up in a later frame
	// (_poll_result), so the render thread does not wait for the scan.
	jboolean accepted = env->CallBooleanMethod(
			m_bridge_instance, m_submit_method, j_data, (jint)width, (jint)height, (jint)0);
	if (env->ExceptionCheck()) {
		ALOGE("Godot ARCore QR: JNI exception in submitImage()");
		env->ExceptionDescribe();
		env->ExceptionClear();
		accepted = JNI_FALSE;
	}
	env->DeleteLocalRef(j_data);

	if (accepted) {
		m_scan_in_flight = true;
		m_scan_width = width;
		m_scan_height = height;
		if (m_capture_detected_images) {
			// The ArImage is released below; keep the Y plane for cropping the detections.
			m_scan_y.resize(width * height);
			memcpy(m_scan_y.ptrw(), y_data, MIN((int)y_data_length, width * height));
		} else {
			m_scan_y.clear();
		}
	}

	ArImage_release(ar_image);
}

void QRScanner::_poll_result(ArSession &p_ar_session, ArFrame &p_ar_frame) {
	JNIEnv *env = ARCoreWrapper::get_env_for_current_thread();
	if (!env || !m_bridge_instance || !m_poll_method) {
		return;
	}
	jbyteArray results = (jbyteArray)env->CallObjectMethod(m_bridge_instance, m_poll_method);
	if (env->ExceptionCheck()) {
		env->ExceptionDescribe();
		env->ExceptionClear();
		return;
	}
	if (!results) {
		return; // still scanning
	}
	m_scan_in_flight = false;
	if (m_discard_result) {
		m_discard_result = false;
	} else {
		_apply_result(env, results, &p_ar_session, &p_ar_frame);
	}
	env->DeleteLocalRef(results);
}

// Parses a packed ML Kit result. Bounds are mapped to the screen with the current frame: one or
// two frames newer than the scanned image, which is fine for an overlay.
void QRScanner::_apply_result(JNIEnv *p_env, jbyteArray p_results, ArSession *p_ar_session, ArFrame *p_ar_frame) {
	int result_bytes = p_env->GetArrayLength(p_results);
	ALOGV("Godot ARCore QR: ML Kit returned %d bytes", result_bytes);

	if (result_bytes < 4) {
		ALOGE("Godot ARCore QR: ML Kit returned malformed payload: %d bytes", result_bytes);
		return;
	}

	jbyte *raw_payload = p_env->GetByteArrayElements(p_results, nullptr);
	if (!raw_payload) {
		return;
	}

	const uint8_t *ptr = reinterpret_cast<const uint8_t *>(raw_payload);
	const uint8_t *end = ptr + result_bytes;

	auto read_u32_le = [&ptr, end](uint32_t &out_value) -> bool {
		if (end - ptr < 4) {
			return false;
		}
		out_value = (uint32_t)ptr[0] |
					((uint32_t)ptr[1] << 8) |
					((uint32_t)ptr[2] << 16) |
					((uint32_t)ptr[3] << 24);
		ptr += 4;
		return true;
	};

	uint32_t detection_count = 0;
	if (!read_u32_le(detection_count)) {
		ALOGE("Godot ARCore QR: Failed to read detection count from payload");
		p_env->ReleaseByteArrayElements(p_results, raw_payload, JNI_ABORT);
		return;
	}

	for (uint32_t i = 0; i < detection_count; i++) {
		uint32_t left_u32 = 0;
		uint32_t top_u32 = 0;
		uint32_t right_u32 = 0;
		uint32_t bottom_u32 = 0;
		uint32_t data_len = 0;
		uint32_t format_len = 0;

		if (!read_u32_le(left_u32) ||
				!read_u32_le(top_u32) ||
				!read_u32_le(right_u32) ||
				!read_u32_le(bottom_u32) ||
				!read_u32_le(data_len)) {
			ALOGE("Godot ARCore QR: Malformed payload while reading detection header %u/%u", i + 1, detection_count);
			break;
		}

		if (data_len > (uint32_t)(end - ptr)) {
			ALOGE("Godot ARCore QR: Malformed payload while reading detection data %u/%u", i + 1, detection_count);
			break;
		}

		String qr_data = String::utf8(reinterpret_cast<const char *>(ptr), (int)data_len);
		ptr += data_len;

		if (!read_u32_le(format_len)) {
			ALOGE("Godot ARCore QR: Malformed payload while reading detection format length %u/%u", i + 1, detection_count);
			break;
		}

		if (format_len > (uint32_t)(end - ptr)) {
			ALOGE("Godot ARCore QR: Malformed payload while reading detection format %u/%u", i + 1, detection_count);
			break;
		}

		String qr_format = String::utf8(reinterpret_cast<const char *>(ptr), (int)format_len);
		ptr += format_len;

		int left = (int)left_u32;
		int top = (int)top_u32;
		int right = (int)right_u32;
		int bottom = (int)bottom_u32;

		bool is_new = !m_active_detections.has(qr_data);

		QRDetection detection;
		detection.data = qr_data;
		detection.format = qr_format;
		detection.bounds_left = left;
		detection.bounds_top = top;
		detection.bounds_right = right;
		detection.bounds_bottom = bottom;
		{
			// The camera image has its own size and rotation and is cropped to fill the screen:
			// let ARCore map the corners (it knows the current display geometry).
			const float corners[8] = { (float)left, (float)top, (float)right, (float)top,
				(float)right, (float)bottom, (float)left, (float)bottom };
			float view[8];
			ArFrame_transformCoordinates2d(p_ar_session, p_ar_frame,
					AR_COORDINATES_2D_IMAGE_PIXELS, 4, corners, AR_COORDINATES_2D_VIEW, view);
			Rect2 r(Vector2(view[0], view[1]), Vector2());
			for (int c = 1; c < 4; c++) {
				r = r.expand(Vector2(view[c * 2], view[c * 2 + 1]));
			}
			detection.screen_bounds = r;
		}
		detection.frame_detected = m_current_frame;
		if (m_capture_detected_images && !m_scan_y.is_empty()) {
			detection.cropped_image = _crop_image_region(m_scan_y.ptr(), m_scan_width, m_scan_height,
					left, top, right, bottom);
		}

		m_active_detections.insert(qr_data, detection);

		if (is_new) {
			m_new_detections.push_back(detection);
			ALOGV("Godot ARCore QR: New code detected: %s [%s]", qr_data.ascii().ptr(), qr_format.ascii().ptr());
		}
	}

	p_env->ReleaseByteArrayElements(p_results, raw_payload, JNI_ABORT);
}

Ref<Image> QRScanner::get_detected_image(const String &p_qr_data) {
	if (!m_active_detections.has(p_qr_data)) {
		return Ref<Image>();
	}
	return m_active_detections[p_qr_data].cropped_image;
}

Rect2 QRScanner::get_detected_bounds(const String &p_qr_data) const {
	if (!m_active_detections.has(p_qr_data)) {
		return Rect2();
	}

	const QRDetection &detection = m_active_detections[p_qr_data];
	return Rect2(
			Vector2(detection.bounds_left, detection.bounds_top),
			Vector2(detection.bounds_right - detection.bounds_left, detection.bounds_bottom - detection.bounds_top));
}

Rect2 QRScanner::get_detected_screen_bounds(const String &p_qr_data) const {
	if (!m_active_detections.has(p_qr_data)) {
		return Rect2();
	}
	return m_active_detections[p_qr_data].screen_bounds;
}

Ref<Image> QRScanner::_crop_image_region(const uint8_t *p_yuv_data, int p_width, int p_height,
		int p_left, int p_top, int p_right, int p_bottom) {
	// Clamp bounds
	int left = CLAMP(p_left, 0, p_width - 1);
	int top = CLAMP(p_top, 0, p_height - 1);
	int right = CLAMP(p_right, left + 1, p_width);
	int bottom = CLAMP(p_bottom, top + 1, p_height);

	int crop_w = right - left;
	int crop_h = bottom - top;

	// Create grayscale Image from Y plane crop
	PackedByteArray data;
	data.resize(crop_w * crop_h);
	uint8_t *dst = data.ptrw();

	for (int y = 0; y < crop_h; y++) {
		const uint8_t *src_row = p_yuv_data + (top + y) * p_width + left;
		memcpy(dst + y * crop_w, src_row, crop_w);
	}

	Ref<Image> img = Image::create_from_data(crop_w, crop_h, false, Image::FORMAT_L8, data);
	return img;
}

void QRScanner::clear_frame_events() {
	m_new_detections.clear();
	m_lost_codes.clear();
}

#endif // ARCORE_FEATURE_QR_SCANNER
