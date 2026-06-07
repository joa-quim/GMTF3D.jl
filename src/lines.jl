# GMTF3D — view_lines: standalone 3-D polyline viewer (needs the f3d_ext DLL).

# ===========================================================================
# view_lines — standalone 3-D polyline viewer (coastlines / tracks / contours /
# wireframes with no surface under them). Mirrors the engine lifecycle of
# `_view_fv_impl` but adds NO mesh: the polylines are drawn through the f3d_ext
# line hatch (`_draw_lines`), which needs the f3d_ext DLL. `lines` accepts the
# same shapes `_draw_lines` does (Matrix N×2/3, GMTdataset, or a Vector of those).
# ===========================================================================

"""
    view_lines(lines; kwargs...)

Show 3-D polylines (coastlines, ship tracks, contours, wireframes) on their own — no
surface or mesh underneath. The lines are drawn through the `f3d_ext` line hatch, so
this viewer **requires an f3d built with `c/f3d_ext_*.cxx`** (it errors on a stock DLL).

`lines` is anything the overlay accepts: an `N×2` (z = 0) or `N×3` `Matrix`, a
`GMTdataset` (uses its `.data`; a multi-segment file is a `Vector{GMTdataset}`), or a
`Vector`/`Tuple` of any of those (several polylines in one call).

# Keywords
- `line_color=:yellow`: colour — a name/`Symbol`/`"#hex"`/`"r/g/b"`, a grey number, or
  an `(r,g,b)` tuple (`0-1` or `0-255`).
- `line_width=2.0`: width in screen pixels.
- `line_zfac=1.0`: scale applied to the z column (match a surface's vertical scale).
- `title`, `size=(1600,1200)`, `bg=(0.1,0.1,0.15)`, `up="+Z"`: window basics.
- `azimuth=-40`, `elevation=25`: initial orbit / tilt (degrees).
- `axes=true`, `grid=true`: orientation gizmo / f3d floor grid.
- `cube_axes=true`, `coord_readout=true`, `scale_handle=true`: extended interactions
  (need `f3d_ext`; see [`view_grid`](@ref)).
- `offscreen=false`, `saveimg=""`: render without a window / save the frame.
- `async=true`: viewer on a worker thread → REPL gets a `ViewHandle` at once
  (`close!(h)`); `false` blocks until the window closes. Forced off when `offscreen`.

E.g. `view_lines(GMT.coastlines())` or `view_lines([track1, track2]; line_color=:red)`.
"""
view_lines(lines; async::Bool=true, kwargs...) = (async && !get(kwargs, :offscreen, false)) ?
		_async_view(ch -> _view_lines_impl(lines; _handle_chan=ch, kwargs...)) : _view_lines_impl(lines; kwargs...)

function _view_lines_impl(lines; _handle_chan=nothing, title::AbstractString="F3D — GMT lines",
				 size::Tuple{Int,Int}=(1600, 1200), bg=(0.1, 0.1, 0.15), up="+Z",
				 line_color=:yellow, line_width::Real=2.0, line_zfac::Real=1.0,
				 azimuth::Real=-40.0, elevation::Real=25.0, axes::Bool=true, grid::Bool=true,
				 cube_axes::Bool=true, coord_readout::Bool=true, scale_handle::Bool=true,
				 offscreen::Bool=false, saveimg::String="")
	_has_f3d_ext() || error("view_lines needs an f3d built with c/f3d_ext_*.cxx (f3d_ext_add_lines)")
	F3D.f3d_engine_autoload_plugins()
	engine = F3D.f3d_engine_create(Cint(offscreen ? 1 : 0))
	engine == C_NULL && error("failed to create F3D engine")
	scene  = F3D.f3d_engine_get_scene(engine)
	window = F3D.f3d_engine_get_window(engine)
	F3D.f3d_window_set_size(window, Cint(size[1]), Cint(size[2]))
	_place_window(window, size)
	F3D.f3d_window_set_window_name(window, title)

	opts = F3D.f3d_engine_get_options(engine)
	(up === nothing) || F3D.f3d_options_set_as_string_representation(opts, "scene.up_direction", string(up))
	F3D.f3d_options_set_as_bool(opts, "ui.scalar_bar", Cint(0))
	axes && F3D.f3d_options_set_as_bool(opts, "ui.axis", Cint(1))
	if grid
		F3D.f3d_options_set_as_bool(opts, "render.grid.enable", Cint(1))
		F3D.f3d_options_set_as_bool(opts, "render.grid.absolute", Cint(0))
	end
	F3D.f3d_options_set_as_double_vector(opts, "render.background.color", Cdouble[bg[1], bg[2], bg[3]], Csize_t(3))

	# Draw the polylines FIRST so reset_to_bounds has actors to frame (the line actors
	# are real props in the renderer, so ResetCamera includes them).
	_draw_lines(window, lines, line_color, line_width, line_zfac)

	camera = F3D.f3d_window_get_camera(window)
	F3D.f3d_camera_reset_to_bounds(camera, 0.9)
	(azimuth   == 0) || F3D.f3d_camera_azimuth(camera, Cdouble(azimuth))
	(elevation == 0) || F3D.f3d_camera_elevation(camera, Cdouble(elevation))
	F3D.f3d_window_render(window)

	if (cube_axes && _has_f3d_ext())
		F3D.f3d_ext_enable_cube_axes(window; floor = false);  F3D.f3d_window_render(window)
	end
	if (scale_handle && _has_f3d_ext())          # gizmo before the grab -> shows in exports too
		F3D.f3d_ext_enable_scale_handle(window, opts, Cdouble(0.01));  F3D.f3d_window_render(window)
	end

	if !isempty(saveimg)
		simg, sfmt = _img_target(saveimg)
		img = F3D.f3d_window_render_to_image(window, Cint(0))
		F3D.f3d_image_save(img, simg, sfmt)
	end
	if offscreen
		F3D.f3d_engine_delete(engine);  return nothing
	end

	interactor = F3D.f3d_engine_get_interactor(engine)
	F3D.f3d_interactor_init_commands(interactor)
	F3D.f3d_interactor_init_bindings(interactor)
	_disable_raytracing_bindings(interactor)   # live RT pins CPU + freezes window; offscreen RT still ok
	disable_extras = _enable_extras(window, opts; cube_axes=cube_axes, coord_readout=coord_readout, scale_handle=scale_handle)
	(_handle_chan === nothing) || put!(_handle_chan, interactor)
	_interactor_start_gcsafe(interactor, 1.0 / 30.0)

	F3D.f3d_interactor_stop(interactor)
	disable_extras()
	_has_f3d_ext() && F3D.f3d_ext_clear_lines(window)
	F3D.f3d_scene_clear(scene)
	F3D.f3d_engine_delete(engine)
	return nothing
end
