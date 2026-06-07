# GMTF3D — common machinery shared by every viewer unit.
# Mesh build, colour parsing, lighting, palette/texture, async window handle,
# extended interactions, line overlays, feature probes and vertical-scale logic.
# (Extracted verbatim from the original examples/gmt_solids.jl.)

# Colour comes from `fv.color` (GMT `-G` strings). Real GMT producers fill it —
# e.g. `flatfv(image, ...)` builds an FV from an RGB image, one `-G#rrggbb` per
# face, so `view_fv(flatfv("pic.png", shape=:circle))` is coloured for free.
# `colorize_by_z!` here is only a demo filler for the plain solids.
#
# Illumination: normals are computed in `fv_to_mesh`. Default `flat=false` gives
# smooth shading (averaged per-vertex normals, `compute_vertex_normals`);
# `flat=true` gives faceted shading (one Newell face normal per face, split
# verts). Lights are set via the `lights` keyword — e.g.
#   view_fv(fv; flat=true, lights=[(; type=:scene, direction=(-1,-1,-1), intensity=1.3)])
# With `lights=()` F3D falls back to its default headlight.
# CLI: `julia gmt_solids.jl cube flat`.

# ---------------------------------------------------------------------------
# GMT "-G" colour string -> (r,g,b) UInt8
# ---------------------------------------------------------------------------
const _NAMED = Dict(
	"red"=>(0xff,0x00,0x00), "green"=>(0x00,0x80,0x00), "blue"=>(0x00,0x00,0xff),
	"white"=>(0xff,0xff,0xff), "black"=>(0x00,0x00,0x00), "yellow"=>(0xff,0xff,0x00),
	"cyan"=>(0x00,0xff,0xff), "magenta"=>(0xff,0x00,0xff), "orange"=>(0xff,0xa5,0x00),
	"gray"=>(0x80,0x80,0x80), "grey"=>(0x80,0x80,0x80),
	"darkgreen"=>(0x00,0x64,0x00), "lightgreen"=>(0x90,0xee,0x90),
)

function parse_gmt_color(s::AbstractString)::NTuple{3,UInt8}
	c = strip(s)
	startswith(c, "-G") && (c = c[3:end])
	isempty(c) && return (0x80, 0x80, 0x80)
	if startswith(c, "#")                       # #rrggbb
		h = c[2:end]
		return (parse(UInt8, h[1:2], base=16), parse(UInt8, h[3:4], base=16), parse(UInt8, h[5:6], base=16))
	elseif occursin('/', c)                     # r/g/b
		p = split(c, '/')
		return (UInt8(clamp(parse(Int, p[1]),0,255)), UInt8(clamp(parse(Int, p[2]),0,255)), UInt8(clamp(parse(Int, p[3]),0,255)))
	elseif all(isdigit, c)                       # single number => gray
		g = UInt8(clamp(parse(Int, c), 0, 255));  return (g, g, g)
	else                                         # named
		return get(_NAMED, lowercase(c), (0x80, 0x80, 0x80))
	end
end

# ---------------------------------------------------------------------------
# Per-face colour access straight off the GMTfv (no flattened face-list copy).
# `fv.faces` is a Vector of Mx(verts-per-face) Int matrices; `fv.color` holds an
# aligned Vector of "-G" strings per group. We iterate those matrices directly
# with row indices, so no per-face Vector{Int} is ever allocated.
# ---------------------------------------------------------------------------
have_color(fv::GMT.GMTfv) = !isempty(fv.color) && any(!isempty, fv.color)

# Total (faces, corners) across all groups — for exact array preallocation.
function count_faces_corners(fv::GMT.GMTfv)
	nfaces = ncorners = 0
	for Fm in fv.faces
		isempty(Fm) && continue
		nf, npf = size(Fm)
		nfaces   += nf
		ncorners += nf * npf
	end
	return nfaces, ncorners
end

@inline function face_color(fv::GMT.GMTfv, g::Int, r::Int)
	(g <= length(fv.color) && r <= length(fv.color[g])) ? fv.color[g][r] : ""
end

"""
	compute_vertex_normals(V, faces) -> Matrix{Float32}  (nv x 3)

Smooth per-vertex normals: each face's normal (Newell's method, robust for
non-planar polygons) accumulated onto its vertices, then normalised. Iterates
the FV face matrices (`fv.faces`) directly — no per-face allocation. Float32 is
ample for shading normals and halves the buffer vs Float64.
"""
function compute_vertex_normals(V::AbstractMatrix, faces)
	nv = size(V, 1)
	N  = zeros(Float32, nv, 3)
	for Fm in faces
		isempty(Fm) && continue
		nf, npf = size(Fm)
		for r in 1:nf
			nx = ny = nz = 0.0f0
			for a in 1:npf                       # Newell: sum over the face's edges
				i = Fm[r, a]
				j = Fm[r, a == npf ? 1 : a + 1]
				nx += Float32(V[i,2] - V[j,2]) * Float32(V[i,3] + V[j,3])
				ny += Float32(V[i,3] - V[j,3]) * Float32(V[i,1] + V[j,1])
				nz += Float32(V[i,1] - V[j,1]) * Float32(V[i,2] + V[j,2])
			end
			for a in 1:npf
				vi = Fm[r, a]
				N[vi,1] += nx;  N[vi,2] += ny;  N[vi,3] += nz
			end
		end
	end
	@inbounds for i in 1:nv
		n = sqrt(N[i,1]^2 + N[i,2]^2 + N[i,3]^2)
		n < 1f-12 && (n = 1f0)
		N[i,1] /= n;  N[i,2] /= n;  N[i,3] /= n
	end
	return N
end

# Single normalised face normal (Newell) for one face row — used for flat shading.
@inline function newell_normal(V::AbstractMatrix, Fm, r::Int, npf::Int)
	nx = ny = nz = 0.0f0
	for a in 1:npf
		i = Fm[r, a]
		j = Fm[r, a == npf ? 1 : a + 1]
		nx += Float32(V[i,2] - V[j,2]) * Float32(V[i,3] + V[j,3])
		ny += Float32(V[i,3] - V[j,3]) * Float32(V[i,1] + V[j,1])
		nz += Float32(V[i,1] - V[j,1]) * Float32(V[i,2] + V[j,2])
	end
	n = sqrt(nx^2 + ny^2 + nz^2);  n < 1f-12 && (n = 1f0)
	return (nx / n, ny / n, nz / n)
end

"""
	fv_to_mesh(fv; flat=false) -> NamedTuple

Convert a `GMTfv` to the flat arrays an `f3d_mesh_t` expects, with `normals` for
illumination. `flat=false` (default) gives smooth shading: one averaged normal
per shared vertex. `flat=true` gives flat shading: each face's own Newell normal
applied to all its corners (faceted look) — this needs split vertices, so a flat
mesh is always vertex-split. When the FV has per-face colours, vertices are also
split and `texcoords` index into `palette` (RGB triplets, `ncolors` texels).
Vertices stay shared only for the smooth + uncoloured case. Reads in place.
"""
function fv_to_mesh(fv::GMT.GMTfv; flat::Bool=false, drape::Bool=false)
	V  = fv.verts
	coloured = !drape && have_color(fv)         # drape overrides per-face colour

	# Drape UV: stretch the image over the FULL x,y extent of the surface (image
	# coordinates ignored). u = (x-xmin)/dx; v = (y-ymin)/dy. No V flip: the grid
	# origin is lower-left and gmtwrite's PNG / VTK texture sampling already put
	# the image's top row at max-y (north), so flipping would turn it upside down.
	# Per-vertex, so it folds into both the shared- and split-vertex paths below.
	local drape_uv
	if drape
		xmn, xmx = extrema(@view V[:, 1]);  dx = xmx - xmn;  dx <= 0 && (dx = 1.0)
		ymn, ymx = extrema(@view V[:, 2]);  dy = ymx - ymn;  dy <= 0 && (dy = 1.0)
		drape_uv = vi -> (Float32((V[vi,1]-xmn)/dx), Float32((V[vi,2]-ymn)/dy))
	end

	if !flat && !coloured                       # smooth + plain: shared vertices
		VN = compute_vertex_normals(V, fv.faces)
		nv = size(V, 1)
		points  = Vector{Float32}(undef, 3nv)
		normals = Vector{Float32}(undef, 3nv)
		@inbounds for i in 1:nv
			points[3i-2],  points[3i-1],  points[3i]  = V[i,1],  V[i,2],  V[i,3]
			normals[3i-2], normals[3i-1], normals[3i] = VN[i,1], VN[i,2], VN[i,3]
		end
		nfaces, ncorners = count_faces_corners(fv)
		sides   = UInt32[];  sizehint!(sides, nfaces)
		indices = UInt32[];  sizehint!(indices, ncorners)
		for Fm in fv.faces
			isempty(Fm) && continue
			nf, npf = size(Fm)
			for r in 1:nf
				push!(sides, UInt32(npf))
				for a in 1:npf
					push!(indices, UInt32(Fm[r,a] - 1))
				end
			end
		end
		tc = Float32[]
		if drape
			tc = Vector{Float32}(undef, 2nv)
			@inbounds for i in 1:nv
				u, v = drape_uv(i);  tc[2i-1] = u;  tc[2i] = v
			end
		end
		return (; points, normals, texcoords = tc, sides, indices, palette = UInt8[], ncolors = 0)
	end

	# Split-vertex path: required for flat shading and/or per-face colour.
	# Smooth normals (if not flat) come from the shared-vertex normals.
	VN = flat ? nothing : compute_vertex_normals(V, fv.faces)
	nfaces, ncorners = count_faces_corners(fv)

	# Colour bookkeeping: distinct-colour palette + one colour index per face.
	ncol    = 0
	cidx    = UInt32[]
	palette = UInt8[]
	if coloured
		idxof = Dict{NTuple{3,UInt8},Int}()
		uniq  = NTuple{3,UInt8}[]
		cidx  = Vector{UInt32}(undef, nfaces)
		fc = 0
		for (g, Fm) in enumerate(fv.faces)
			isempty(Fm) && continue
			for r in 1:size(Fm, 1)
				c = parse_gmt_color(face_color(fv, g, r))
				k = get!(idxof, c) do
					push!(uniq, c); length(uniq)
				end
				cidx[fc += 1] = k
			end
		end
		ncol = length(uniq)
		sizehint!(palette, 3ncol)
		for c in uniq
			push!(palette, c[1], c[2], c[3])
		end
	end

	points    = Float32[];  sizehint!(points,  3ncorners)
	normals   = Float32[];  sizehint!(normals, 3ncorners)
	texcoords = Float32[];  (coloured || drape) && sizehint!(texcoords, 2ncorners)
	sides     = UInt32[];   sizehint!(sides,   nfaces)
	indices   = UInt32[];   sizehint!(indices, ncorners)
	vid = 0
	fi  = 0
	for Fm in fv.faces
		isempty(Fm) && continue
		nf, npf = size(Fm)
		for r in 1:nf
			fi += 1
			fn = flat ? newell_normal(V, Fm, r, npf) : (0f0, 0f0, 0f0)
			u  = coloured ? (cidx[fi] - 0.5f0) / ncol : 0f0   # texel centre
			push!(sides, UInt32(npf))
			for a in 1:npf
				vi = Fm[r, a]
				push!(points, V[vi,1], V[vi,2], V[vi,3])
				if flat
					push!(normals, fn[1], fn[2], fn[3])
				else
					push!(normals, VN[vi,1], VN[vi,2], VN[vi,3])
				end
				if coloured
					push!(texcoords, u, 0.5f0)
				elseif drape
					uu, vv = drape_uv(vi);  push!(texcoords, uu, vv)
				end
				push!(indices, UInt32(vid));  vid += 1
			end
		end
	end

	return (; points, normals, texcoords, sides, indices, palette, ncolors = ncol)
end

# Collapse a path the way libf3d wants. The shipped DLL auto-collapses any path
# given to a `*.texture` option and logs "Collapsing path inside the libf3d is now
# deprecated, use utils::collapsePath manually." Pre-collapsing here (normalised,
# forward slashes) makes the DLL skip its own collapse -> no warning. Textures are
# path-only in this API (F3D_API_gaps #1), so every texture we set goes through here.
function collapse_path(p::AbstractString)
	cp = F3D.f3d_utils_collapse_path(String(p), "")
	return cp == C_NULL ? String(p) : unsafe_string(cp)
end

# ---------------------------------------------------------------------------
# Write the palette as a 1 x ncolors RGB PNG via F3D's own image API and return
# the (collapsed) temp file path (so we need no extra image dependency).
# ---------------------------------------------------------------------------
function write_palette_png(palette::Vector{UInt8}, ncolors::Int)
	img = F3D.f3d_image_new_params(Cuint(ncolors), Cuint(1), Cuint(3), F3D.BYTE)
	(img == C_NULL) && error("failed to create palette image")
	path = joinpath(tempdir(), "f3d_palette_$(getpid()).png")
	GC.@preserve palette begin
		F3D.f3d_image_set_content(img, pointer(palette))
		F3D.f3d_image_save(img, path, F3D.PNG)
	end
	F3D.f3d_image_delete(img)
	return collapse_path(path)
end

# ---------------------------------------------------------------------------
# Georeferenced drape: place `I` onto the [x0,x1]×[y0,y1] bbox at its TRUE
# geographic position, with an ALPHA band that is 0 outside the image footprint, by
# index copy at the image's own increment (same transpose/orientation as `drape_pad`).
# Sampling this canvas with the bbox UV paints only the grid ∩ image overlap; the rest
# stays transparent. Used by the drape_clip path (outside=:transparent / view_fv clip).
# ---------------------------------------------------------------------------
function drape_to_bbox(I::GMT.GMTimage, x0, x1, y0, y1)
	ox0, ox1 = max(x0, I.range[1]), min(x1, I.range[2])
	oy0, oy1 = max(y0, I.range[3]), min(y1, I.range[4])
	Ic = GMT.crop(I, region=(ox0, ox1, oy0, oy1))[1]
	dx, dy = abs(Ic.inc[1]), abs(Ic.inc[2])
	nx = clamp(round(Int, (x1 - x0) / dx), 16, 8192)
	ny = clamp(round(Int, (y1 - y0) / dy), 16, 8192)
	S = Ic.image;  inx, iny = size(S, 1), size(S, 2)
	xoff = round(Int, (Ic.range[1] - x0) / dx)
	yoff = round(Int, (y1 - Ic.range[4]) / dy)
	rgba = zeros(UInt8, ny, nx, 4)                        # RGB 0 + alpha 0 (transparent) outside
	@inbounds for jy in 1:iny, ix in 1:inx
		r = yoff + jy;  c = xoff + ix                     # rows = lat (north->down), cols = lon
		(1 <= r <= ny && 1 <= c <= nx) || continue
		rgba[r, c, 1] = S[ix, jy, 1];  rgba[r, c, 2] = S[ix, jy, 2]
		rgba[r, c, 3] = S[ix, jy, 3];  rgba[r, c, 4] = 0xff
	end
	return GMT.mat2img(rgba; x=[x0, x1], y=[y0, y1])
end

# Pad an image onto a larger bbox WITHOUT gdal/resample: copy the image block into a
# canvas covering [x0,x1]×[y0,y1] at the image's OWN increment, leaving `fill` everywhere
# the image is absent. Returns two GMTimages over the bbox — `col` (image + `fill` outside)
# and `emis` (image + BLACK outside) — for the colour and emissive textures of `:shade`.
# Pure index translation in the image's native layout, so no resampling and no flip.
# Expand a user color into a 3-band UInt8 RGB tuple. Accepts:
#   grey 0-255 Int/Real            -> (g,g,g)
#   (r,g,b) tuple/vector 0-255     -> as-is
#   (r,g,b) floats in 0-1          -> scaled to 0-255
_rgb3(c::Real) = (u = UInt8(clamp(round(Int, c), 0, 255)); (u, u, u))
function _rgb3(c)
	length(c) == 3 || error("color must be a grey value or an (r,g,b); got $(c)")
	# floats all in [0,1] are interpreted as fractions -> scale to 0-255; otherwise 0-255.
	scl = all(v -> isa(v, AbstractFloat) && 0 <= v <= 1, c) ? 255 : 1
	ntuple(i -> UInt8(clamp(round(Int, c[i] * scl), 0, 255)), 3)
end

function drape_pad(I::GMT.GMTimage, x0, x1, y0, y1; fill=170)
	# Crop to the part of the image inside the canvas FIRST: `GMT.crop` returns a clean
	# band-planar, top-origin "TRBa" image (the native layout reconstructs reliably; the
	# raw image may be pixel-interleaved "BRPa", which a fresh planar array can't mimic).
	ox0, ox1 = max(x0, I.range[1]), min(x1, I.range[2])
	oy0, oy1 = max(y0, I.range[3]), min(y1, I.range[4])
	Ic = GMT.crop(I, region=(ox0, ox1, oy0, oy1))[1]
	dx, dy = abs(Ic.inc[1]), abs(Ic.inc[2])
	nx = clamp(round(Int, (x1 - x0) / dx), 16, 8192)
	ny = clamp(round(Int, (y1 - y0) / dy), 16, 8192)
	S = Ic.image
	inx, iny = size(S, 1), size(S, 2)                     # Ic.image: dim1 = lon, dim2 = lat (TRBa, jy=1 north)
	xoff = round(Int, (Ic.range[1] - x0) / dx)            # cols from canvas west to image west
	yoff = round(Int, (y1 - Ic.range[4]) / dy)            # rows from canvas north down to image top
	rgb  = _rgb3(fill)
	# canvas is standard raster order (rows = lat from NORTH, cols = lon from WEST) so
	# mat2img's default reads it upright; the source is indexed [lon, lat] so the copy
	# transposes it into [lat, lon] (this is the 90° fix).
	col  = Array{UInt8}(undef, ny, nx, 3)
	for b in 1:3; fill!(view(col, :, :, b), rgb[b]); end
	emis = zeros(UInt8, ny, nx, 3)
	@inbounds for b in 1:3, jy in 1:iny, ix in 1:inx
		r = yoff + jy;  c = xoff + ix                     # row = lat (north->down), col = lon (west->east)
		(1 <= r <= ny && 1 <= c <= nx) || continue
		v = S[ix, jy, b];  col[r, c, b] = v;  emis[r, c, b] = v
	end
	return GMT.mat2img(col;  x=[x0, x1], y=[y0, y1]),
		   GMT.mat2img(emis; x=[x0, x1], y=[y0, y1])
end

# ---------------------------------------------------------------------------
# Light control. Each light is a NamedTuple; sensible defaults fill the rest:
#   (; type=:scene, direction=(-1,-1,-1), intensity=1.2, color=(1,1,1))
# type    : :head (at camera, follows view) | :camera | :scene (fixed in world)
# direction: for a directional scene light (ignored when positional)
# position : world point when `positional=true`
# A SCENE light with a direction is the usual "sun from over there" source.
# Pass `lights=[...]` to view_fv; with none, F3D's default headlight is used.
# ---------------------------------------------------------------------------
const _LIGHT_TYPES = Dict(
	:head   => F3D.F3D_LIGHT_TYPE_HEADLIGHT,
	:camera => F3D.F3D_LIGHT_TYPE_CAMERA_LIGHT,
	:scene  => F3D.F3D_LIGHT_TYPE_SCENE_LIGHT,
)

function add_lights!(scene, lights)
	for L in lights
		typ = _LIGHT_TYPES[get(L, :type, :scene)]
		pos = get(L, :position,  (0.0, 0.0, 0.0))
		col = get(L, :color,     (1.0, 1.0, 1.0))
		dir = get(L, :direction, (0.0, 0.0, -1.0))
		st = Ref(F3D.f3d_light_state_t(
			typ,
			(Cdouble(pos[1]), Cdouble(pos[2]), Cdouble(pos[3])),
			F3D.f3d_color_t((Cdouble(col[1]), Cdouble(col[2]), Cdouble(col[3]))),
			(Cdouble(dir[1]), Cdouble(dir[2]), Cdouble(dir[3])),
			Cint(get(L, :positional, false) ? 1 : 0),
			Cdouble(get(L, :intensity, 1.0)),
			Cint(get(L, :on, true) ? 1 : 0),
		))
		GC.@preserve st F3D.f3d_scene_add_light(scene, st)
	end
end

# Image save format from a file name's extension (default PNG when none). F3D
# supports PNG / JPG / TIF / BMP. Returns (path_with_ext, format_enum).
function _img_target(fname::AbstractString)
	ext = lowercase(splitext(fname)[2])
	isempty(ext)            && return string(fname, ".png"), F3D.PNG
	(ext in (".png",))      && return String(fname), F3D.PNG
	(ext in (".jpg",".jpeg")) && return String(fname), F3D.JPG
	(ext in (".tif",".tiff")) && return String(fname), F3D.TIF
	(ext == ".bmp")         && return String(fname), F3D.BMP
	error("unsupported image format \"$ext\"; use png, jpg, tif or bmp")
end

# Handle returned by `async=true` viewers. Holds the worker Task and the interactor
# pointer so the window can be closed from the REPL with `close!(h)`.
mutable struct ViewHandle
	task::Task
	interactor::Ptr{Cvoid}
	open::Bool
	sel::Ref{Any}            # latest rubber-band selection (set by view_points when pick=true)
end
ViewHandle(t, i, o) = ViewHandle(t, i, o, Ref{Any}(nothing))

# Registry of async viewer windows still on screen. Two LIVE f3d engines at once race
# VTK/GLEW process-global GL state during the second window's context init -> the first
# window's running event loop hits a write to read-only memory => ReadOnlyMemoryError in
# f3d_interactor_start. We can't serialise setup-of-2 against running-of-1 (window 1 is
# parked inside the blocking native start(), holding no lock), so we forbid a second live
# window instead. Lazy global (NOT top-level const) so a partial Revise reload is safe —
# same reason as the pick refs below.
_open_views() = (@isdefined(_OPEN_VIEWS) || (global _OPEN_VIEWS = ViewHandle[]); _OPEN_VIEWS)

# Cheap early-out for the public viewers: if a window is already open, warn and hand back
# the live handle BEFORE any (expensive) geometry build. Only async on-screen calls can
# collide — blocking/offscreen never spawn a second engine. Returns the handle to return
# early, or `nothing` to proceed. (_async_view re-checks as a backstop for direct callers.)
function _busy_view(; async=true, offscreen=false)
	(async && !offscreen) || return nothing
	reg = _open_views();  filter!(isopen, reg)
	isempty(reg) && return nothing
	@warn "An F3D window is already open; close it (close!(h) or its X button) before \
		   opening another. Returning the existing window."
	return reg[end]
end

"""
	selection(h::ViewHandle)

Return the rubber-band-selected points of a `view_points` window as a `GMTdataset`,
or `nothing` if nothing is selected. The raw rows are stored from the viewer's worker
thread; the `GMTdataset` is built HERE (on the calling/main thread) because GMT is not
thread-safe — never call GMT from the async worker.
"""
function selection(h::ViewHandle)
	m = h.sel[]
	return m === nothing ? nothing : GMT.mat2ds(m)
end

"""Close an async viewer window from the REPL: `close!(h)`. Cross-thread request_stop
makes the worker's native event loop exit, then it deletes the engine."""
function close!(h::ViewHandle)
	# If the worker task is already done the user closed the window (X button) and the
	# engine/interactor are ALREADY freed — calling request_stop on that dangling pointer
	# is a use-after-free that crashes the whole process. Only stop a still-running window.
	if istaskdone(h.task) || !h.open || h.interactor == C_NULL
		h.open = false
		return h
	end
	F3D.f3d_interactor_request_stop(h.interactor)
	h.open = false
	return h
end
Base.isopen(h::ViewHandle) = h.open && !istaskdone(h.task)
function Base.show(io::IO, h::ViewHandle)
	st = istaskfailed(h.task) ? "failed" : istaskdone(h.task) ? "closed" : "open"
	print(io, "ViewHandle($st)")
end

# Blocking interactor loop, run GC-SAFE. `f3d_interactor_start` is a long ccall that never
# reaches a Julia safepoint; on a worker thread it would block GC's stop-the-world (any
# allocation in the REPL → whole process hangs). `jl_gc_safe_enter` marks this thread
# collectable for the duration (it only touches VTK, no Julia heap). The @cfunction picks
# callbacks (onpick) auto re-enter gc-unsafe on entry, so they stay safe.
function _interactor_start_gcsafe(interactor, dt)
	gc_state = ccall(:jl_gc_safe_enter, Int8, ())
	try
		F3D.f3d_interactor_start(interactor, dt)
	finally
		ccall(:jl_gc_safe_leave, Cvoid, (Int8,), gc_state)
	end
end

# Raytracing ('R' / 'Shift+R') switches the live render from GL raster to CPU OSPRay
# path-tracing. Measured offscreen it is fast (60-294 ms/frame), but in the interactive
# loop it pins all cores at 100% and never returns control to the event loop -> the window
# freezes hard and killing it crashes the REPL. The root cause of the non-return was not
# isolated; until it is, strip the raytracing binds from the LIVE viewer so the key cannot
# freeze the window. Offscreen raytracing stays available via F3D.preload_raytracing()
# + the render.raytracing.* options (see examples/raytracing.md). Call AFTER
# f3d_interactor_init_bindings.
#
# TO REACTIVATE the live 'R' key: at each call site below, replace
#     _disable_raytracing_bindings(interactor)
# with
#     F3D.preload_raytracing()   # load ospray modules so 'R' does not crash on toggle
# (4 sites: view_image, view_grid, view_points). WARNING: live raytracing currently
# freezes the window as described above; only do this once that is fixed upstream.
function _disable_raytracing_bindings(interactor)
	interactor == C_NULL && return
	cnt  = Ref{Cint}(0)
	arr  = F3D.f3d_interactor_get_binds(interactor, cnt)
	arr == C_NULL && return
	try
		binds = unsafe_wrap(Array, arr, Int(cnt[]))
		doc   = Ref{F3D.f3d_binding_documentation_t}()
		for b in binds
			rb = Ref(b)
			F3D.f3d_interactor_get_binding_documentation(interactor, rb, doc)
			docstr = GC.@preserve doc unsafe_string(
				Ptr{Cchar}(Base.unsafe_convert(Ptr{F3D.f3d_binding_documentation_t}, doc)))
			occursin(r"raytrac"i, docstr) && F3D.f3d_interactor_remove_binding(interactor, rb)
		end
	finally
		F3D.f3d_interactor_free_bind_array(arr)
	end
	return
end

# Primary-monitor pixel size (Windows). SM_CXSCREEN=0, SM_CYSCREEN=1.
_screen_size() = (Int(ccall((:GetSystemMetrics, "user32"), Cint, (Cint,), 0)),
				  Int(ccall((:GetSystemMetrics, "user32"), Cint, (Cint,), 1)))

# Place the on-screen window: width = 60% of screen, centered horizontally, top at 3.5%
# from the top. Height keeps the requested window's aspect ratio (`win` = (w,h) just set),
# clamped so it doesn't run off the bottom. SKIPS offscreen windows so the savepng output
# resolution is untouched. `win` is the (width,height) tuple passed to f3d_window_set_size.
function _place_window(window, win)
	(Sys.iswindows() && window != C_NULL) || return
	F3D.f3d_window_is_offscreen(window) != 0 && return
	sw, sh = _screen_size()
	(sw > 0 && sh > 0) || return
	w = round(Int, 0.60 * sw)
	y = round(Int, 0.035 * sh)
	h = clamp(round(Int, w * win[2] / win[1]), 1, sh - y)
	x = (sw - w) ÷ 2
	F3D.f3d_window_set_size(window, Cint(w), Cint(h))
	F3D.f3d_window_set_position(window, Cint(x), Cint(y))
	return
end

# Run the blocking viewer `impl(ch)` on a worker thread; VTK's GL context AND the platform
# message pump must live on ONE thread, so the WHOLE engine/window/interactor lifecycle
# runs there. `impl` publishes its interactor pointer into `ch` once initialised, letting
# the REPL get a ViewHandle (→ `close!`) while the window stays interactive.
function _async_view(impl; sel::Ref{Any}=Ref{Any}(nothing))
	reg = _open_views()
	filter!(isopen, reg)        # drop windows the user already closed (X button or close!)
	if !isempty(reg)            # a second LIVE engine crashes VTK -> refuse, but gracefully
		@warn "An F3D window is already open; close it (close!(h) or its X button) before \
			   opening another. Returning the existing window."
		return reg[end]
	end
	ch = Channel{Ptr{Cvoid}}(1)
	h = ViewHandle(@task(nothing), C_NULL, true, sel)   # placeholder task; filled below
	h.task = Threads.@spawn try
		impl(ch)
	catch e
		@error "async view failed" exception=(e, catch_backtrace())
		rethrow()
	finally
		close(ch)                       # unblock take! if impl returned/errored before publishing
		# Window is gone and the engine/interactor freed by impl. Drop the now-dangling
		# pointer + mark closed so NOTHING in the REPL can touch freed memory later (the
		# delayed-crash-after-close). Must run on every exit path (close!, X button, error).
		h.interactor = C_NULL
		h.open = false
	end
	try
		h.interactor = take!(ch)        # the live interactor, published once impl inits it
	catch                               # channel closed before publish (offscreen, or error)
		istaskfailed(h.task) && fetch(h.task)   # surface the real error
	end
	istaskfailed(h.task) || push!(reg, h)       # track a window that actually started
	return h
end

# A simple two-source rig: a warm key light from upper-right-front and a dim
# cool fill from the left, both fixed in the world (SCENE lights).
const DEMO_LIGHTS = ((; type=:scene, direction=(-1.0, -1.0, -1.0), intensity=1.3, color=(1.0, 0.96, 0.9)),
                     (; type=:scene, direction=( 1.0,  0.3,  0.2), intensity=0.4, color=(0.8, 0.85, 1.0)))

# ---------------------------------------------------------------------------
# Grid bridge: GMT.grid2tri(G) -> GMTfv -> F3D
# ---------------------------------------------------------------------------
# GMT's `grid2tri` turns a GMTgrid into a Vector{GMTdataset} of 3-D triangle
# polygons (top surface, optionally + vertical wall / bottom). Each dataset is
# one closed triangle (4 rows, row 4 == row 1). F3D wants a single mesh, so we
# fold those triangles into a GMTfv — one independent face per triangle (no
# vertex sharing, which keeps per-face colour trivial) — then reuse view_fv.
# Faces are colour-coded by their mean z through a GMT colormap (turbo), so the
# render carries the same height shading GMT's psxy path would draw.

# z value -> "#rrggbb" via a GMTcpt colormap (Mx3, stored 0-1 or 0-255).
function z_to_hex(z, cmap::AbstractMatrix, zmin, zmax)
	N = size(cmap, 1)
	t = zmax > zmin ? (z - zmin) / (zmax - zmin) : 0.0
	i = clamp(round(Int, t * (N - 1)) + 1, 1, N)
	s = maximum(cmap) > 1.0 ? 1.0 : 255.0            # detect 0-1 vs 0-255 storage
	r = round(Int, clamp(cmap[i, 1] * s, 0, 255))
	g = round(Int, clamp(cmap[i, 2] * s, 0, 255))
	b = round(Int, clamp(cmap[i, 3] * s, 0, 255))
	return string("#", lpad(string(r, base = 16), 2, '0'),
					   lpad(string(g, base = 16), 2, '0'),
					   lpad(string(b, base = 16), 2, '0'))
end

const DEG2M = 111194.9          # ~1 geographic degree in metres (GMT's value)

const GEOG_VFRAC = 0.135        # geog auto: displayed z-range / horizontal extent.
								# 0.135 reproduces the vexag=20 look on a ~10-deg,
								# ~7.5 km-relief grid and generalises to any grid.

# Resolve the factor that multiplies z. A numeric `zscale` is used verbatim.
# `:auto` adapts to the data:
#   * GEOG grid (x,y in degrees, z assumed in metres) with a NUMERIC `vexag`:
#     z is converted to degree units (z/DEG2M) for a true 1:1 scale, then
#     multiplied by `vexag` (a real vertical exaggeration factor).
#   * GEOG grid with `vexag=:auto` (the default): pick the exaggeration that
#     makes the displayed z-range = GEOG_VFRAC x the horizontal extent — i.e.
#     a good-looking slab (~ vexag 20), no flat invisible sheet.
#   * non-geog: same flat-slab idea with `vfrac` (never a cube / invisible sheet).
function _resolve_zscale(zscale, dx, dy, dz, vfrac, isgeog, vexag)
	zscale === :auto || return float(zscale)
	(isgeog && vexag !== :auto) && return float(vexag) / DEG2M   # explicit exaggeration
	horiz = max(dx, dy)
	(dz > 0 && horiz > 0) || return 1.0
	frac = isgeog ? GEOG_VFRAC : vfrac                           # auto flat-slab
	return frac * horiz / dz
end

# Minimum decimal places so adjacent axis tick labels stay UNIQUE: VTK lays out up
# to ~`maxticks` ticks across the span, so the smallest step is ~span/maxticks; pick
# enough decimals that that step is non-zero when rounded. Over-resolving (assuming
# more ticks than VTK draws) only adds digits — it never makes labels collide.
function _axis_decimals(span::Real; maxticks::Int=10)
	s = abs(float(span))
	s <= 0 && return 0
	return clamp(ceil(Int, -log10(s / maxticks)), 0, 8)
end

# Build a 1 x n RGB palette (flat UInt8, 3n) from a GMT colormap name.
function cmap_palette(cmap, n::Int; categorical::Bool=false)
	C  = categorical ? GMT.makecpt(cmap=string(cmap), range=(1, n, 1), categorical=true) :
					   GMT.makecpt(cmap=string(cmap), range=(0.0, 1.0, 1.0 / n))
	cm = C.colormap
	s  = maximum(cm) > 1.0 ? 1.0 : 255.0          # 0-1 vs 0-255 storage
	pal = Vector{UInt8}(undef, 3n)
	@inbounds for i in 1:n
		pal[3i-2] = round(UInt8, clamp(cm[i, 1] * s, 0, 255))
		pal[3i-1] = round(UInt8, clamp(cm[i, 2] * s, 0, 255))
		pal[3i]   = round(UInt8, clamp(cm[i, 3] * s, 0, 255))
	end
	return pal
end

# True if the running libf3d carries the c/f3d_ext_*.cxx symbols (rebuilt DLL).
_has_f3d_ext() = Libdl.dlsym(Libdl.dlopen(F3D.libf3d), :f3d_ext_enable_cube_axes; throw_error=false) !== nothing
# gap #1: in-memory base-colour texture (no temp PNG). Same rebuilt DLL as f3d_ext.
_has_inmem_texture() = Libdl.dlsym(Libdl.dlopen(F3D.libf3d), :f3d_window_set_color_texture; throw_error=false) !== nothing

# Turn on the extended viewer interactions (all need a rebuilt f3d_ext DLL). Called
# AFTER the interactor exists and after the first render (cube axes needs bounds).
# Returns a zero-arg closure that disables them again (call before scene teardown).
# NOTE: rubber-band point picking is NOT wired here — it is point-cloud-only and
# lives in view_points (a frustum pick on a surface also grabs occluded points).
function _enable_extras(window, opts; cube_axes=false, coord_readout=false,
						vscale_drag=false, vscale_step=0.01, scale_handle=false, colorbar=nothing,
						cube_floor=false)         # floor plane off by default (no see-through)
	# NOTE: middle-drag pan + middle-click "set rotation centre" are NATIVE in f3d
	# (vtkF3DInteractorStyle middle=StartPan; interactor_impl middle-click picks a point
	# and animates the camera to centre it) — no f3d_ext needed once f3d.dll is rebuilt.
	(cube_axes || coord_readout || vscale_drag || scale_handle || colorbar !== nothing) || return () -> nothing
	if !_has_f3d_ext()
		@warn "extended interactions ignored: this f3d build has no f3d_ext (rebuild per f3d_GIT/c/f3d_ext_REBUILD.md)"
		return () -> nothing
	end
	# The Fledermaus-style gizmo already maps Ctrl+left-drag to vertical scale, so it
	# supersedes the plain vscale_drag observer — never install both (double-apply).
	scale_handle && (vscale_drag = false)
	coord_readout && F3D.f3d_ext_enable_coord_readout(window)
	vscale_drag   && F3D.f3d_ext_enable_vertical_scale_drag(window, opts, Cdouble(vscale_step))
	cube_axes     && F3D.f3d_ext_enable_cube_axes(window; floor=cube_floor)
	scale_handle  && F3D.f3d_ext_enable_scale_handle(window, opts, Cdouble(vscale_step))
	# Re-enable the colour bar as DRAGGABLE now that the interactor exists (the static one
	# put up on the offscreen/main path is idempotently swapped for a vtkScalarBarWidget,
	# and the 'b' key toggles it with f3d's own scalar bar). `colorbar` is a NamedTuple
	# (rgb, n, vmin, vmax[, title, fmt]) or nothing.
	colorbar !== nothing && F3D.f3d_ext_enable_colorbar(window, colorbar.rgb, colorbar.n,
		colorbar.vmin, colorbar.vmax, get(colorbar, :title, ""), get(colorbar, :fmt, "%.1f");
		draggable=true)
	return function ()
		colorbar !== nothing && F3D.f3d_ext_disable_colorbar(window)
		scale_handle  && F3D.f3d_ext_disable_scale_handle(window)
		cube_axes     && F3D.f3d_ext_disable_cube_axes(window)
		vscale_drag   && F3D.f3d_ext_disable_vertical_scale_drag(window)
		coord_readout && F3D.f3d_ext_disable_coord_readout(window)
	end
end

# Install the in-DLL rubber-band selector on `window`, routing picks to `onpick`. The
# gesture is Ctrl+right-drag (gated on Ctrl in the C side, like Ctrl+left-drag = vertical
# scale), so it is always available and never fires on a plain right-drag. Returns true
# if installed. No-op + warning when the running f3d lacks the f3d_ext symbols.
# Normalise a colour to an (r,g,b) tuple of Float64 in [0,1]. Accepts a 3-tuple/vector
# already in [0,1], or anything `_rgb3` handles (name, gray number, "r/g/b", "#hex")
# which it returns as 0-255 bytes.
function _color01(c)
	if (c isa Tuple || c isa AbstractVector) && length(c) == 3 && all(x -> x isa Real, c)
		t = Float64.(Tuple(c))
		return maximum(t) <= 1 ? t : t ./ 255   # >1 anywhere => assume 0-255 input
	end
	t = _rgb3(c)                                 # 0-255 bytes
	return (t[1] / 255, t[2] / 255, t[3] / 255)
end

# ---------------------------------------------------------------------------
# Line overlays: draw polylines (coastlines, tracks, contours) ON TOP of a
# surface or image. libf3d's mesh API has no line cells, so this goes through the
# f3d_ext renderer hatch (`f3d_ext_add_lines`). Needs the f3d_ext DLL.
#
# `lines` input forms, each treated as one polyline:
#   - a Matrix: N x 2 (z = 0) or N x 3 (column 3 is z)
#   - a GMTdataset (its `.data` matrix; a multi-segment file is a Vector{GMTdataset})
#   - a Vector/Tuple of any of the above (several polylines / layers in one call)
# ---------------------------------------------------------------------------
_collect_polylines(x::AbstractMatrix) = [Matrix{Float64}(x)]
_collect_polylines(x::GMT.GMTdataset)  = [Matrix{Float64}(x.data)]
function _collect_polylines(x)          # Vector/Tuple of the above (recurses)
	out = Matrix{Float64}[]
	for el in x
		append!(out, _collect_polylines(el))
	end
	return out
end

# Pack polylines into the flat (points, sizes) buffers the C side wants. `zfac` scales
# the z column so a line lands on a surface drawn with the same vertical scale; a 2-col
# polyline has no z and lies on z = 0.
function _lines_to_arrays(lines, zfac::Real)
	polys = _collect_polylines(lines)
	pts   = Cdouble[]
	sizes = Cuint[]
	for P in polys
		n = size(P, 1)
		n < 2 && continue
		hasz = size(P, 2) >= 3
		push!(sizes, Cuint(n))
		for i in 1:n
			push!(pts, P[i, 1], P[i, 2], hasz ? P[i, 3] * zfac : 0.0)
		end
	end
	return pts, sizes, length(pts) ÷ 3, length(sizes)
end

# Resolve a line colour to (r,g,b) Float64 in [0,1]. Accepts a colour NAME (Symbol or
# String, e.g. :red / "darkgreen" / "#ff8800" / "255/128/0" — via `parse_gmt_color`),
# a grey number, or an (r,g,b) tuple/vector ([0,1] or 0-255). `nothing` => yellow.
function _line_rgb(color)
	color === nothing && return (1.0, 1.0, 0.0)
	if color isa Symbol || color isa AbstractString
		t = parse_gmt_color(string(color));  return (t[1] / 255, t[2] / 255, t[3] / 255)
	elseif color isa Real
		g = color <= 1 ? Float64(color) : color / 255;  return (g, g, g)
	end
	return _color01(color)                       # (r,g,b) tuple/vector
end

# Draw the `lines` overlay on `window` (no-op if none / no f3d_ext). `zfac` matches the
# surface's vertical scale; `line_color` is any `_line_rgb`-able colour (default yellow);
# `line_width` is in screen pixels. `overlay=1` keeps the lines from z-fighting the surface.
function _draw_lines(window, lines, line_color, line_width, zfac)
	(lines === nothing || !_has_f3d_ext()) && return
	pts, sizes, npts, nlines = _lines_to_arrays(lines, zfac)
	npts == 0 && return
	r, g, b = _line_rgb(line_color)
	F3D.f3d_ext_add_lines(window, pts, npts, sizes, nlines, Cdouble[r, g, b],
						   nothing, Float64(line_width), Cint(1))
	F3D.f3d_window_render(window)
end
