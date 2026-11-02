//
// Created by Patrick on 07.09.2023.
// Modified by luca on 18.08.24.
// Modified by Maxime on 08.09.24.
//

#ifndef ARCOREPLUGIN_ARCORE_INTERFACE_H
#define ARCOREPLUGIN_ARCORE_INTERFACE_H

#include "godot_cpp/variant/projection.hpp"
#include "include/arcore_c_api.h"
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/classes/xr_interface_extension.hpp>
#include <godot_cpp/classes/xr_positional_tracker.hpp>

#include "arcore_rgba_texture.h"
#include "background_renderer.h"
#include "plane_renderer.h"
#include "plane_tracker.h"
#include "point_cloud_renderer.h"
#include "image_tracker.h"
#include "qr_scanner.h"

namespace godot {
class ARCoreInterface : public XRInterfaceExtension {
	GDCLASS(ARCoreInterface, XRInterfaceExtension);

protected:
	static void _bind_methods();

public:
	enum InitStatus {
		NOT_INITIALISED,
		START_INITIALISE,
		INITIALISED,
		INITIALISE_FAILED
	};

	// Controls how much of the per-frame AR pipeline runs. Used to implement the
	// "inspect mode" freeze, where the user holds the AR view still to interact with /
	// orbit around the currently visible content.
	enum ARSessionState {
		AR_SESSION_RUNNING = 0, // normal AR: camera pose + displayed feed updated every frame
		AR_SESSION_FROZEN,      // view held still (pose + displayed feed frozen), but ARCore keeps
		                        // running underneath — still tracking, finding planes, scanning QR,
		                        // collecting feature points. Resume is seamless.
		AR_SESSION_FULLY_PAUSED // ArSession_pause(): camera + tracking stopped entirely (saves power)
	};

	ARCoreInterface();
	virtual ~ARCoreInterface();
	void start();
	void _resume();
	void _pause();

	void set_ar_session_state(int p_state);
	int get_ar_session_state() const;

	// Method overrides from XRInterface
	virtual XRInterface::TrackingStatus _get_tracking_status() const override;

	virtual StringName _get_name() const override;

	virtual uint32_t _get_capabilities() const override;

	virtual int32_t _get_camera_feed_id() const override;

	virtual bool _is_initialized() const override;

	virtual bool _initialize() override;

	virtual void _uninitialize() override;

	virtual Vector2 _get_render_target_size() override;

	virtual uint32_t _get_view_count() override;

	virtual Transform3D _get_camera_transform() override;

	virtual Transform3D _get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) override;

	virtual PackedFloat64Array _get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far) override;

	virtual void _post_draw_viewport(const RID &p_render_target, const Rect2 &p_screen_rect) override;

	virtual void _process() override;

	virtual void notification(int p_what);

	void enable_depth_estimation(bool p_enable);
	bool is_depth_supported();
	void show_depth_map(bool p_enable);
	void set_max_depth_meters(float p_max_depth_meters);
	void enable_vertical_plane_detection(bool p_enable);
	void enable_horizontal_plane_detection(bool p_enable);
	void enable_instant_placement(bool p_enable);
	godot::Transform3D getHitPose(float p_pixel_x, float p_pixel_y);
	godot::Transform3D getHitRayPose(const godot::Vector3 &p_origin, const godot::Vector3 &p_direction);
	// Vertical FOV (degrees) of ARCore's current rendering projection. Godot's Camera3D.fov is
	// bypassed under XR (the projection matrix is supplied directly), so GDScript feeds this into
	// Camera3D.fov to keep project_ray_normal()/picking aligned with what's on screen.
	double get_camera_fov() const;
	// The full 4x4 rendering projection (column-major, 16 doubles) ARCore currently renders with.
	// GDScript unprojects screen taps through this so object picking matches the on-screen image
	// exactly, regardless of FOV/aspect/orientation (Camera3D's own projection is bypassed by XR).
	godot::PackedFloat64Array get_projection_matrix() const;
	void enable_images_detection(bool p_enable);
	void enable_point_cloud_detection(bool p_enable);
	godot::PackedVector3Array point_cloud_get_points();
	godot::PackedFloat32Array point_cloud_get_confidences();
	void point_cloud_set_confidence_threshold(float p_threshold);
	void switch_orientation(bool p_vertical);
	void enable_light_estimation(bool p_enable);
	godot::Vector4 get_light_color_correction();
	godot::Vector3 get_light_main_hdr_direction();
	godot::Vector3 get_light_main_hdr_intensity();

#if ARCORE_FEATURE_QR_SCANNER
	// QR Scanner
	void qr_scanner_start();
	void qr_scanner_stop();
	bool qr_scanner_is_active();
	void qr_scanner_set_scan_interval(int p_frames);
	void qr_scanner_set_lost_timeout(float p_seconds);
	void qr_scanner_set_capture_detected_images(bool p_enabled);
	bool qr_scanner_get_capture_detected_images() const;
	godot::Ref<godot::Image> qr_scanner_get_detected_image(const godot::String &p_qr_data);
	godot::Rect2 qr_scanner_get_detected_bounds(const godot::String &p_qr_data) const;
#endif

	void image_tracker_database_create();
	godot::PackedByteArray image_tracker_database_get_serialized();
	void image_tracker_database_load(const godot::PackedByteArray &db);
	void image_tracker_database_add_image(godot::Ref<godot::Image> img, const godot::String &img_identifier, float img_phyisical_width = -1.0);
	bool image_tracker_get_image_tracking_status(const godot::String &img_identifier);
	godot::Transform3D image_tracker_get_tracked_transform(const godot::String &img_identifier);

	godot::Array plane_tracker_get_all_plane_ids(int flags);
	godot::Array plane_tracker_get_plane_boundary(int plane_id);
	godot::Transform3D plane_tracker_get_plane_transform(int plane_id);
	int plane_tracker_get_plane_parent(int plane_id);
	

	godot::Ref<godot::CameraFeed> get_camera_feed();
	godot::Ref<godot::ARCoreRGBATexture> get_camera_rgba_texture();
	godot::String get_last_error() const { return m_last_error; }


	float getNear() { return m_z_near; }
	float getFar() { return m_z_far; }

private:
	enum class Orientation : int32_t {
		UNKNOWN = -1, // Not initialized
		ROTATION_0 = 0, // Portrait mode
		ROTATION_90 = 1, // Counter-clockwise rotation of 90 degrees
		ROTATION_180 = 2, // Upside down
		ROTATION_270 = 3 // Counter-clockwise rotation of 270 degrees
	};

	arcore_plugin::BackgroundRenderer m_background_renderer;
	arcore_plugin::PlaneRenderer m_plane_renderer;
	arcore_plugin::PlaneTracker m_plane_tracker;
	arcore_plugin::PointCloudRenderer m_point_cloud_renderer;
	arcore_plugin::ImageTracker m_image_tracker;
#if ARCORE_FEATURE_QR_SCANNER
	arcore_plugin::QRScanner m_qr_scanner;
#endif

	InitStatus m_init_status;
	godot::String m_last_error;
	ARSessionState m_session_state = AR_SESSION_RUNNING;
	ArSession *m_ar_session;
	ArFrame *m_ar_frame;
	int m_screen_width;
	int m_screen_height;
	Orientation m_display_orientation;

	Ref<XRPositionalTracker> m_head;
	Transform3D m_view;
	Projection m_projection;
	float m_z_near;
	float m_z_far;

	TrackingStatus m_tracking_status;

	bool m_enable_depth_estimation;
	bool m_enable_vertical_plane_detection;
	bool m_enable_horizontal_plane_detection;
	bool m_enable_instant_placement;
	bool m_enable_images_detection;
	bool m_enable_point_cloud_detection;
	bool m_enable_light_estimation;
	bool m_vertical_orientation;
	godot::Vector4 m_color_correction;
	godot::Vector3 m_light_env_hdr_main_light_direction;
	godot::Vector3 m_light_env_hdr_main_light_intensity;

	void configureSession();

	void estimateLight();
};
}; //namespace godot

VARIANT_ENUM_CAST(godot::ARCoreInterface::ARSessionState);

#endif //ARCOREPLUGIN_ARCORE_INTERFACE_H
