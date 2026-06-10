# GMTF3D — view_points: coloured point clouds with rubber-band selection.

# ---------------------------------------------------------------------------
# Point clouds: a GMTdataset (N x >=3 table) -> F3D point cloud, coloured by a
# data column (z depth by default) through a GMT colormap.
#
# F3D has no per-point scalar/colour array on the mesh struct, so colour goes the
# same route as faces: a 1 x ncolor palette texture + one u-texcoord per point
# (v=0.5) pointing at its colour's texel. The mesh is built with EMPTY sides /
# indices, which libf3d renders as a pure point cloud (vertices only); points are
# drawn as round sprites (`model.point_sprites`) sized by `pointsize`.
# ---------------------------------------------------------------------------

# Rubber-band pick plumbing (needs an f3d built with c/f3d_ext_*.cxx; absent in the
# stock DLL). The C side calls back with the selected point ids; `_pick_trampoline`
# is the @cfunction target (a NAMED top-level fn, so @cfunction accepts it) and reads
# the active Julia callback. ids are 0-based VTK -> +1 for Julia rows.
#
# State lives in LAZILY-created module globals, NOT top-level `const`: a partial
# Revise / `includet` reload updates changed methods but refuses to re-create a
# `const`, so the new method body would reference an unbound name (the UndefVarError
# seen on window close). Creating the Refs on first use is reload-proof.
_pick_onpick() = (@isdefined(_PICK_ONPICK) || (global _PICK_ONPICK = Ref{Any}(nothing)); _PICK_ONPICK)
_pick_cbref()  = (@isdefined(_PICK_CBREF)  || (global _PICK_CBREF  = Ref{Any}(nothing)); _PICK_CBREF)
function _pick_trampoline(ids::Ptr{Csize_t}, n::Csize_t, ::Ptr{Cvoid})::Cvoid
	f = _pick_onpick()[]
	f === nothing && return nothing
	try
		sel = n == 0 ? Int[] : Int.(unsafe_wrap(Array, ids, Int(n))) .+ 1
		f(sel)
	catch e
		@warn "onpick callback threw" exception=(e, catch_backtrace())
	end
	return nothing
end

function _arm_pick(window, onpick, pickcolor=(0.83, 0.83, 0.83))
	onpick === nothing && return false
	h = Libdl.dlopen(F3D.libf3d)
	sym = Libdl.dlsym(h, :f3d_ext_enable_rubber_band_pick; throw_error=false)
	if sym === nothing
		@warn "onpick ignored: this f3d build has no f3d_ext (rebuild f3d with c/f3d_ext_*.cxx)"
		return false
	end
	r, g, b = _color01(pickcolor)
	cb = @cfunction(_pick_trampoline, Cvoid, (Ptr{Csize_t}, Csize_t, Ptr{Cvoid}))
	ok = ccall(sym, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cdouble, Cdouble, Cdouble),
			   window, cb, C_NULL, Cdouble(r), Cdouble(g), Cdouble(b))
	ok == 1 || return false
	_pick_onpick()[] = onpick           # what the trampoline calls
	_pick_cbref()[]  = cb               # keep the @cfunction alive (GC guard)
	return true
end

"""
	view_points(D; kwargs...)

Show a `GMTdataset` (an `N x >=3` table of `x y z [...]`) as a 3-D point cloud in
F3D, colouring each point by a data column through a GMT colormap. Blocks until
the window is closed (unless `offscreen`).

# Colour
- `color=:z`: which value drives the colour — `:z` (column 3, depth, the default),
  or a column index `Int` (`1`=x, `2`=y, ...), or a length-`N` vector of values.
  Continuous (ramp) colouring.
- `class=nothing`: nominal sibling of `color` — same source forms, but flags the
  values as discrete CLASSES (implies `categorical=true` and the qualitative
  `:categorical` cmap). Use for labels/IDs, not continuous data.
- `cmap=nothing`: GMT colormap name. `nothing` picks `:categorical` when classed,
  else `:turbo`.
- `categorical=false`: force discrete-class painting (one solid colour per value,
  no ramp, no colour bar). Set implicitly by `class`.
- `ncolor=256`: palette resolution (continuous) / becomes #classes (categorical).
- `clim=nothing`: `(lo, hi)` colour limits; `nothing` = data min/max.

# Points
- `pointsize=1`: point size in pixels (`1` = true single-pixel points).
- `sprites=false`: when `true`, draw round splats coloured by value (gap #9). The
  sprite mapper ignores texture coords, so per-point colour is baked on via
  `f3d_ext_color_point_sprites` — REQUIRES an f3d built with `c/f3d_ext_*.cxx`; on a
  stock DLL the splats render uniform grey (a warning is shown).
- `splat="sphere"`: sprite shape — `"sphere"` (shaded disc), `"circle"` (flat ring),
  or `"gaussian"` (soft, can look fuzzy/dark over a dark bg). Only with `sprites=true`.

# Vertical scale (same geog-aware logic as `view_grid`)
- `zscale=:auto`: `:auto` sets a sensible flat slab so x,y and z are never on the
  same raw scale — geographic data (`GMT.isgeog`) gets a true 1:1 metres→degrees
  scale times `vexag`; non-geographic uses the `vfrac` heuristic. A number
  overrides (e.g. `zscale=1` for raw 1:1). Colours always key off the true z.
- `vexag=:auto`: vertical exaggeration multiplier (geographic `:auto` only).
- `vfrac=0.2`: target relief height as a fraction of the xy span (non-geographic).
- `isgeog=nothing`: force geographic on/off; `nothing` = autodetect via `GMT.isgeog(D)`.

# View / export (as in `view_fv`)
- `title`, `size=(1200,1000)`, `bg=(0.1,0.1,0.15)`, `lights=()`.
- `async=true`: viewer on a worker thread → REPL gets a `ViewHandle` at once;
  `false` blocks until the window closes (and returns the selection).
- `axes=true`, `grid=true`: orientation gizmo / f3d floor grid.
- `azimuth=-40`, `elevation=25`: orbit / tilt the camera (degrees).
- `offscreen=false`, `saveimg=""`: render without a window / save the frame
  (format from extension: png/jpg/tif/bmp).

# Extended interactions (need an f3d built with `c/f3d_ext_*.cxx`; a stock DLL warns
# and ignores them)
- `cube_axes=true`: labelled bounding-box (X/Y/Z tick) axes with coords (default on).
- `coord_readout=true`: live world X/Y/Z under the cursor (bottom-left).
- `vscale_drag=true`: Ctrl+left-drag to exaggerate / flatten the relief
  (`vscale_step=0.01` per pixel).
- `colorbar=true`: colour scale on the right edge (continuous colouring only — off
  for the categorical/class path).
- `up="+Z"`: scene up-direction (`"+Z"` lays z-up data flat).

# Interactive selection (rubber-band) — always on, Ctrl+right-drag
- **Ctrl+right-drag** a box to select points (Ctrl+Z undoes, re-dragging the same box
  deselects); plain right-drag stays normal navigation. The selected points are kept
  for you — read them back with `selection(h)` (async) or from the return value
  (`async=false`); both give a `GMTdataset` of the picked rows. No option, no callback.
  REQUIRES an f3d built with `c/f3d_ext_*.cxx`. Interactive only.
  E.g. `h = view_points(D); ... ; sel = selection(h)`.
- `onpick=nothing`: for full control, pass `f(rows::Vector{Int})` instead — called with
  the selected row indices into `D.data` on every change (replaces the default stash).
- `pickcolor=(0.83,0.83,0.83)`: recolour applied IN PLACE to the selected points (light grey
  by default). Accepts an RGB tuple in `[0,1]`, a 0-255 triplet, or a colour name/`"#hex"`/gray
  number (as in `fill`).
  TODO: instead of a fixed grey, derive the colour MOST DISTINCT from those present in the
  active colour scale (`pal`) so the selection always pops regardless of the cmap — e.g. the
  max-min CIELAB-distance colour, or the palette's complementary. Compute from `pal` here and
  pass it through the existing `pickcolor` plumbing. (Matching TODO in f3d_ext_interactor.cxx.)

E.g. `view_points(D)`, `view_points(D; cmap=:roma)`, `view_points(D; vexag=10)`.

`async=true` (default) runs the viewer on a worker thread and hands the REPL back a
`ViewHandle` at once (`close!(h)` to shut it); `async=false` blocks until the window
closes and returns the selection.
"""
function view_points(D::GMT.GMTdataset; async::Bool=true, onpick=nothing, kwargs...)
	# Ctrl+right-drag box-select is ALWAYS on (no option). By default the picked points
	# are stashed for you — read them back with `selection(h)` (async) or the return value
	# (`async=false`). A custom `onpick=f` overrides the default stash.
	selref = Ref{Any}(nothing)
	# Default sink runs on the viewer's WORKER thread, so it must NOT touch GMT (not
	# thread-safe -> hard process crash). Stash a plain matrix copy; `selection(h)` wraps
	# it in a GMTdataset on the main thread.
	cb = onpick !== nothing ? onpick :
		 (rows -> (selref[] = isempty(rows) ? nothing : D.data[rows, :]))
	if async && !get(kwargs, :offscreen, false)   # offscreen has no window -> nothing to hand back
		return _async_view(ch -> _view_points_impl(D; _handle_chan=ch, onpick=cb, kwargs...); sel=selref)
	else
		_view_points_impl(D; onpick=cb, kwargs...)
		return selref[]                            # sync: hand back the selection on close
	end
end

function _view_points_impl(D::GMT.GMTdataset; _handle_chan=nothing, color=:z, class=nothing, cmap=nothing, ncolor::Int=256,
					 clim=nothing, categorical::Bool=false, pointsize::Real=1, sprites::Bool=false,
					 splat::AbstractString="sphere", spritesize::Real=10.0,
					 zscale=:auto, vfrac=0.2, vexag=:auto, isgeog=nothing,
					 title::AbstractString="F3D — point cloud",
					 size::Tuple{Int,Int}=(1200, 1000), bg=(0.1, 0.1, 0.15), lights=(),
					 axes::Bool=true, grid::Bool=true, offscreen::Bool=false,
					 saveimg::String="", azimuth::Real=-40.0, elevation::Real=25.0,
					 up="+Z", cube_axes::Bool=true, coord_readout::Bool=true,
					 vscale_drag::Bool=true, vscale_step::Real=0.01, scale_handle::Bool=true, colorbar::Bool=true,
					 onpick=nothing, pickcolor=(0.83, 0.83, 0.83),
					 lines=nothing, line_color=nothing, line_width::Real=2.0, L=nothing)
	lines = L === nothing ? lines : L          # `L` = GMT-style short alias for `lines`
	A = D.data
	N = Base.size(A, 1)
	N == 0 && error("dataset has no points")
	Base.size(A, 2) >= 3 || error("dataset needs at least 3 columns (x y z); got $(Base.size(A,2))")

	# `class` is the nominal sibling of `color`: passing it picks the source AND implies
	# categorical painting with the qualitative `:categorical` cmap (user can still override
	# `cmap`). `color` stays the continuous path.
	src = class === nothing ? color : class
	class === nothing || (categorical = true)
	cmap === nothing && (cmap = categorical ? :categorical : :turbo)

	# source: a column index / :z, an N-vector, a one-column matrix, or a GMTdataset.
	# Keep a VIEW (no copy) — the continuous path promotes in its own arithmetic, the
	# categorical path only needs unique/lookup. `vec` on an Nx1 matrix is a reshape view.
	cv = src isa GMT.GMTdataset ? src.data : src
	cvals = cv isa AbstractVector ? cv :
			cv isa AbstractMatrix  ? (GMT.isvector(cv) ? vec(cv) :
									  error("`color`/`class` matrix/dataset must be a single column; got size $(Base.size(cv))")) :
			@view A[:, cv === :z ? 3 : Int(cv)]
	length(cvals) == N || error("`color`/`class` length $(length(cvals)) != $N points")
	cmin, cmax = clim === nothing ? extrema(cvals) : (float(clim[1]), float(clim[2]))
	span = cmax > cmin ? cmax - cmin : 1.0

	# Vertical scale — SAME geog-aware logic as view_grid/tri2fv (`_resolve_zscale`):
	# `:auto` makes a sensible flat slab (geog: 1:1 metres->degrees x `vexag`; else the
	# `vfrac` heuristic), so x,y and z are NEVER on the same raw scale. A number overrides.
	xmn, xmx = extrema(@view A[:, 1]);  ymn, ymx = extrema(@view A[:, 2])
	zmn, zmx = extrema(@view A[:, 3])
	geo = isgeog === nothing ? GMT.isgeog(D) : Bool(isgeog)
	s   = Float32(_resolve_zscale(zscale, xmx - xmn, ymx - ymn, zmx - zmn, vfrac, geo, vexag))

	pts = Vector{Float32}(undef, 3N)
	tc  = Vector{Float32}(undef, 2N)
	if categorical
		# Nominal classes (e.g. LIDAR ASPRS): one distinct colour per unique value, no
		# ramp. ncolor := #classes; each point's texel = its class index. GMT builds the
		# discrete palette (`makecpt ... categorical=true`); `cmap=:categorical` is a good default.
		u       = sort(unique(cvals))
		ncolor  = length(u)
		cls2idx = Dict(c => k for (k, c) in enumerate(u))
		@inbounds for i in 1:N
			pts[3i-2] = A[i, 1];  pts[3i-1] = A[i, 2];  pts[3i] = A[i, 3] * s
			k = cls2idx[cvals[i]]
			tc[2i-1] = Float32((k - 0.5) / ncolor)      # texel centre of this class
			tc[2i]   = 0.5f0
		end
		pal = cmap_palette(cmap, ncolor; categorical=true)
		println("  classes: ", join(string.(u), ", "))
	else
		@inbounds for i in 1:N
			pts[3i-2] = A[i, 1];  pts[3i-1] = A[i, 2];  pts[3i] = A[i, 3] * s
			t = clamp((cvals[i] - cmin) / span, 0.0, 1.0)
			tc[2i-1] = Float32(clamp((floor(t * ncolor) + 0.5) / ncolor, 0.0, 1.0))   # texel centre
			tc[2i]   = 0.5f0
		end
		pal = cmap_palette(cmap, ncolor)
	end

	# Coloured ROUND sprites (gap #9): vtkPointGaussianMapper ignores the palette
	# texture, so for sprites we bake a per-point RGB array (same palette index the
	# texcoord encodes) and hand it to f3d_ext_color_point_sprites after the first
	# render. `splat` ("sphere"/"circle"/"gaussian") picks the splat SHAPE.
	# Bake the RGB even when starting as a PLAIN point cloud (sprites=false): the sprite
	# actor exists (hidden) from the start, so seeding its colour now lets the C side cache
	# it — otherwise the first 'o' key (enable sprites) shows uncoloured grey splats because
	# f3d wipes the colour array before our re-assert observer ever sees it (see
	# f3d_ext_color_point_sprites / reassertSpriteColors).
	rgb = UInt8[]
	if _has_f3d_ext()
		rgb = Vector{UInt8}(undef, 3N)
		@inbounds for i in 1:N
			row = clamp(floor(Int, tc[2i-1] * ncolor) + 1, 1, ncolor)   # 1-based palette row
			o = 3 * (row - 1)
			rgb[3i-2] = pal[o+1];  rgb[3i-1] = pal[o+2];  rgb[3i] = pal[o+3]
		end
	end

	savefmt = F3D.PNG
	isempty(saveimg) || ((saveimg, savefmt) = _img_target(saveimg))

	F3D.f3d_engine_autoload_plugins()
	engine = F3D.f3d_engine_create(Cint(offscreen ? 1 : 0))
	engine == C_NULL && error("failed to create F3D engine")
	scene  = F3D.f3d_engine_get_scene(engine)
	window = F3D.f3d_engine_get_window(engine)
	F3D.f3d_window_set_size(window, Cint(size[1]), Cint(size[2]))
	_place_window(window, size)
	F3D.f3d_window_set_window_name(window, title)

	opts = F3D.f3d_engine_get_options(engine)
	# `up`: scene up-direction. set_as_string_representation (NOT set_as_string -> crashes
	# on the `direction` option type).
	up === nothing || F3D.f3d_options_set_as_string_representation(opts, "scene.up_direction", string(up))
	F3D.f3d_options_set_as_bool(opts, "ui.scalar_bar", Cint(0))
	axes && F3D.f3d_options_set_as_bool(opts, "ui.axis", Cint(1))
	if grid
		F3D.f3d_options_set_as_bool(opts, "render.grid.enable", Cint(1))
		F3D.f3d_options_set_as_bool(opts, "render.grid.absolute", Cint(0))  # bbox bottom = cube axes floor
	end
	bgc = Cdouble[bg[1], bg[2], bg[3]]
	F3D.f3d_options_set_as_double_vector(opts, "render.background.color", bgc, Csize_t(3))
	F3D.f3d_options_set_as_bool(opts, "model.point_sprites.enable", Cint(sprites ? 1 : 0))
	sprites && F3D.f3d_options_set_as_string(opts, "model.point_sprites.type", splat)
	F3D.f3d_options_set_as_double(opts, "render.point_size", Cdouble(pointsize))
	# Sprite splat size (the `o` key cycles the TYPE but not the size; f3d's default 10 is
	# oversized). Set it always so cycling to a sprite shape looks right; Shift+/- adjusts live.
	F3D.f3d_options_set_as_double(opts, "model.point_sprites.size", Cdouble(spritesize))

	# Colour palette as a per-point scivis scalar + colormap on the zero-copy mesh_view:
	# no temp PNG, and it survives f3d's per-render option re-push (a PNG `model.color.
	# texture` would be re-read on every re-render — e.g. the Ctrl-drag vertical scale —
	# and break once its temp file is deleted).
	uscalar = Vector{Float32}(undef, N)            # palette position per point (the texcoord u)
	@inbounds for i in 1:N;  uscalar[i] = tc[2i-1];  end
	_set_scivis_palette!(opts, pal, ncolor, "color"; cells=false, range=(0.0, 1.0))
	add_mesh_view!(scene, engine, pts, Float32[], Float32[], UInt32[], UInt32[];
	               name="points", point_scalars=[mvscalar("color", uscalar)]) ||
		(F3D.f3d_engine_delete(engine); error("f3d_scene_add_mesh_view failed"))

	isempty(lights) || add_lights!(scene, lights)
	println(title, ": ", N, " points, ", ncolor, " colours")

	camera = F3D.f3d_window_get_camera(window)
	F3D.f3d_camera_reset_to_bounds(camera, 0.9)
	azimuth   == 0 || F3D.f3d_camera_azimuth(camera, Cdouble(azimuth))
	elevation == 0 || F3D.f3d_camera_elevation(camera, Cdouble(elevation))
	F3D.f3d_window_render(window)

	# Sprites ignore the palette texture -> push the per-point RGB onto the gaussian
	# mapper now that the sprite actor exists (after the first render). gap #9.
	if !isempty(rgb)
		GC.@preserve rgb begin
			ok = F3D.f3d_ext_color_point_sprites(window, pointer(rgb), N, 3)
			ok == 1 || @warn "f3d_ext_color_point_sprites did not apply (no sprite actor?)"
		end
		F3D.f3d_window_render(window)
	end

	# Labelled cube axes with coordinates in EVERY figure — incl. offscreen / saveimg
	# exports (enabled here, before the frame grab, not only on the interactive path).
	if cube_axes && _has_f3d_ext()
		F3D.f3d_ext_enable_cube_axes(window; floor = false)   # no see-through floor plane
		F3D.f3d_window_render(window)
	end

	# Rotation-centre gizmo before the frame grab so it lands in offscreen / saveimg exports
	# too (idempotently re-asserted on the interactive path via _enable_extras). Same as the
	# view_grid/_view_fv_impl path — keeps the two viewers' exports consistent.
	if scale_handle && _has_f3d_ext()
		F3D.f3d_ext_enable_scale_handle(window, opts, Cdouble(vscale_step))
		F3D.f3d_window_render(window)
	end

	# Colour scale keyed on the value range that drives the point colours. Skipped for
	# the categorical path (discrete classes, not a continuous ramp).
	if colorbar && !categorical && _has_f3d_ext()
		nd = _axis_decimals(cmax - cmin)
		F3D.f3d_ext_enable_colorbar(window, pal, ncolor, cmin, cmax, "", "%.$(nd)f")
		F3D.f3d_window_render(window)
	end

	# Line overlays drawn ON TOP of the cloud. `s` is the SAME vertical scale applied to
	# the points, so a line's z (data units) lands at the cloud's level. Needs f3d_ext.
	_draw_lines(window, lines, line_color, line_width, s)

	if !isempty(saveimg)
		img = F3D.f3d_window_render_to_image(window, Cint(0))
		F3D.f3d_image_save(img, saveimg, savefmt)
		F3D.f3d_image_delete(img)
	end

	if offscreen
		_mv_release!(engine)
		F3D.f3d_engine_delete(engine)
		return nothing
	end

	interactor = F3D.f3d_engine_get_interactor(engine)
	F3D.f3d_interactor_init_commands(interactor)
	F3D.f3d_interactor_init_bindings(interactor)
	_disable_raytracing_bindings(interactor)   # live RT pins CPU + freezes window; offscreen RT still ok
	# Extended interactions (need a rebuilt f3d_ext DLL): cube axes / coordinate
	# readout / vertical-scale drag. Enabled after the first render (cube axes needs
	# bounds). Point clouds are the right place for the rubber-band selector.
	# Hand the colour-bar palette to _enable_extras so it re-enables as a draggable widget
	# ('b' toggles it). Skipped on the categorical path (no continuous ramp), matching the
	# static bar above.
	cbar_nt = (colorbar && !categorical && _has_f3d_ext()) ?
		(rgb=pal, n=ncolor, vmin=cmin, vmax=cmax, fmt="%.$(_axis_decimals(cmax - cmin))f") : nothing
	disable_extras = _enable_extras(window, opts; cube_axes=cube_axes,   # re-assert (idempotent)
									coord_readout=coord_readout, vscale_drag=vscale_drag,
									vscale_step=vscale_step, scale_handle=scale_handle, colorbar=cbar_nt)
	# Shift+'+' / Shift+'-' grow / shrink the point sprites (the `o` key only cycles type;
	# plain '+'/'-' stay free for zoom).
	_has_f3d_ext() && F3D.f3d_ext_enable_sprite_size_keys(window, opts, Cdouble(spritesize))
	# Vertical scale distorts gaussian/sphere splats if applied as an actor transform; keep
	# the sprites at the model_scale z by baking coords instead (re-placed on the `o` toggle).
	_has_f3d_ext() && F3D.f3d_ext_enable_sprite_zscale_sync(window, opts)
	# `onpick` IS the rubber-band switch: pass it and the box-select is on; omit it and
	# there is no selector at all. Installed AFTER the interactor exists and active right
	# away -> right-drag a box selects; the C side calls back with the ids ->
	# _pick_trampoline -> onpick(rows). Ctrl+Z undoes / re-dragging the same box deselects.
	pick_on = _arm_pick(window, onpick, pickcolor)
	pick_on && println("  pick: Ctrl+right-drag a box to select (Ctrl+Z undo); selection(h) / return value gives the points")

	(_handle_chan === nothing) || put!(_handle_chan, interactor)   # async: let the REPL close! us
	_interactor_start_gcsafe(interactor, 1.0 / 30.0)    # blocks until window closed (GC-safe)
	F3D.f3d_interactor_stop(interactor)   # kill the event-loop timer -> no stray OnTimer AV on close
	pick_on && F3D.f3d_ext_disable_rubber_band_pick(window)
	_pick_onpick()[] = nothing;  _pick_cbref()[] = nothing
	_has_f3d_ext() && F3D.f3d_ext_disable_sprite_size_keys(window)
	_has_f3d_ext() && F3D.f3d_ext_disable_sprite_zscale_sync(window)
	disable_extras()
	colorbar && !categorical && _has_f3d_ext() && F3D.f3d_ext_disable_colorbar(window)
	(lines === nothing) || !_has_f3d_ext() || F3D.f3d_ext_clear_lines(window)
	F3D.f3d_scene_clear(scene)        # drop actors before GL teardown -> avoids close-time AV in engine_delete
	_mv_release!(engine)              # zero-copy buffers safe to drop only after scene cleared
	F3D.f3d_engine_delete(engine)
	return nothing
end
