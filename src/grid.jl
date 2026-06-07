# GMTF3D — view_grid: GMTgrid surfaces via grid2tri → coloured GMTfv → viewer.

"""
	tri2fv(D; cmap=:turbo, zscale=:auto, vfrac=0.2, vexag=1.0, isgeog=false, ncolor=256) -> GMTfv

Fold a `Vector{GMTdataset}` of 3-D triangles (as returned by `GMT.grid2tri`)
into a single coloured `GMTfv`. Each triangle becomes one face with its own
three vertices; faces are coloured by mean z through `cmap`. `ncolor` is the
colormap resolution.

Vertical scale (`zscale=:auto`, the default):
* `isgeog=true` — x,y are degrees and z is assumed in **metres**, so z is
  converted to degree units (true 1:1) and then multiplied by the vertical
  exaggeration `vexag` (default 1.0). Set `isgeog` from `GMT.isgeog(grid)`.
* `isgeog=false` — purely geometric: the displayed z-range is set to `vfrac`
  times the largest horizontal extent (`vfrac=0.2` ~ a gentle slab), so the
  surface reads *flatter than a cube*.

Pass a number for `zscale` to override completely (e.g. `zscale=1` for raw 1:1).
Colours always key off the true (un-scaled) z.
"""
function tri2fv(D::Vector{<:GMT.GMTdataset}; cmap=:turbo, zscale=:auto,
				vfrac=0.2, vexag=:auto, isgeog::Bool=false, ncolor::Int=256)
	nT = length(D)
	nT == 0 && error("grid2tri returned no triangles")
	V  = Matrix{Float64}(undef, 3nT, 3)
	F  = Matrix{Int}(undef, nT, 3)
	zc = Vector{Float64}(undef, nT)                  # per-face mean z (true, for colour)
	@inbounds for k in 1:nT
		d = D[k].data                                # 4x3, row 4 == row 1; first 3 are the corners
		b = 3 * (k - 1)
		for c in 1:3
			V[b+c, 1] = d[c, 1];  V[b+c, 2] = d[c, 2];  V[b+c, 3] = d[c, 3]   # z un-scaled here
		end
		F[k, 1], F[k, 2], F[k, 3] = b + 1, b + 2, b + 3
		zc[k] = (d[1, 3] + d[2, 3] + d[3, 3]) / 3
	end
	xmin, xmax = extrema(@view V[:, 1])
	ymin, ymax = extrema(@view V[:, 2])
	zmin, zmax = extrema(@view V[:, 3])
	s = _resolve_zscale(zscale, xmax - xmin, ymax - ymin, zmax - zmin, vfrac, isgeog, vexag)
	s == 1.0 || (@inbounds @views V[:, 3] .*= s)     # apply vertical scale to geometry
	czmin, czmax = extrema(zc)                        # colour range from true z
	step = czmax > czmin ? (czmax - czmin) / ncolor : 1.0
	C  = GMT.makecpt(cmap = string(cmap), range = (czmin, czmax, step))
	cm = C.colormap
	col = [string("-G", z_to_hex(zc[k], cm, czmin, czmax)) for k in 1:nT]
	bb = Float64[xmin, xmax, ymin, ymax, extrema(@view V[:, 3])...]
	return GMT.GMTfv(verts = V, faces = [F], color = [col], bbox = bb, isflat = [false])
end

"""
	grid2fv(G; cmap=:turbo, zscale=:auto, vfrac=0.2, vexag=1.0, ncolor=256, kw...) -> GMTfv

Triangulate a grid with `GMT.grid2tri(G; kw...)` and convert to a coloured
`GMTfv` ready for F3D. The vertical scale is geog-aware: if `GMT.isgeog(G)` is
true, x,y are degrees and z is assumed in metres, so `:auto` gives a true 1:1
scale times `vexag`; otherwise `:auto` uses the `vfrac` flat-slab heuristic (see
`tri2fv`). `kw...` are forwarded to `grid2tri` (`thickness`, `wall_only`,
`top_only`, `bottom`, `downsample`, `ratio`, `geog`, ...).
"""
function grid2fv(G; cmap=:turbo, zscale=:auto, vfrac=0.2, vexag=:auto, ncolor::Int=256, kwargs...)
	D = GMT.grid2tri(G; kwargs...)
	return tri2fv(D; cmap=cmap, zscale=zscale, vfrac=vfrac, vexag=vexag, isgeog=GMT.isgeog(G), ncolor=ncolor)
end

"""
	view_grid(G; kwargs...)

Visualise a GMT grid `G` (a `GMTgrid` or a grid file name) in F3D: `grid2tri` ->
coloured `GMTfv` -> interactive viewer (or an offscreen export).

# Surface & colour
- `cmap=:turbo`: GMT colormap name for the elevation colouring.
- `ncolor=256`: number of colour levels.
- `zscale=:auto`: vertical scale. `:auto` is geog-aware — geographic grids
  (`GMT.isgeog(G)`) get a true 1:1 metre scale, others the `vfrac` flat-slab look.
  A number overrides it directly.
- `vexag=:auto`: vertical exaggeration multiplier applied on top of `zscale`.
- `vfrac=0.2`: target relief height as a fraction of the xy span (non-geographic
  `:auto` only).

# Mesh build (forwarded to `GMT.grid2tri`)
- `thickness=0.0`, `isbase=false`, `bottom=false`, `wall_only=false`,
  `top_only=false`: solid/wall options.
- `downsample=0`: decimate the grid before triangulating (0 = none).
- `ratio=0.01`: triangulation simplification ratio.
- `geog=false`: force geographic handling.

# Image draping
- `drape=GMTimage()`: a `GMTimage` to drape over the surface as a texture.
- `drape_clip=false`: when `true`, paint only the grid ∩ image overlap and let
  `outside` decide the rest. When `false`, the image is stretched over the whole surface.
- `outside=:drop`: what to do with the grid area the image does NOT cover
  (`drape_clip=true` only):
	- `:drop` — crop the grid to the overlap (no resample); rest not shown.
	- `:shade` — keep full grid; uncovered area = flat `outside_color` fill, no edges.
	- `:shademesh` — like `:shade` but with mesh edges on top.
	- `:transparent` — keep full grid; uncovered area is see-through.
- `outside_color=200`: fill colour for `:shade`/`:shademesh` — a grey `0-255`, or
  an `(r,g,b)` tuple (`0-255` ints, or `0-1` floats).

# Colour bar
- `colorbar=true`: draw a colour scale (right edge) keyed on the grid's true z range
  and `cmap`. Auto-suppressed when an image is draped (the surface shows the picture,
  not a z ramp). Needs an f3d built with `c/f3d_ext_*.cxx`.

# Export (forwarded to `view_fv`)
- `mapexport=""`: one-shot georeferenced map. Forces orthographic top-down +
  offscreen and saves to this file (extension picks the format: `png`/`jpg`/`tif`/
  `bmp`, default `png`). A `.tiff` extension writes a GeoTIFF stamped with the
  grid's range and projection.
- `saveimg=""`: save the current view to a file (any of the formats above), without forcing top-down.
- `topdown=false`: orthographic straight-down, north-up view (georeferenceable).
- `offscreen=false`: render without opening a window.

# View (forwarded to `view_fv`)
- `title`, `size=(1600,1200)`, `bg=(0.1,0.1,0.15)`: window title, pixel size, background colour.
- `async=true`: viewer on a worker thread → REPL gets a `ViewHandle` at once
  (`close!(h)`); `false` blocks until the window closes.
- `lights=()`: vector of light NamedTuples (see `add_lights!`).
- `azimuth=-40`, `elevation=25`: orbit / tilt the camera (degrees).
- `up="+Z"`: scene up-direction (defaulted to `"+Z"` so grids lie flat, X,Y floor).
- `flat=false`: flat (faceted) shading instead of smooth.
- `axes=true`, `grid=true`: orientation gizmo / f3d floor grid (both forced off under `topdown`).
- mesh wireframe edges: live `'e'` hotkey (no kwarg); `outside=:shademesh` turns them
  on automatically for the grid area an image drape does not cover.

# Extended interactions (forwarded; need an f3d built with `c/f3d_ext_*.cxx`)
- `cube_axes=true`: labelled bounding-box (X/Y/Z tick) axes with coords.
- `coord_readout=true`: live world X/Y/Z under the cursor.
- `vscale_drag=true`, `vscale_step=0.01`: Ctrl+left-drag to exaggerate / flatten the
  relief (`vscale_step` per dragged pixel).
- `scale_handle=true`: Fledermaus-style gizmo at the rotation centre — drag the vertical
  arrowhead (vertical scale), horizontal arrows (tilt), or compass ring (azimuth). ON by
  default for `view_grid` (pass `scale_handle=false` to hide it).

# Material (forwarded to `view_fv`; `nothing` keeps f3d defaults)
- `metallic=nothing`: PBR metalness, scalar `0-1`.
- `roughness=nothing`: PBR roughness, scalar `0-1`.
- `emissive=nothing`: self-illumination factor — a scalar grey or an `(r,g,b)` tuple (`0-1`).

Any other `view_fv` keyword (e.g. `drape_light`, `drape_emis`, `drape_unlit`,
`georef`) passes straight through.

E.g. `view_grid(GMT.peaks())`, `view_grid("dem.grd"; vexag=5)`, or
`view_grid(G; drape=I, mapexport="lit.tiff")`.
"""
function view_grid(G; cmap=:turbo, zscale=:auto, vfrac=0.2, vexag=:auto, ncolor::Int=256,
				   thickness=0.0, isbase=false, downsample=0, ratio=0.01,
				   bottom=false, wall_only=false, top_only=false, geog=false,
				   drape::GMT.GMTimage=GMT.GMTimage(), drape_clip::Bool=false,
				   outside::Symbol=:drop, outside_color=200, colorbar::Bool=true, kwargs...)
	# Georeferenced drape (`drape_clip=true`): only the grid ∩ image area carries the
	# image. `outside` controls the grid area NOT covered by the image:
	#   :drop        – crop the grid to the overlap; uncovered area is not shown.
	#                  Cheapest: crop BOTH grid and image to their bbox intersection
	#                  (in-memory subset) and stretch-drape.
	#   :shade       – keep the full grid; uncovered area is a flat fixed colour
	#                  (`outside_color`, grey 0-255), NO mesh edges.
	#   :shademesh   – like :shade but with global mesh edges on top.
	#   :transparent – keep the full grid; uncovered area is invisible (see-through).
	# :shade/:shademesh pad the image into the grid bbox by index copy. Only
	# :transparent still uses an alpha warp (drape_clip path in view_fv).
	# geo footprint (x0,x1,y0,y1,proj) of a grid -> lets view_fv stamp a GeoTIFF on .tiff export.

	# Bail BEFORE building the (potentially large) mesh if a window is already open.
	let h = _busy_view(; async=get(kwargs, :async, true), offscreen=get(kwargs, :offscreen, false))
		h === nothing || return h
	end
	geo(g) = (g.range[1], g.range[2], g.range[3], g.range[4], isempty(g.proj4) ? g.wkt : g.proj4)
	# No default-patching here: up=+Z, cube_axes and the scale_handle gizmo (rotation rings)
	# all default in _view_fv_impl — scale_handle = true, the SAME default
	# view_points uses, so both viewers enable the rings by the identical procedure.
	vkw = Dict{Symbol,Any}(kwargs)

	# Line overlays (`lines=`) carry z in DATA units; the surface is drawn with the
	# vertical scale `_resolve_zscale` gives, so forward that SAME factor as `line_zfac`
	# (else the line floats off the surface). N x 2 lines have no z -> lie on z = 0.
	if haskey(vkw, :lines) || haskey(vkw, :L)
		Gh = isa(G, GMT.GMTgrid) ? G : GMT.gmtread(G)
		r  = Gh.range
		get!(vkw, :line_zfac,
			 _resolve_zscale(zscale, r[2] - r[1], r[4] - r[3], r[6] - r[5], vfrac, GMT.isgeog(Gh), vexag))
	end
	if (!isempty(drape) && drape_clip)
		Gin = isa(G, GMT.GMTgrid) ? G : GMT.gmtread(G)
		full(g) = grid2fv(g; cmap=cmap, zscale=zscale, vfrac=vfrac, vexag=vexag, ncolor=ncolor,
						  thickness=thickness, isbase=isbase, downsample=downsample,
						  ratio=ratio, bottom=bottom, wall_only=wall_only, top_only=top_only, geog=geog)
		if (outside === :drop)
			# crop BOTH grid and image to their bbox intersection (in-memory subset),
			# and stretch-drape; uncovered area is not built.
			gr, ir = Gin.range, drape.range
			ix0, ix1 = max(gr[1], ir[1]), min(gr[2], ir[2])
			iy0, iy1 = max(gr[3], ir[3]), min(gr[4], ir[4])
			(ix1 > ix0 && iy1 > iy0) || error("grid and image bounding boxes do not overlap")
			Gc = GMT.crop(Gin, region=(ix0, ix1, iy0, iy1))[1]
			Ic = GMT.crop(drape, region=(ix0, ix1, iy0, iy1))[1]
			return view_fv(full(Gc); drape=Ic, drape_clip=false, georef=geo(Gc), vkw...)
		elseif (outside === :transparent)
			# full grid; warp image onto the grid bbox with alpha 0 outside -> uncovered
			# area is see-through (drape_clip path enables blending).
			return view_fv(full(Gin); drape=drape, drape_clip=true, georef=geo(Gin), vkw...)
		elseif (outside === :shade)
			# full grid; uncovered area = flat `outside_color` fill, NO edges. `drape_pad`
			# places the image into the full-grid-bbox canvas by index copy
			# colour = image + fixed-colour fill outside (lit -> relief shading);
			# emissive = image + BLACK fill outside (fill emits nothing, only image glows).
			gr = Gin.range
			Cg, Ce = drape_pad(drape, gr[1], gr[2], gr[3], gr[4]; fill=outside_color)
			return view_fv(full(Gin); drape=Cg, drape_emis=Ce, drape_clip=false, georef=geo(Gin), vkw...)
		elseif (outside === :shademesh)
			# like :shade but with mesh edges on top (the combined look): the only path
			# that drives the internal `_edges` flag — see _view_fv_impl.
			gr = Gin.range
			Cg, Ce = drape_pad(drape, gr[1], gr[2], gr[3], gr[4]; fill=outside_color)
			kw = copy(vkw)
			kw[:_edges]     = true
			kw[:_edge_width] = get(kw, :_edge_width, 1.0)
			return view_fv(full(Gin); drape=Cg, drape_emis=Ce, drape_clip=false, georef=geo(Gin), kw...)
		else
			error("`outside` must be :drop, :shade, :shademesh or :transparent (got :$outside)")
		end
	end

	Gp = isa(G, GMT.GMTgrid) ? G : GMT.gmtread(G)
	fv = grid2fv(Gp; cmap=cmap, zscale=zscale, vfrac=vfrac, vexag=vexag, ncolor=ncolor,
				 thickness=thickness, isbase=isbase, downsample=downsample,
				 ratio=ratio, bottom=bottom, wall_only=wall_only, top_only=top_only, geog=geog)

	# Colour scale keyed on the grid's true z range + the same colormap (not when an
	# image is draped — then the surface shows the picture, not a z-colour ramp).
	if colorbar && isempty(drape)
		zmn, zmx = Float64(Gp.range[5]), Float64(Gp.range[6])
		nd = _axis_decimals(zmx - zmn)
		get!(vkw, :colorbar, (rgb=cmap_palette(cmap, ncolor), n=ncolor,
							  vmin=zmn, vmax=zmx, title="", fmt="%.$(nd)f"))
	end
	return view_fv(fv; drape=drape, drape_clip=drape_clip, georef=geo(Gp), vkw...)
end
