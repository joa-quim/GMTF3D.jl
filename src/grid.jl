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
	# Vertical scale is carried as a GPU transform (GMTfv.zscale -> mesh_view::transform_3d in
	# the viewer), NOT baked into the geometry, so verts/bbox keep TRUE z (correct colour range,
	# axis values, picked coordinates). See _view_fv_impl.
	s = _resolve_zscale(zscale, xmax - xmin, ymax - ymin, zmax - zmin, vfrac, isgeog, vexag)
	czmin, czmax = extrema(zc)                        # colour range from true z
	step = czmax > czmin ? (czmax - czmin) / ncolor : 1.0
	C  = GMT.makecpt(cmap = string(cmap), range = (czmin, czmax, step))
	cm = C.colormap
	col = [string("-G", z_to_hex(zc[k], cm, czmin, czmax)) for k in 1:nT]
	bb = Float64[xmin, xmax, ymin, ymax, zmin, zmax]
	return GMT.GMTfv(verts = V, faces = [F], color = [col], bbox = bb, isflat = [false], zscale = s)
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
	grid2fv_direct(G; zscale=:auto, vfrac=0.2, vexag=:auto, downsample=0, isgeog=GMT.isgeog(G)) -> GMTfv

Build a surface `GMTfv` straight from a `GMTgrid`'s structured topology — **no
triangulation**. A grid is already regular, so the mesh is pure index arithmetic:
`M·N` *shared* vertices (one per node) and `2·(M-1)·(N-1)` triangles (two per cell).
This skips `GMT.grid2tri` entirely (the slow Delaunay + decimation path) and keeps
vertices shared all the way to the GPU.

The returned `GMTfv` carries **no per-face colour** — the surface is meant to be
coloured per-vertex by elevation through the viewer's `vcolor` scivis path (smooth
interpolated ramp + smooth normals), which `view_grid` wires up. Vertical scale is the
same geog-aware GPU transform as [`tri2fv`](@ref) (`fv.zscale`).

`z[i,j]` pairs with `(x[j], y[i])` (GMT.jl normalises every grid to y-ascending,
`z[1,:]` = ymin). Cells with any NaN corner are dropped; the now-orphan vertices are kept
in place (parked at the grid's min z so they neither draw, reach the GPU as NaN, nor perturb
the bounds) — no compaction, no remap. `downsample>=2` strides the grid (every n-th node)
before meshing; it replaces `grid2tri`'s `downsample`/`ratio` simplification for this path.

This is the fast path `view_grid` uses for a plain surface. Solid/wall/thickness/base
options still need `grid2tri` (real sided geometry), so `view_grid` routes those to
[`grid2fv`](@ref) instead.

**Float32-only:** a `Float64` grid is rejected (it would double the mesh footprint for no
visual gain — the GPU path is `Float32`). The build is allocation-tight: verts (`Float32`)
go straight into one `nv0×3` buffer in grid order (no vertex remap, ever); faces are
pre-counted so the `Int` face buffer is sized exactly — neither array is oversized-then-
trimmed. `G.hasnans` (0=unknown/scan, 1=none, 2=present) decides whether the NaN handling
even runs. `view_grid` converts a stray `Float64` grid for you before calling this.
"""
function grid2fv_direct(G::GMT.GMTgrid; zscale=:auto, vfrac=0.2, vexag=:auto,
						downsample::Int=0, isgeog::Bool=GMT.isgeog(G))
	x = G.x;  y = G.y;  Z = G.z
	eltype(Z) === Float64 &&
		error("grid2fv_direct expects a Float32 grid (or less but got a z Float64 grid). " *
			  "Convert first (e.g. `mat2grid(Float32.(G.z), G)`).")
	ny, nx = size(Z)
	(nx >= 2 && ny >= 2) || error("grid too small to mesh (need >= 2x2 nodes)")
	s  = downsample >= 2 ? downsample : 1
	js = collect(1:s:nx);  is = collect(1:s:ny)               # x (cols) / y (rows) node picks
	mx = length(js);  my = length(is)
	(mx >= 2 && my >= 2) || error("downsample too coarse: < 2x2 nodes left")
	@inline gid(a, b) = (b - 1) * mx + a                      # a: x-index 1..mx, b: y-index 1..my
	@inline cellbad(a, b) = isnan(Z[is[b],js[a]]) || isnan(Z[is[b],js[a+1]]) ||
							isnan(Z[is[b+1],js[a+1]]) || isnan(Z[is[b+1],js[a]])
	nv0   = mx * my
	ncell = (mx - 1) * (my - 1)
	# Verts kept in Float32 (input z is Float32; fv_to_mesh casts to Float32 for the GPU anyway,
	# so no precision is lost vs the old Float64 buffer — it just stops doubling the footprint).
	Vx = x isa AbstractVector{Float32} ? x : Float32.(x)
	Vy = y isa AbstractVector{Float32} ? y : Float32.(y)

	# Does any cell touch a NaN? Trust the grid's own flag (G.hasnans: 0=unknown, 1=no NaNs,
	# 2=has NaNs) and only fall back to a scan when it doesn't know. The no-NaN case skips the
	# vertex remap entirely (identity ids = grid node order).
	hasnan = (G.hasnans == 1) ? false : (G.hasnans == 2) ? true :
			 let f = false
				 @inbounds for b in 1:my-1, a in 1:mx-1
					 cellbad(a, b) && (f = true;  break)
				 end
				 f
			 end

	# Vertices: ALL nv0 nodes in grid order, identity ids — NO remap, NO compaction, so NO trim
	# copy and no per-vertex branching. A NaN-z node is parked at the grid's min z: no surviving
	# face references it (its cells are dropped below), so it never draws, while a finite value
	# keeps NaN out of the GPU buffer and out of the bounds (min z is already a real z bound).
	V = Matrix{Float32}(undef, nv0, 3)
	if !hasnan
		@inbounds for b in 1:my, a in 1:mx
			g = gid(a,b);  V[g,1] = Vx[js[a]];  V[g,2] = Vy[is[b]];  V[g,3] = Z[is[b],js[a]]
		end
	else
		zfill = Float32(G.range[5])              # grid min z (NaN-excluded) — the orphan sentinel
		@inbounds for b in 1:my, a in 1:mx
			g = gid(a,b);  z = Z[is[b],js[a]]
			V[g,1] = Vx[js[a]];  V[g,2] = Vy[is[b]];  V[g,3] = ifelse(isnan(z), zfill, z)
		end
	end

	# Faces: two CCW (upward-normal) triangles per cell; cells with a NaN corner dropped. Pre-count
	# the survivors so F is sized EXACTLY — no oversize-then-trim copy.
	nf = 2 * ncell
	if hasnan
		nf = 0
		@inbounds for b in 1:my-1, a in 1:mx-1
			cellbad(a, b) || (nf += 2)
		end
		nf == 0 && error("grid has no finite cells to mesh")
	end
	F = Matrix{Int}(undef, nf, 3);  k = 0
	@inbounds for b in 1:my-1, a in 1:mx-1
		hasnan && cellbad(a, b) && continue
		v00 = gid(a,b);  v01 = gid(a+1,b);  v11 = gid(a+1,b+1);  v10 = gid(a,b+1)
		F[k+1,1] = v00;  F[k+1,2] = v01;  F[k+1,3] = v11
		F[k+2,1] = v00;  F[k+2,2] = v11;  F[k+2,3] = v10
		k += 2
	end

	xmin, xmax = extrema(@view V[:,1]);  ymin, ymax = extrema(@view V[:,2]);  zmin, zmax = extrema(@view V[:,3])
	sz = _resolve_zscale(zscale, Float64(xmax - xmin), Float64(ymax - ymin), Float64(zmax - zmin), vfrac, isgeog, vexag)
	bb = Float64[xmin, xmax, ymin, ymax, zmin, zmax]
	return GMT.GMTfv(verts = V, faces = [F], color = [String[]], bbox = bb, isflat = [false], zscale = sz)
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

# Vertical curtains (Fledermaus-style seismic / midwater profiles)
- `vcurtain=nothing`: hang one or more image "curtains" — vertical walls that follow an
  XY path THROUGH the scene, sharing the grid's coordinate space and vertical scale so
  they stand under / weave through the relief. A curtain is a NamedTuple:
    - `image`: the profile — a `GMTimage`, or a file-path `String` that **F3D loads
      itself** (no `gmtread` import).
    - `path`: the horizontal track — an `N×2` matrix (`x y`) or a `GMTdataset`. `N=2` is
      the simplest "two-points" straight curtain; more points let the image weave.
    - `zrange=(zmin, zmax)`: the vertical extent the image spans (data z units).
    - `spacing=:distance`: column placement — `:distance` (by cumulative track length),
      `:simple` (even per point), or `:geomatch` (caller `cols`, per-point pixel columns).
    - `cols=nothing`: the `:geomatch` per-point column positions.
    - `flipv=false`: flip the vertical image sense if it comes out upside down.
    - `clip=false`: when `true` (or `:surface`), cut the curtain's top edge to the grid
      surface — the wall hugs the bathymetry and the image ABOVE the relief is dropped
      (only the sub-surface part shows). The track is densified and the seafloor sampled
      along it; `clip_n=300` sets that column resolution. Clip needs the grid, so it works
      only through `view_grid`/`f3dview` (a bare `view_fv` curtain has no surface to cut to).
  Pass one NamedTuple, or a **vector** of them for several curtains. The image is drawn
  unlit (emissive) so it shows exact pixels while the relief keeps its shading.
  E.g. `view_grid(G; vcurtain=(; image="profile.jpg", path=track, zrange=(-2000,0)))`, or
  clipped: `view_grid(G; vcurtain=(; image=I, path=track, zrange=(-10000,0), clip=true))`.

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

	# Resolve any clip-to-surface vcurtain here, where we still have the grid: sample the
	# bathymetry along the (densified) track so the curtain's top edge hugs the relief and
	# the image above the surface is dropped. No-op for curtains without `clip`.
	# Clip-to-surface vcurtain: sample the bathymetry along the (densified) track so the
	# curtain top hugs the relief. Spec VALIDATION (incl. missing-image bail) is done once,
	# downstream in `view_fv` — the single gatekeeper for both view_grid and direct view_fv,
	# so a bad spec prints its clean message exactly ONCE. `_resolve_vcurtain_clip` only reads
	# the grid + track (never the image), so it is safe to run before that check.
	if haskey(vkw, :vcurtain) && _vcurtain_problem(vkw[:vcurtain]) == ""
		Gh = isa(G, GMT.GMTgrid) ? G : GMT.gmtread(G)
		vkw[:vcurtain] = _resolve_vcurtain_clip(vkw[:vcurtain], Gh)
	end

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

	# Plain surface -> FAST PATH: build the mesh straight from the grid's structured
	# topology (grid2fv_direct), no `grid2tri`. The solid/wall/thickness/base options
	# build real sided geometry, NOT a height field, so they still need grid2tri (grid2fv).
	needs_tri = thickness != 0 || isbase || bottom || wall_only || top_only
	if needs_tri
		fv = grid2fv(Gp; cmap=cmap, zscale=zscale, vfrac=vfrac, vexag=vexag, ncolor=ncolor,
					 thickness=thickness, isbase=isbase, downsample=downsample,
					 ratio=ratio, bottom=bottom, wall_only=wall_only, top_only=top_only, geog=geog)
	else
		# Fast path is Float32-only (grid2fv_direct refuses Float64 to avoid doubling the mesh
		# footprint). view_grid is the convenience front door, so convert a stray Float64 grid
		# here (one f32 copy of z; rare) instead of erroring in the user's face.
		Gd = eltype(Gp.z) === Float32 ? Gp : GMT.mat2grid(Float32.(Gp.z), Gp)
		fv = grid2fv_direct(Gd; zscale=zscale, vfrac=vfrac, vexag=vexag,
							downsample=downsample, isgeog=(geog || GMT.isgeog(Gp)))
		# Colour the bare surface per-VERTEX by elevation through the viewer's scivis ramp
		# (smooth, shared-vertex). Skipped under a drape (the image is the colour then).
		if isempty(drape)
			zmn, zmx = Float64(Gp.range[5]), Float64(Gp.range[6])
			get!(vkw, :vcolor, (; pal=cmap_palette(cmap, ncolor), n=ncolor, vmin=zmn, vmax=zmx))
		end
	end

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
