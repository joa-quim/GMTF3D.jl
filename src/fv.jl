# GMTF3D — view_fv: GMTfv solids & arbitrary meshes.
# Plus poly2fv (polygons→fv), the demo z-ramp colouriser and the SOLIDS catalogue.

"""
	view_fv(fv; kwargs...)

Open an interactive F3D viewer showing a `GMTfv` (faces-vertices solid), using its
per-face colours when present. Blocks until the window is closed, unless `async`
(then it returns a `ViewHandle` at once) or `offscreen`.

# Window & threading
- `title="F3D — GMT solid"`: window title bar text.
- `size=(1600,1200)`: window size in pixels `(w, h)`.
- `bg=(0.1,0.1,0.15)`: background colour, RGB in `0-1`.
- `async=true`: run the viewer on a worker thread and hand the REPL back a
  `ViewHandle` immediately (window stays interactive; `close!(h)` to shut it).
  `async=false` blocks until the window closes. Forced off when `offscreen`.

# Lighting & material (`nothing`/`NaN` keeps f3d's defaults)
- `lights=()`: vector of light NamedTuples (see `add_lights!`); empty = f3d's
  default headlight.
- `metallic=NaN`: PBR metalness, scalar `0-1`.
- `roughness=NaN`: PBR roughness, scalar `0-1`.
- `emissive=nothing`: self-illumination factor — scalar grey or `(r,g,b)` (`0-1`).

# Shading & decoration
- `flat=false`: flat (faceted) shading instead of smooth normals.
- mesh wireframe edges: toggle live with the `'e'` hotkey (no kwarg). The only
  programmatic use is `view_grid(...; outside=:shademesh)`, which turns edges on
  for the grid area an image drape does NOT cover.
- `axes=true`: show the corner orientation gizmo (forced off under `topdown`).
- `grid=true`: show f3d's floor grid at the bbox bottom = cube-axes floor (forced
  off under `topdown`).

# Camera
- `azimuth=-40.0`, `elevation=25.0`: initial orbit / tilt of the camera (degrees).
- `topdown=false`: orthographic straight-down, north-up view (georeferenceable).
- `up="+Z"`: scene up-direction (`"+Z"` lays z-up data flat with X,Y on the floor).

# Image draping (`drape::GMTimage` overrides per-face colours)
- `drape=GMTimage()`: image to drape over the surface as a texture.
- `drape_clip=false`: `false` stretches the image to the full x,y extent, ignoring
  its georeferencing; `true` honours the image's geographic coords — warps it onto
  the surface bbox so only the grid ∩ image overlap is painted, rest transparent.
  Use for a referenced GeoTIFF over a DEM sharing a coordinate system.
- `drape_light=1.0`: emissive factor for the drape (`1.0` = full image colour,
  lower keeps more relief shading).
- `drape_emis=GMTimage()`: separate emissive image; when given it is the glow layer
  while `drape` stays the lit colour (relief shading + glowing overlay).
- `drape_unlit=false`: kill diffuse lighting so the surface shows ONLY the image at
  full colour (no relief shading).

# Export
- `mapexport=""`: one-shot georeferenceable map — forces orthographic top-down +
  offscreen and saves to this file (format from extension, default PNG; `.tiff`
  writes a GeoTIFF when `georef` is set).
- `saveimg=""`: save the current frame to a file (format from extension) without
  forcing top-down.
- `offscreen=false`: render without opening a window (no interaction; extras off).
- `georef=nothing`: `(x0,x1,y0,y1,proj)` tuple stamped onto a `.tiff` export to make
  it a GeoTIFF; usually filled in for you by `view_grid`.

# Colour bar & extended interactions (need an f3d built with `c/f3d_ext_*.cxx`)
- `colorbar=nothing`: NamedTuple `(rgb, n, vmin, vmax[, title, fmt])` drawing a
  colour scale on the right edge; `nothing` = none.
- `cube_axes=true`: labelled bounding-box (X/Y/Z tick) axes with coords.
- `coord_readout=true`: live world X/Y/Z under the cursor (bottom-left).
- `vscale_drag=true`: Ctrl+left-drag to exaggerate / flatten the relief.
- `vscale_step=0.01`: vertical-scale change per dragged pixel (with `vscale_drag`).
- `scale_handle=false`: show a Fledermaus-style gizmo at the rotation centre — drag the
  vertical arrowhead to exaggerate the relief (the cone stretches to show the factor),
  the horizontal arrows to tilt, the compass ring to spin azimuth (Ctrl+left-drag also
  still scales). Supersedes `vscale_drag` when on.
"""
view_fv(fv::GMT.GMTfv; async::Bool=true, kwargs...) =
	(async && !get(kwargs, :offscreen, false)) ?   # offscreen has no window -> nothing to hand back
		_async_view(ch -> _view_fv_impl(fv; _handle_chan=ch, kwargs...)) : _view_fv_impl(fv; kwargs...)

function _view_fv_impl(fv::GMT.GMTfv; _handle_chan=nothing, title::AbstractString="F3D — GMT solid",
				 size::Tuple{Int,Int}=(1600, 1200), bg=(0.1, 0.1, 0.15),
				 lights=(), flat::Bool=false, axes::Bool=true,
				 grid::Bool=true, _edges::Bool=false,
				 offscreen::Bool=false, saveimg::String="", mapexport::AbstractString="",
				 azimuth::Real=-40.0, elevation::Real=25.0, topdown::Bool=false,
				 up="+Z", cube_axes::Bool=true, coord_readout::Bool=true, floor::Bool=false,
				 vscale_drag::Bool=true, vscale_step::Real=0.01, scale_handle::Bool=true,
				 drape::GMT.GMTimage=GMT.GMTimage(), drape_clip::Bool=false,
				 drape_emis::GMT.GMTimage=GMT.GMTimage(),
				 drape_light::Real=1.0, drape_unlit::Bool=false, _edge_width::Real=1.0,
				 metallic=NaN, roughness=NaN, emissive=nothing, georef=nothing, colorbar=nothing,
				 lines=nothing, line_color=nothing, line_width::Real=2.0, line_zfac::Real=1.0, L=nothing)
	lines = (L === nothing) ? lines : L          # `L` = GMT-style short alias for `lines`
	savefmt = F3D.PNG
	if (!isempty(mapexport))
		topdown = true;  offscreen = true
		saveimg, savefmt = _img_target(mapexport)
	elseif !isempty(saveimg)
		saveimg, savefmt = _img_target(saveimg)
	end

	do_drape = !isempty(drape)
	m = fv_to_mesh(fv; flat = flat, drape = do_drape)

	F3D.f3d_engine_autoload_plugins()
	engine = F3D.f3d_engine_create(Cint(offscreen ? 1 : 0))
	engine == C_NULL && error("failed to create F3D engine")

	scene  = F3D.f3d_engine_get_scene(engine)
	window = F3D.f3d_engine_get_window(engine)
	win = size
	if topdown                                   # match window aspect to xy data bounds
		xmn = xmx = m.points[1];  ymn = ymx = m.points[2]
		@inbounds for i in 1:(length(m.points) ÷ 3)
			x = m.points[3i-2];  y = m.points[3i-1]
			x < xmn && (xmn = x);  x > xmx && (xmx = x)
			y < ymn && (ymn = y);  y > ymx && (ymx = y)
		end
		ar   = (xmx - xmn) / max(ymx - ymn, eps(Float32))         # Δx/Δy
		long = max(size[1], size[2])
		win  = (ar >= 1) ? (long, max(round(Int, long / ar), 1)) : (max(round(Int, long * ar), 1), long)
	end
	F3D.f3d_window_set_size(window, Cint(win[1]), Cint(win[2]))
	_place_window(window, win)
	F3D.f3d_window_set_window_name(window, title)

	opts = F3D.f3d_engine_get_options(engine)
	# `up`: scene up-direction ("+Z", "+Y", ...). Grids are z=f(x,y) so +Z lays them
	# flat (X,Y on the floor, Z vertical); use set_as_string_representation — plain
	# set_as_string CRASHES on the `direction` option type.
	up === nothing || F3D.f3d_options_set_as_string_representation(opts, "scene.up_direction", string(up))
	# Mesh wireframe is normally a live `'e'` toggle, NOT a kwarg. `_edges` is the one
	# internal exception: view_grid's outside=:shademesh turns it on so the grid area an
	# image drape does not cover shows structure. (Sets render.show_edges, same as 'e'.)
	F3D.f3d_options_set_as_bool(opts, "render.show_edges", Cint(_edges ? 1 : 0))
	_edges && F3D.f3d_options_set_as_double(opts, "render.line_width", Cdouble(_edge_width))
	F3D.f3d_options_set_as_bool(opts, "ui.scalar_bar", Cint(0))
	(axes && !topdown) && F3D.f3d_options_set_as_bool(opts, "ui.axis", Cint(1))  # gizmo; off for map export
	# Floor grid at the model's bbox bottom. Suppressed when an image is draped: its
	# lines read THROUGH the flat parts of the relief (which sit at z=zmin, the floor
	# level) and make the draped surface look see-through. The draped picture is the
	# focus anyway, so the floor grid is just noise there.
	if (grid && !topdown && !do_drape)
		F3D.f3d_options_set_as_bool(opts, "render.grid.enable", Cint(1))   # (z=zmin) = the cube
		F3D.f3d_options_set_as_bool(opts, "render.grid.absolute", Cint(0)) # axes floor, NOT z=0
	end

	# NOTE: render.axes_grid (labeled coord ticks) is an UNREGISTERED key in this
	# DLL (3.5.0-103, predates the option). f3d_options_set_as_* SEGFAULTS on any
	# unknown key (not just this one) — never set keys this DLL doesn't know.
	# Origin grid + gizmo give orientation and object-vs-origin offset instead.
	bgc = Cdouble[bg[1], bg[2], bg[3]]
	F3D.f3d_options_set_as_double_vector(opts, "render.background.color", bgc, Csize_t(3))
	# PBR material / self-illumination (only set when given, else f3d defaults stand).
	# metallic, roughness: scalars 0-1. emissive: scalar grey or (r,g,b) factor (0-1).
	isnan(metallic) || F3D.f3d_options_set_as_double(opts, "model.material.metallic",  Cdouble(metallic))
	isnan(roughness) || F3D.f3d_options_set_as_double(opts, "model.material.roughness", Cdouble(roughness))
	if (emissive !== nothing)
		ef = emissive isa Real ? Cdouble[emissive, emissive, emissive] :
								 Cdouble[emissive[1], emissive[2], emissive[3]]
		F3D.f3d_options_set_as_double_vector(opts, "model.emissive.factor", ef, Csize_t(3))
	end

	# Temp textures to delete when the window CLOSES — NOT after the first render. f3d
	# re-reads model.color/emissive.texture on every option re-push (e.g. the Ctrl-drag
	# vertical-scale changing render.model_scale); deleting early -> "Texture file does
	# not exist" spam + lost texture. The per-face palette goes fully in-memory (gap #1).
	tmp_files = String[]
	if do_drape                                 # external image draped over surface
		palette_path = joinpath(tempdir(), "f3d_drape_$(getpid()).png")
		if drape_clip                           # honour image coords: paint only the overlap
			gx0, gx1 = extrema(@view fv.verts[:, 1])
			gy0, gy1 = extrema(@view fv.verts[:, 2])
			GMT.gmtwrite(palette_path, drape_to_bbox(drape, gx0, gx1, gy0, gy1))
			# warped canvas has an alpha band (0 outside the image) — enable blending
			# so the non-overlap area reads as transparent, not opaque black.
			F3D.f3d_options_set_as_bool(opts, "render.effect.blending.enable", Cint(1))
		else                                    # stretch image over the whole surface
			GMT.gmtwrite(palette_path, drape)   # GMTimage -> PNG (bands/layout handled)
		end
		F3D.f3d_options_set_as_string(opts, "model.color.texture", collapse_path(palette_path))
		push!(tmp_files, palette_path)
		# A single headlight leaves draped imagery dim; make the image emissive so it
		# shows near true-colour. `drape_light` is the emissive factor (1.0 = full image
		# colour, lower keeps more relief shading). When `drape_emis` is given it is the
		# emissive texture instead of the colour one — used by outside=:mesh so the grey
		# (lit, edge-bearing) fill emits nothing while the image still glows.
		emis_path = palette_path
		if (!isempty(drape_emis))
			emis_path = joinpath(tempdir(), "f3d_drape_emis_$(getpid()).png")
			GMT.gmtwrite(emis_path, drape_emis)
			push!(tmp_files, emis_path)
		end
		F3D.f3d_options_set_as_string(opts, "model.emissive.texture", collapse_path(emis_path))
		ef = Cdouble(drape_light)
		F3D.f3d_options_set_as_double_vector(opts, "model.emissive.factor", Cdouble[ef, ef, ef], Csize_t(3))
		# `drape_unlit`: kill diffuse lighting so the surface shows ONLY the (full)
		# emissive texture -> dead-flat, NO relief shading. Used by outside=:mesh, whose
		# baked canvas is already flat fill + lines; any headlight would re-introduce the
		# grey shading the user does not want.
		drape_unlit && F3D.f3d_options_set_as_double(opts, "render.light.intensity", Cdouble(0.0))
	elseif (m.ncolors > 0)                      # per-face colour palette
		if _has_inmem_texture()                 # in-memory (gap #1): no temp PNG, survives re-render
			palimg = F3D.f3d_image_new_params(Cuint(m.ncolors), Cuint(1), Cuint(3), F3D.BYTE)
			GC.@preserve m F3D.f3d_image_set_content(palimg, pointer(m.palette))
			F3D.f3d_window_set_color_texture(window, palimg)   # copies content into the renderer
			F3D.f3d_image_delete(palimg)
		else
			pp = write_palette_png(m.palette, m.ncolors)
			F3D.f3d_options_set_as_string(opts, "model.color.texture", pp)
			push!(tmp_files, pp)
		end
	end

	GC.@preserve m begin
		nrm = isempty(m.normals)   ? C_NULL : pointer(m.normals)
		tex = isempty(m.texcoords) ? C_NULL : pointer(m.texcoords)
		mesh = Ref(F3D.f3d_mesh_t(pointer(m.points), Csize_t(length(m.points)),
		                          nrm,               Csize_t(length(m.normals)),       # per-vertex normals
		                          tex,               Csize_t(length(m.texcoords)),     # texcoords -> colour
		                          pointer(m.sides),  Csize_t(length(m.sides)),
		                          pointer(m.indices),Csize_t(length(m.indices))
		                          ))

		err = Ref{Cstring}(C_NULL)
		if (F3D.f3d_mesh_is_valid(mesh, err) != 1)
			msg = err[] == C_NULL ? "unknown" : unsafe_string(err[])
			err[] != C_NULL && F3D.f3d_utils_string_free(err[])
			F3D.f3d_engine_delete(engine)
			error("generated mesh is invalid: $msg")
		end
		(err[] != C_NULL) && F3D.f3d_utils_string_free(err[])

		F3D.f3d_scene_add_mesh(scene, mesh) == 1 || error("f3d_scene_add_mesh failed")
	end

	isempty(lights) || add_lights!(scene, lights)

	println(title, ": ", length(m.points) ÷ 3, " vertices, ", length(m.sides),
			" faces, ", m.ncolors, " colours, ", length(lights), " lights")

	# Top-down map view: parallel (orthographic) projection + camera straight above,
	# north (+Y) up. No perspective distortion, so the saved frame maps linearly onto
	# the grid x/y range -> can be georeferenced back in GMT (mat2img with the range).
	topdown && F3D.f3d_options_set_as_bool(opts, "scene.camera.orthographic", Cint(1))

	camera = F3D.f3d_window_get_camera(window)
	F3D.f3d_camera_reset_to_bounds(camera, topdown ? 1.0 : 0.9)
	if topdown
		fp = zeros(Cdouble, 3);  F3D.f3d_camera_get_focal_point(camera, fp)
		ps = zeros(Cdouble, 3);  F3D.f3d_camera_get_position(camera, ps)
		d  = hypot(ps[1]-fp[1], ps[2]-fp[2], ps[3]-fp[3])
		F3D.f3d_camera_set_position(camera, [fp[1], fp[2], fp[3] + d])   # straight above
		F3D.f3d_camera_set_view_up(camera, [0.0, 1.0, 0.0])             # north up
		F3D.f3d_camera_reset_to_bounds(camera, 1.0)                     # reframe top-down
		# reset_to_bounds fits the bounding SPHERE (Z relief inflates its radius) -> data
		# smaller than frame -> black border. Calibrate empirically: render once on a magenta
		# sentinel bg, measure how far the data falls short of each edge, then zoom IN by that
		# factor so the data fills the frame exactly (no border, no crop). min() over both
		# axes guarantees we never over-zoom into a crop.
		F3D.f3d_options_set_as_double_vector(opts, "render.background.color", Cdouble[1.0, 0.0, 1.0], Csize_t(3))
		F3D.f3d_window_render(window)
		cimg = F3D.f3d_window_render_to_image(window, Cint(0))
		cw = Int(F3D.f3d_image_get_width(cimg));  ch = Int(F3D.f3d_image_get_height(cimg))
		nc = Int(F3D.f3d_image_get_channel_count(cimg))
		buf = unsafe_wrap(Array, Ptr{UInt8}(F3D.f3d_image_get_content(cimg)), cw * ch * nc)
		issent(x, y) = (p = ((y * cw + x) * nc) + 1;                    # row-major from origin
						buf[p] > 240 && buf[p+1] < 15 && buf[p+2] > 240)
		x0 = cw; x1 = -1; y0 = ch; y1 = -1
		@inbounds for y in 0:ch-1, x in 0:cw-1
			issent(x, y) && continue
			x < x0 && (x0 = x);  x > x1 && (x1 = x);  y < y0 && (y0 = y);  y > y1 && (y1 = y)
		end
		F3D.f3d_image_delete(cimg)
		if x1 >= x0 && y1 >= y0
			f = min(cw / (x1 - x0 + 1), ch / (y1 - y0 + 1))            # fill factor, no crop
			f > 1.0001 && F3D.f3d_camera_zoom(camera, Cdouble(f))
		end
		bgc2 = Cdouble[bg[1], bg[2], bg[3]]                            # restore real background
		F3D.f3d_options_set_as_double_vector(opts, "render.background.color", bgc2, Csize_t(3))
	end
	azimuth   == 0 || F3D.f3d_camera_azimuth(camera, Cdouble(azimuth))      # orbit horizontally
	elevation == 0 || F3D.f3d_camera_elevation(camera, Cdouble(elevation))  # tilt for oblique view
	F3D.f3d_window_render(window)            # first render

	# Labelled cube axes with coordinates in EVERY figure — incl. offscreen / saveimg
	# exports (enabled here, before the frame grab, not only on the interactive path).
	# Needs the f3d_ext DLL; on a stock binary it is silently skipped.
	if (cube_axes && _has_f3d_ext())
		# Floor plane is OFF by default (it is semi-transparent and, where the relief is flat
		# at z=zmin, reads THROUGH the surface). `floor=true` turns it back on — the caller's
		# choice. Edges + tick labels always on.
		F3D.f3d_ext_enable_cube_axes(window; floor = floor)
		F3D.f3d_window_render(window)
	end

	# Rotation-centre gizmo (Fledermaus scale handle: compass / tilt rings + cone) in EVERY
	# figure incl. offscreen / saveimg exports — enabled here, before the frame grab, so it
	# is captured (it is ALSO re-asserted on the interactive path via _enable_extras, which is
	# idempotent: f3d_ext_enable_scale_handle tears down any prior gizmo first). The live-only
	# extras (coord readout, vscale drag) stay out of static exports. Needs the f3d_ext DLL.
	if (scale_handle && _has_f3d_ext())
		F3D.f3d_ext_enable_scale_handle(window, opts, Cdouble(vscale_step))
		F3D.f3d_window_render(window)
	end

	# Colour scale (right edge): `colorbar` is a NamedTuple (rgb, n, vmin, vmax[, title,
	# fmt]) built by the caller from the colouring palette + value range. In every
	# figure incl. offscreen exports. Needs the f3d_ext DLL.
	if (colorbar !== nothing && _has_f3d_ext())
		F3D.f3d_ext_enable_colorbar(window, colorbar.rgb, colorbar.n, colorbar.vmin, colorbar.vmax,
		                            get(colorbar, :title, ""), get(colorbar, :fmt, "%.1f"))
		F3D.f3d_window_render(window)
	end

	# Line overlays drawn ON TOP (coastlines/tracks/contours). In every figure incl.
	# offscreen exports. `line_zfac` matches the surface's vertical scale. Needs f3d_ext.
	_draw_lines(window, lines, line_color, line_width, line_zfac)

	if !isempty(saveimg)                        # grab the rendered frame to a file
		img = F3D.f3d_window_render_to_image(window, Cint(0))
		if ((georef !== nothing) && (lowercase(splitext(saveimg)[2]) == ".tiff"))
			# GeoTIFF: build a georeferenced GMTimage from the IN-MEMORY frame and gmtwrite it
			# (GDAL GTiff). We never gmtread the output -> no Windows file lock. VTK's frame
			# origin is bottom-left, so flip rows to north-up; pixels are RGB(A)-interleaved.
			cw = Int(F3D.f3d_image_get_width(img));  ch = Int(F3D.f3d_image_get_height(img))
			nc = Int(F3D.f3d_image_get_channel_count(img))
			buf = unsafe_wrap(Array, Ptr{UInt8}(F3D.f3d_image_get_content(img)), cw * ch * nc)
			A = Array{UInt8}(undef, ch, cw, 3)   # (rows=lat north->south, cols=lon west->east)
			@inbounds for j in 1:ch, i in 1:cw
				base = ((ch - j) * cw + (i - 1)) * nc      # VTK row (ch-j) = north when j=1
				A[j, i, 1] = buf[base + 1];  A[j, i, 2] = buf[base + 2];  A[j, i, 3] = buf[base + 3]
			end
			Inew = GMT.mat2img(A; x=[Float64(georef[1]), Float64(georef[2])], y=[Float64(georef[3]), Float64(georef[4])])
			pj = String(georef[5])
			isempty(pj) || (occursin("+", pj) ? (Inew.proj4 = pj) : (Inew.wkt = pj))
			GMT.gmtwrite(saveimg, Inew)
		else
			F3D.f3d_image_save(img, saveimg, savefmt)
		end
	end

	if offscreen
		for f in tmp_files; rm(f; force=true); end   # drape temp PNGs (none if in-memory palette)
		F3D.f3d_engine_delete(engine)
		return nothing
	end

	interactor = F3D.f3d_engine_get_interactor(engine)
	F3D.f3d_interactor_init_commands(interactor)
	F3D.f3d_interactor_init_bindings(interactor)
	_disable_raytracing_bindings(interactor)   # live RT pins CPU + freezes window; offscreen RT still ok
	# Extended interactions (need a rebuilt f3d_ext DLL): labelled cube axes,
	# coordinate readout, Ctrl+left-drag vertical exaggeration. Enabled after the
	# render above so the cube axes can capture the data bounds.
	disable_extras = _enable_extras(window, opts; cube_axes=cube_axes,   # re-assert (idempotent)
	                                coord_readout=coord_readout, vscale_drag=vscale_drag,
                                    vscale_step=vscale_step, scale_handle=scale_handle,
                                    colorbar=colorbar, cube_floor=floor)	# swap the static bar for a draggable one
	_handle_chan === nothing || put!(_handle_chan, interactor)	# async: let the REPL close! us
	_interactor_start_gcsafe(interactor, 1.0 / 30.0)			# blocks until window closed (GC-safe)

	# f3d's start() registers a repeating Win32 timer but does NOT kill it when the loop
	# exits (only stop() does) -> a stray WM_TIMER can hit vtkWin32RenderWindowInteractor::
	# OnTimer on a half-torn-down interactor => EXCEPTION_ACCESS_VIOLATION on close. Stop
	# the interactor first (DestroyTimer) before tearing the scene/engine down.
	F3D.f3d_interactor_stop(interactor)
	disable_extras()
	(colorbar !== nothing) && _has_f3d_ext() && F3D.f3d_ext_disable_colorbar(window)
	(lines === nothing) || !_has_f3d_ext() || F3D.f3d_ext_clear_lines(window)
	for f in tmp_files; rm(f; force=true); end   # delete drape temp PNGs only now (window closed)
	F3D.f3d_scene_clear(scene)        # drop actors before GL teardown -> avoids close-time AV in engine_delete
	F3D.f3d_engine_delete(engine)
	return nothing
end

# ---------------------------------------------------------------------------
# Demo helper: colour a solid's faces with a hue ramp keyed on face-centroid z,
# filling `fv.color` with GMT "-G#rrggbb" strings so view_fv has colours to show.
# ---------------------------------------------------------------------------
function colorize_by_z!(fv::GMT.GMTfv)
	V = fv.verts
	zmin, zmax = extrema(@view V[:, 3])
	span = (zmax > zmin) ? (zmax - zmin) : 1.0
	fv.color = Vector{Vector{String}}(undef, length(fv.faces))
	for (g, Fm) in enumerate(fv.faces)
		if isempty(Fm)
			fv.color[g] = String[];  continue
		end
		nf, npf = size(Fm)
		cols = Vector{String}(undef, nf)
		for r in 1:nf
			zc = sum(V[Fm[r, c], 3] for c in 1:npf) / npf
			t  = (zc - zmin) / span
			# simple blue -> red ramp
			rr = round(Int, 255 * t);  bb = round(Int, 255 * (1 - t));  gg = round(Int, 80 + 100 * (1 - abs(2t - 1)))
			cols[r] = string("-G#", lpad(string(rr, base=16), 2, '0'),
			                        lpad(string(gg, base=16), 2, '0'),
			                        lpad(string(bb, base=16), 2, '0'))
		end
		fv.color[g] = cols
	end
	return fv
end

# Default demo profiles for the parametric generators (used when the caller gives none).
_demo_revolve_curve() = (x = collect(range(0, 2pi, length=15)) .+ 1; [x zeros(length(x)) -cos.(x)])
function _demo_loft_curves()                       # circle base -> 6-lobe star top
	t = range(0, 2pi, 75);  r = 5.0
	C1 = [r .* cos.(t) r .* sin.(t) zeros(length(t))]
	f  = tt -> r + 2.0 * sin(6tt)
	C2 = stack([(f(tt) * cos(tt), f(tt) * sin(tt), 3.0) for tt in t])'
	return C1, C2
end
function _demo_extrude_shape()                     # 5-point star outline (Mx2)
	a  = range(pi/2, 2pi + pi/2, 11)[1:10]
	rr = [isodd(k) ? 2.0 : 0.8 for k in 1:10]
	return [rr .* cos.(a) rr .* sin.(a)]
end

# Catalogue of solids. Each entry forwards to its GMT generator, PASSING THROUGH every
# kwarg untouched so the generator's OWN defaults stand (we never restate them here). An
# optional positional argument uses a `missing` sentinel: omit it and the generator's
# default is used; give it and it is passed positionally. Only a generator with a
# REQUIRED positional that has no default (cylinder r/h, revolve curve, loft C1/C2,
# extrude shape/h) carries a demo value — that is sample data, not a default override.
# f3dview routes a kwarg here when it is NOT one of the viewer's keywords (see f3dview).
const SOLIDS = Dict{String,Function}(
	# closed primitives — `r` (optional) is the circumradius (centre→vertex), not the side
	"icosahedron" => (; r=missing, kw...) -> ismissing(r) ? icosahedron(; kw...) : icosahedron(r; kw...),
	"octahedron"  => (; r=missing, kw...) -> ismissing(r) ? octahedron(; kw...)  : octahedron(r; kw...),
	"dodecahedron"=> (; r=missing, kw...) -> ismissing(r) ? dodecahedron(; kw...) : dodecahedron(r; kw...),
	"tetrahedron" => (; r=missing, kw...) -> ismissing(r) ? tetrahedron(; kw...) : tetrahedron(r; kw...),
	"cube"        => (; r=missing, kw...) -> ismissing(r) ? cube(; kw...)        : cube(r; kw...),
	"sphere"      => (; r=missing, kw...) -> ismissing(r) ? sphere(; kw...)      : sphere(r; kw...),
	"torus"       => (; kw...)            -> torus(; kw...),                       # all-keyword
	# generators / required positionals — demo SAMPLE data only; optional kwargs pass through
	"cylinder"    => (; r=1.0, h=3.0, kw...)                -> cylinder(r, h; kw...),
	"revolve"     => (; curve=_demo_revolve_curve(), kw...) -> revolve(curve; kw...),
	"loft"        => (; C1=_demo_loft_curves()[1], C2=_demo_loft_curves()[2], kw...) -> loft(C1, C2; kw...),
	"extrude"     => (; shape=_demo_extrude_shape(), h=1.0, kw...) -> extrude(shape, h; kw...),
)

# ===========================================================================
# poly2fv — fold closed polygons into a GMTfv, ONE face per polygon, any corner
# count. Generalises `tri2fv` (triangles only) to quads / n-gons: `fv_to_mesh`
# already renders arbitrary-sided faces, so n-gons need NO triangulation — VTK
# tessellates each convex, planar cell at render. `triangulate=true` fan-splits
# every polygon into triangles first (vertex-1 fan) for concave / strongly
# non-planar polygons where the single-cell fill would look wrong. Vertices are
# split per face (never shared), so per-face colour is trivial; faces are coloured
# by their mean z through `cmap`, exactly like `tri2fv`. Faces of different corner
# counts go into separate GMTfv face groups (the format needs one fixed width per
# group); fv_to_mesh iterates groups, so a mix renders fine.
# ===========================================================================

"""
    poly2fv(D::Vector{<:GMTdataset}; cmap=:turbo, zscale=:auto, vfrac=0.2,
            vexag=:auto, isgeog=false, ncolor=256, triangulate=false) -> GMTfv

Fold a vector of **closed 3-D polygons** into a single coloured `GMTfv` ready for
[`view_fv`](@ref) — one mesh face per polygon, any corner count (triangles, quads,
n-gons). Each polygon needs `x y z` columns; a repeated closing vertex is dropped.
This is what [`f3dview`](@ref) calls for polygon `GMTdataset`s.

Faces are coloured by their mean *z* through the GMT colormap `cmap` (`ncolor`
levels); colours always key off the **true** (unscaled) *z*. Vertical scale follows
the same geog-aware `:auto` logic as [`view_grid`](@ref) (`zscale`, `vfrac`, `vexag`,
`isgeog`); pass a number for `zscale` to override (e.g. `zscale=1` for raw 1:1).

Polygons of different corner counts are placed in separate `GMTfv` face groups (the
format needs one fixed width per group), which the renderer handles transparently.
By default an n-gon is rendered as a single cell (VTK tessellates each convex, planar
face at render time); pass `triangulate=true` to fan-split every polygon into
triangles first — needed for concave or strongly non-planar polygons where the
single-cell fill would look wrong.

E.g. `view_fv(poly2fv(GMT.gmtread("countries.gmt")))`.
"""
function poly2fv(D::Vector{<:GMT.GMTdataset}; cmap=:turbo, zscale=:auto,
				 vfrac=0.2, vexag=:auto, isgeog::Bool=false, ncolor::Int=256,
				 triangulate::Bool=false)
	isempty(D) && error("no polygons to render")
	faces_xyz = Matrix{Float64}[]                    # one matrix of corner xyz per face
	for d in D
		P = Matrix{Float64}(d.data)
		size(P, 2) >= 3 || error("polygon needs 3-D vertices (x y z); got $(size(P,2)) columns")
		(size(P, 1) >= 2 && @views P[1, 1:3] == P[end, 1:3]) && (P = P[1:end-1, :])  # drop closing dup
		size(P, 1) >= 3 || continue
		if triangulate                               # fan from vertex 1: (1, t, t+1)
			for t in 2:size(P, 1)-1
				push!(faces_xyz, P[[1, t, t + 1], :])
			end
		else
			push!(faces_xyz, P)
		end
	end
	nf = length(faces_xyz)
	nf == 0 && error("no usable polygon faces (need >= 3 vertices each)")
	ncorners = sum(size(P, 1) for P in faces_xyz)
	V  = Matrix{Float64}(undef, ncorners, 3)
	zc = Vector{Float64}(undef, nf)                  # per-face mean z (true, for colour)
	buckets = Dict{Int,Vector{Tuple{Int,Vector{Int}}}}()   # npf -> [(faceidx, [vert ids])]
	vi = 0
	for (k, P) in enumerate(faces_xyz)
		np  = size(P, 1)
		row = Vector{Int}(undef, np)
		zsum = 0.0
		for c in 1:np
			vi += 1
			V[vi, 1] = P[c, 1];  V[vi, 2] = P[c, 2];  V[vi, 3] = P[c, 3]
			row[c] = vi;  zsum += P[c, 3]
		end
		zc[k] = zsum / np
		push!(get!(buckets, np, Tuple{Int,Vector{Int}}[]), (k, row))
	end
	xmin, xmax = extrema(@view V[:, 1]);  ymin, ymax = extrema(@view V[:, 2])
	zmin, zmax = extrema(@view V[:, 3])
	s = _resolve_zscale(zscale, xmax - xmin, ymax - ymin, zmax - zmin, vfrac, isgeog, vexag)
	s == 1.0 || (@inbounds @views V[:, 3] .*= s)     # apply vertical scale to geometry
	czmin, czmax = extrema(zc)                        # colour range from true z
	# A flat slab (all faces equal mean-z) gives czmin == czmax -> makecpt errors
	# "min >= max"; widen to a unit window so every face lands on the mid colour.
	czmax > czmin || (czmin -= 0.5;  czmax += 0.5)
	step = (czmax - czmin) / ncolor
	cm = GMT.makecpt(cmap = string(cmap), range = (czmin, czmax, step)).colormap
	faces = Matrix{Int}[];  colors = Vector{Vector{String}}()
	for npf in sort(collect(keys(buckets)))          # one group per distinct corner count
		rows = buckets[npf];  m = length(rows)
		Fm = Matrix{Int}(undef, m, npf);  col = Vector{String}(undef, m)
		for (j, (gk, row)) in enumerate(rows)
			@inbounds for c in 1:npf;  Fm[j, c] = row[c];  end
			col[j] = string("-G", z_to_hex(zc[gk], cm, czmin, czmax))
		end
		push!(faces, Fm);  push!(colors, col)
	end
	bb = Float64[xmin, xmax, ymin, ymax, extrema(@view V[:, 3])...]
	return GMT.GMTfv(verts = V, faces = faces, color = colors, bbox = bb, isflat = fill(false, length(faces)))
end
