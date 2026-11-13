class_name ScreenCapture

## Takes a picture of what is on screen (camera feed + 3D), with the given UI hidden for that one
## frame. Works the same on the desktop and on the phone. For a photo for a report, a share
## button or a "what I saw" thumbnail.
##   var img := await ScreenCapture.capture(get_viewport(), [ui_root])

static func capture(viewport: Viewport, hide: Array[CanvasItem] = []) -> Image:
	var was_visible: Array[bool] = []
	for item in hide:
		was_visible.append(item.visible)
		item.hide()
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	for i in hide.size():
		hide[i].visible = was_visible[i]
	return img
