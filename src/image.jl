# GMTF3D — view_image: flat 2-D image viewer (orthographic, rotation-locked).

# Georeferenced? An image carries a CRS (proj4 / WKT / EPSG) only when it has been
# referenced; a plain picture (e.g. `mat2img` of an array, or a decoded JPEG/PNG)
# has none. That is exactly the line between "show map coordinates" and "just show
# the picture".
_img_is_georef(I::GMT.GMTimage) = !isempty(I.proj4) || !isempty(I.wkt) || I.epsg != 0

function _view_image_impl(I::GMT.GMTimage; _handle_chan=nothing, title::AbstractString="F3D — GMT image", bg=(0.1, 0.1, 0.15),
		size=nothing, decimals=nothing, offscreen::Bool=false, saveimg::String="",
		lines=nothing, line_color=nothing, line_width::Real=2.0, L=nothing)
	lines = L === nothing ? lines : L          # `L` = GMT-style short alias for `lines`
	savefmt = F3D.PNG
	isempty(saveimg) || ((saveimg, savefmt) = _img_target(saveimg))
	isgeo = _img_is_georef(I)
	nr, nc = Base.size(I, 1), Base.size(I, 2)        # rows, cols (kwarg `size` shadows Base.size)

	# Extent: real coordinates if referenced, else the pixel grid.
	r = (length(I.range) >= 4 && I.range[2] > I.range[1] && I.range[4] > I.range[3]) ?
		I.range : Float64[1.0, nc, 1.0, nr]
	x0, x1, y0, y1 = Float64(r[1]), Float64(r[2]), Float64(r[3]), Float64(r[4])

	# Window: match the image aspect (coordinate extent if referenced, else pixels),
	# then pad for the outward ticks + labels when axes are drawn.
	if size === nothing
		asp  = isgeo ? (x1 - x0) / (y1 - y0) : nc / nr
		long = 900
		w, h = asp >= 1 ? (long, max(round(Int, long / asp), 1)) :
						   (max(round(Int, long * asp), 1), long)
		isgeo && (w += 90; h += 70)                  # room for axis annotations
		win = (w, h)
	else
		win = size
	end

	# Flat quad at z=0 spanning the extent, draped with the image.
	V = Float64[x0 y0 0.0; x1 y0 0.0; x1 y1 0.0; x0 y1 0.0]
	quad = GMT.GMTfv(verts=V, faces=[[1 2 3 4]], color=[String[]],
					 bbox=Float64[x0, x1, y0, y1, 0.0, 0.0], isflat=[false])
	m = fv_to_mesh(quad; drape=true)

	F3D.f3d_engine_autoload_plugins()
	engine = F3D.f3d_engine_create(Cint(offscreen ? 1 : 0))
	engine == C_NULL && error("failed to create F3D engine")
	scene  = F3D.f3d_engine_get_scene(engine)
	window = F3D.f3d_engine_get_window(engine)
	F3D.f3d_window_set_size(window, Cint(win[1]), Cint(win[2]))
	_place_window(window, win)
	F3D.f3d_window_set_window_name(window, title)

	opts = F3D.f3d_engine_get_options(engine)
	F3D.f3d_options_set_as_string_representation(opts, "scene.up_direction", "+Z")
	F3D.f3d_options_set_as_bool(opts, "ui.axis", Cint(0))                # no gizmo
	F3D.f3d_options_set_as_bool(opts, "ui.scalar_bar", Cint(0))
	F3D.f3d_options_set_as_bool(opts, "render.grid.enable", Cint(0))
	F3D.f3d_options_set_as_bool(opts, "scene.camera.orthographic", Cint(1))   # 2-D
	F3D.f3d_options_set_as_string(opts, "interactor.style", "2d")             # lock rotation
	F3D.f3d_options_set_as_double_vector(opts, "render.background.color", Cdouble[bg[1], bg[2], bg[3]], Csize_t(3))

	# Drape the image as an UNLIT texture: emissive = image at full factor and the
	# diffuse light killed, so the quad shows the exact pixels with no relief shading.
	tex_path = joinpath(tempdir(), "f3d_image_$(getpid()).png")
	GMT.gmtwrite(tex_path, I)
	cp = collapse_path(tex_path)
	F3D.f3d_options_set_as_string(opts, "model.color.texture", cp)
	F3D.f3d_options_set_as_string(opts, "model.emissive.texture", cp)
	F3D.f3d_options_set_as_double_vector(opts, "model.emissive.factor", Cdouble[1, 1, 1], Csize_t(3))
	F3D.f3d_options_set_as_double(opts, "render.light.intensity", Cdouble(0.0))

	GC.@preserve m begin
		nrm = isempty(m.normals)   ? C_NULL : pointer(m.normals)
		tex = isempty(m.texcoords) ? C_NULL : pointer(m.texcoords)
		mesh = Ref(F3D.f3d_mesh_t(
			pointer(m.points),   Csize_t(length(m.points)),
			nrm,                 Csize_t(length(m.normals)),
			tex,                 Csize_t(length(m.texcoords)),
			pointer(m.sides),    Csize_t(length(m.sides)),
			pointer(m.indices),  Csize_t(length(m.indices))))
		F3D.f3d_scene_add_mesh(scene, mesh) == 1 || (F3D.f3d_engine_delete(engine); error("f3d_scene_add_mesh failed"))
	end

	# Camera: orthographic, straight above, north up.
	cam = F3D.f3d_window_get_camera(window)
	F3D.f3d_camera_reset_to_bounds(cam, Cdouble(0.95))
	fp = zeros(Cdouble, 3);  F3D.f3d_camera_get_focal_point(cam, fp)
	ps = zeros(Cdouble, 3);  F3D.f3d_camera_get_position(cam, ps)
	d  = hypot(ps[1]-fp[1], ps[2]-fp[2], ps[3]-fp[3])
	F3D.f3d_camera_set_position(cam, [fp[1], fp[2], fp[3] + d])
	F3D.f3d_camera_set_view_up(cam, [0.0, 1.0, 0.0])
	F3D.f3d_camera_reset_to_bounds(cam, Cdouble(0.95))
	F3D.f3d_window_render(window)

	# Box-fit (not sphere-fit): reset_to_bounds fits the bounding sphere and centres
	# the image, wasting space on the long axis + all four sides. Measure the data
	# box on screen and zoom to fill the frame; for a georef image leave a label band
	# at the bottom (X axis) and left (Y axis) and pan the data into the top-right so
	# no space is wasted where there are no labels.
	todisp(wx, wy) = (dd = zeros(Cdouble, 3);
		F3D.f3d_window_get_display_from_world(window, [Cdouble(wx), Cdouble(wy), 0.0], dd); (dd[1], dd[2]))
	a = todisp(x0, y0);  b = todisp(x1, y1)
	dxpx = max(abs(b[1] - a[1]), 1.0);  dypx = max(abs(b[2] - a[2]), 1.0)
	# Bottom/left band carries the X/Y axes; top/right need only a small band so the
	# END labels (centred on the max-x / max-y corner ticks) are not clipped at the edge.
	leftpx  = isgeo ? 0.11 * win[1] : 0.02 * win[1]
	botpx   = isgeo ? 0.12 * win[2] : 0.02 * win[2]
	rightpx = isgeo ? 0.05 * win[1] : 0.02 * win[1]
	toppx   = isgeo ? 0.05 * win[2] : 0.02 * win[2]
	f = min((win[1] - leftpx - rightpx) / dxpx, (win[2] - botpx - toppx) / dypx)
	F3D.f3d_camera_zoom(cam, Cdouble(f));  F3D.f3d_window_render(window)
	# Pan so the data's left edge sits at `leftpx` and bottom edge at `botpx`.
	a = todisp(x0, y0);  b = todisp(x1, y1)
	datl = min(a[1], b[1]);  datb = min(a[2], b[2])
	wppx = (x1 - x0) / max(abs(b[1] - a[1]), 1.0);  wppy = (y1 - y0) / max(abs(b[2] - a[2]), 1.0)
	F3D.f3d_camera_pan(cam, Cdouble(-(leftpx - datl) * wppx), Cdouble(-(botpx - datb) * wppy), 0.0)
	F3D.f3d_window_render(window)

	# 2-D map frame (referenced images only): X bottom + Y left, outward ticks,
	# decimals chosen so labels are unique. Needs the f3d_ext DLL.
	if isgeo && _has_f3d_ext()
		dx = decimals === nothing ? _axis_decimals(x1 - x0) : (decimals isa Tuple ? Int(decimals[1]) : Int(decimals))
		dy = decimals === nothing ? _axis_decimals(y1 - y0) : (decimals isa Tuple ? Int(decimals[2]) : Int(decimals))
		F3D.f3d_ext_enable_image_axes(window, "%.$(dx)f", "%.$(dy)f")
		F3D.f3d_window_render(window)
	end

	# Line overlays on the flat image (coastlines, tracks). The image lies at z = 0
	# and the view is top-down, so zfac = 1 (z column, if any, is honoured but unseen).
	_draw_lines(window, lines, line_color, line_width, 1.0)

	if !isempty(saveimg)
		img = F3D.f3d_window_render_to_image(window, Cint(0))
		F3D.f3d_image_save(img, saveimg, savefmt);  F3D.f3d_image_delete(img)
	end

	if offscreen
		rm(tex_path; force=true)
		F3D.f3d_engine_delete(engine)
		return nothing
	end

	interactor = F3D.f3d_engine_get_interactor(engine)
	F3D.f3d_interactor_init_commands(interactor)
	F3D.f3d_interactor_init_bindings(interactor)
	_disable_raytracing_bindings(interactor)   # live RT pins CPU + freezes window; offscreen RT still ok
	# Live coordinate readout under the cursor (referenced images only). Picks the
	# world point on the flat quad -> shows lon/lat. Interactor-only, so it is enabled
	# here (not on the offscreen path) after the interactor is initialised.
	isgeo && _has_f3d_ext() && F3D.f3d_ext_enable_coord_readout(window)
	_handle_chan === nothing || put!(_handle_chan, interactor)
	_interactor_start_gcsafe(interactor, 1.0 / 30.0)        # blocks until closed (GC-safe)
	F3D.f3d_interactor_stop(interactor)
	if isgeo && _has_f3d_ext()
		F3D.f3d_ext_disable_coord_readout(window)
		F3D.f3d_ext_disable_cube_axes(window)
	end
	lines === nothing || !_has_f3d_ext() || F3D.f3d_ext_clear_lines(window)
	rm(tex_path; force=true)
	F3D.f3d_scene_clear(scene)
	F3D.f3d_engine_delete(engine)
	return nothing
end

"""
    view_image(I::GMTimage; kwargs...)

Display a 2-D image `I` in an interactive F3D window as a flat, top-down picture —
no intermediate grid. The image is laid on a quad spanning its own extent and
draped on as an unlit texture, so it shows the exact pixels. It is a strict **2-D
viewer**: orthographic, north up, rotation locked (`interactor.style="2d"`, pan +
zoom only), no orientation gizmo.

Whether it is **georeferenced** (carries a CRS — `proj4`/`wkt`/`epsg`) decides two
things automatically:
- a **referenced** image gets the 2-D coordinate frame — an X axis along the
  bottom and a Y axis along the left with outward tick marks and lon/lat labels —
  and the window is sized to the coordinate-extent aspect;
- a **plain** image gets no axes and the window is sized to the pixel aspect.

# Keywords
- `decimals=nothing`: tick-label decimal places (`Int`, or `(dx, dy)` per axis).
  `nothing` auto-picks the fewest decimals that keep every label unique.
- `size=nothing`: explicit window size `(w, h)` in px; `nothing` derives it from the
  image aspect (coordinate extent if referenced, else pixels).
- `title="F3D — GMT image"`: window title bar text.
- `bg=(0.1,0.1,0.15)`: background colour, RGB in `0-1`.
- `saveimg=""`: save the frame to this file (format from extension); empty = none.
- `offscreen=false`: render without opening a window (no interaction).
- `async=true`: viewer on a worker thread → REPL gets a `ViewHandle` at once
  (`close!(h)`); `false` blocks until the window closes. Forced off when `offscreen`.

A referenced image also gets the live coordinate readout (lon/lat under the cursor)
in the interactive window.

`async=true` (default) runs the viewer on a worker thread and hands the REPL back a
`ViewHandle` at once (`close!(h)`); `async=false` blocks until the window closes.

E.g. `view_image(I)` or `view_image(I; decimals=3)`.
"""
view_image(I::GMT.GMTimage; async::Bool=true, kwargs...) =
	(async && !get(kwargs, :offscreen, false)) ?
		_async_view(ch -> _view_image_impl(I; _handle_chan=ch, kwargs...)) : _view_image_impl(I; kwargs...)
