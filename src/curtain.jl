# GMTF3D — vertical "curtains" (Fledermaus-style seismic / midwater profiles):
# an image hung on a vertical wall that follows an XY path THROUGH the bathymetry
# scene. Not a viewer of its own — folded into `view_grid` (hence `f3dview`) via the
# `vcurtain=` option, so a curtain shares the grid's coordinate space AND its vertical
# scale (`mesh_view::transform_3d`), standing under / weaving through the relief.
#
# Geometry: a quad strip — for each XY point on the track, two vertices (top at zmax,
# bottom at zmin); consecutive columns joined by a quad. The image is the per-mesh
# in-memory `baseColorTexture` (gap#1 fold), marked `emissive` so the curtain shows
# true colour WITHOUT killing the grid's lighting. Each pixel COLUMN lands at a track
# position via the `spacing` rule; the rows fill the vertical [zmin, zmax] range. Pure
# Julia mesh build + the existing zero-copy texture binding => NO patched f3d core.

# Pull the XY track out of an N×2 matrix OR a GMTdataset. `GMTdataset <: AbstractArray`
# (NOT AbstractMatrix), so a single `AbstractArray` method covers both with no extra
# viewer specialisation — column indexing works the same on each.
_curtain_xy(P::AbstractArray) = (Float64.(P[:, 1]), Float64.(P[:, 2]))

# Per-column horizontal texture coordinate u ∈ [0,1] along the track.
#   :simple   — first point = first column, last point = last column, rest even (geometry ignored)
#   :distance — by cumulative chord length (a leg twice as long carries twice the image)
#   :geomatch — caller-supplied column positions `cols` (pixel indices or u in [0,1])
# Two-points (N=2) is just the degenerate case: the image spreads evenly along the segment.
function _curtain_u(px, py, spacing::Symbol, cols)
	N = length(px)
	if spacing === :geomatch
		cols === nothing && error("vcurtain spacing=:geomatch needs `cols` (per-point column positions)")
		length(cols) == N || error("`cols` must have one entry per track point ($(N)); got $(length(cols))")
		u  = Float64.(collect(cols))
		mx = maximum(u);  mx > 1 && (u = u ./ mx)   # pixel indices -> normalise to [0,1]
		return Float32.(u)
	elseif spacing === :distance
		d = zeros(Float64, N)
		@inbounds for i in 2:N
			d[i] = d[i-1] + hypot(px[i]-px[i-1], py[i]-py[i-1])
		end
		tot = d[end];  tot <= 0 && (tot = 1.0)
		return Float32.(d ./ tot)
	elseif spacing === :simple
		return Float32.(N == 1 ? [0.0] : collect(0:N-1) ./ (N - 1))
	end
	error("unknown vcurtain spacing=$(spacing); choose :simple, :distance or :geomatch")
end

# Build the ribbon mesh: 2N shared vertices (top/bottom per column), N-1 quads. Normals
# are horizontal (perp to the track in XY); irrelevant for the emissive drape but filled
# so the mesh is well-formed. `flipv` swaps the vertical image sense (image first scanline
# -> top by default; verified correct against the in-memory texture orientation).
#
# `topz` (clip): per-column top z. `nothing` => flat top at `zmax` (the whole image). When
# given (the bathymetry depth sampled along the track) each column's top vertex sits at the
# seafloor instead of `zmax`, and its texture v is sampled at that height — so the part of
# the image ABOVE the G surface is simply not drawn (the wall's top edge hugs the relief).
function _curtain_mesh(px, py, u, zmin, zmax, flipv::Bool, topz=nothing)
	N = length(px)
	N >= 2 || error("a vcurtain needs at least 2 track points; got $N")
	topz === nothing || length(topz) == N ||
		error("clip topz must have one entry per track point ($(N)); got $(length(topz))")
	span = zmax - zmin
	vat(z) = (f = Float32((z - zmin) / span); flipv ? (1f0 - f) : f)   # texture v at world height z
	points    = Vector{Float32}(undef, 3 * 2N)
	normals   = Vector{Float32}(undef, 3 * 2N)
	texcoords = Vector{Float32}(undef, 2 * 2N)
	nx = zeros(Float64, N);  ny = zeros(Float64, N)
	@inbounds for i in 1:N-1
		dx = px[i+1]-px[i];  dy = py[i+1]-py[i]
		L  = hypot(dx, dy);  L <= 0 && (L = 1.0)
		hx = dy / L;  hy = -dx / L
		nx[i] += hx;  ny[i] += hy;  nx[i+1] += hx;  ny[i+1] += hy
	end
	@inbounds for i in 1:N
		L = hypot(nx[i], ny[i]);  L <= 0 && (nx[i] = 1.0; L = 1.0)
		nxi = nx[i] / L;  nyi = ny[i] / L
		# Top vertex follows the clip surface (clamped into [zmin, zmax]); bottom stays at zmin.
		ztop = topz === nothing ? zmax : clamp(Float64(topz[i]), zmin, zmax)
		ti = 2i - 1;  bi = 2i
		points[3ti-2] = px[i];  points[3ti-1] = py[i];  points[3ti] = ztop
		points[3bi-2] = px[i];  points[3bi-1] = py[i];  points[3bi] = zmin
		normals[3ti-2] = nxi;  normals[3ti-1] = nyi;  normals[3ti] = 0f0
		normals[3bi-2] = nxi;  normals[3bi-1] = nyi;  normals[3bi] = 0f0
		texcoords[2ti-1] = u[i];  texcoords[2ti] = vat(ztop)
		texcoords[2bi-1] = u[i];  texcoords[2bi] = vat(zmin)
	end
	sides   = UInt32[];  sizehint!(sides,   N - 1)
	indices = UInt32[];  sizehint!(indices, 4 * (N - 1))
	@inbounds for i in 1:N-1
		ti = 2i - 1;  bi = 2i;  ti2 = 2(i+1) - 1;  bi2 = 2(i+1)
		push!(sides, UInt32(4))
		push!(indices, UInt32(ti-1), UInt32(bi-1), UInt32(bi2-1), UInt32(ti2-1))
	end
	return (; points, normals, texcoords, sides, indices)
end

# Image -> (data, w, h, comps) byte buffer in VTK orientation (row 0 = bottom of the
# picture), ready for the per-mesh in-memory texture. A GMTimage folds through the shared
# `img_to_texbuf`; a String path is loaded BY F3D ITSELF (`f3d_image_new_path`, no gmtread)
# and its buffer copied out (F3D's image is bottom-up like img_to_texbuf, so the same
# `flipv` convention holds for both sources).
_curtain_texbuf(I::GMT.GMTimage) = img_to_texbuf(I)
function _curtain_texbuf(path::AbstractString)
	isfile(path) || error("vcurtain image file not found: $(path)")
	ip = F3D.f3d_image_new_path(String(path))
	ip == C_NULL && error("F3D failed to load curtain image: $(path)")
	w = Int(F3D.f3d_image_get_width(ip));  h = Int(F3D.f3d_image_get_height(ip))
	c = Int(F3D.f3d_image_get_channel_count(ip))
	src = F3D.f3d_image_get_content(ip)
	src == C_NULL && (F3D.f3d_image_delete(ip); error("F3D loaded an empty curtain image: $(path)"))
	data = Vector{UInt8}(undef, w * h * c)
	unsafe_copyto!(pointer(data), Ptr{UInt8}(src), w * h * c)
	F3D.f3d_image_delete(ip)
	return (data, w, h, c)
end

# Validate vcurtain spec(s) WITHOUT building anything — called synchronously at the public
# entry (view_fv / view_grid) BEFORE the async worker spawns and BEFORE any F3D engine /
# window is created. On a bad spec it prints ONE clean message (no stacktrace) and the
# caller bails with `|| return nothing` — no half-built window left to block / kill the REPL.
# `_check_vcurtain` returns true when OK, false (after printing) when not.
_vcurtain_problem(::Nothing) = ""
function _vcurtain_problem(spec::NamedTuple)::String     # "" == OK
	hasproperty(spec, :image)  || return "vcurtain spec needs an `image` (GMTimage or file path)"
	hasproperty(spec, :path)   || return "vcurtain spec needs a `path` (N×2 matrix or GMTdataset)"
	hasproperty(spec, :zrange) || return "vcurtain spec needs `zrange=(zmin, zmax)`"
	img = spec.image
	if img isa AbstractString
		isfile(img) || return "vcurtain image file not found: $(img)"
	elseif !(img isa GMT.GMTimage)
		return "vcurtain `image` must be a GMTimage or a file-path String; got $(typeof(img))"
	end
	z = spec.zrange
	(length(z) >= 2 && z[2] > z[1]) ||
		return "vcurtain zrange must be (zmin, zmax) with zmax > zmin; got $(z)"
	P = spec.path
	(P isa AbstractArray && size(P, 1) >= 2 && size(P, 2) >= 2) ||
		return "vcurtain path must be an N×2 (N≥2) matrix or a GMTdataset; got $(typeof(P))"
	return ""
end
function _vcurtain_problem(specs)::String                # vector/tuple of specs: first problem wins
	for s in specs
		p = _vcurtain_problem(s);  isempty(p) || return p
	end
	return ""
end

function _check_vcurtain(vc)::Bool
	p = _vcurtain_problem(vc)
	isempty(p) && return true
	printstyled(stderr, p, '\n'; color = :light_red, bold = true)   # clean message, no stacktrace
	return false
end

# Add ONE curtain (a NamedTuple spec) into an already-built scene, sharing the grid's
# vertical scale `zs` so it lines up with the relief. Spec fields:
#   image   :: GMTimage | String     (required)
#   path    :: N×2 matrix | GMTdataset (required; N=2 => straight two-points curtain)
#   zrange  :: (zmin, zmax)           (required; TRUE z units, same as the grid data)
#   spacing :: Symbol = :distance     (:simple | :distance | :geomatch)
#   cols    :: per-point columns      (:geomatch only)
#   flipv   :: Bool = false
function _add_curtain!(scene, engine, opts, spec::NamedTuple, zs::Real, idx::Int)
	hasproperty(spec, :image)  || error("vcurtain spec needs an `image` (GMTimage or file path)")
	hasproperty(spec, :path)   || error("vcurtain spec needs a `path` (N×2 matrix or GMTdataset)")
	hasproperty(spec, :zrange) || error("vcurtain spec needs `zrange=(zmin, zmax)`")
	zmin, zmax = Float64(spec.zrange[1]), Float64(spec.zrange[2])
	zmax > zmin || error("vcurtain zrange must be (zmin, zmax) with zmax > zmin; got $(spec.zrange)")
	spacing = hasproperty(spec, :spacing) ? spec.spacing : :distance
	cols    = hasproperty(spec, :cols)    ? spec.cols    : nothing
	flipv   = hasproperty(spec, :flipv)   ? spec.flipv   : false

	topz = hasproperty(spec, :topz) ? spec.topz : nothing   # per-column clip surface (resolved by view_grid)
	px, py = _curtain_xy(spec.path)
	u = _curtain_u(px, py, spacing, cols)
	m = _curtain_mesh(px, py, u, zmin, zmax, flipv, topz)
	data, tw, th, tc = _curtain_texbuf(spec.image)
	tc == 4 && F3D.f3d_options_set_as_bool(opts, "render.effect.blending.enable", Cint(1))

	# Share the grid's GPU vertical scale so the curtain rises/falls WITH the relief.
	mvt = (zs > 0 && zs != 1.0) ? (; scale=(1.0, 1.0, Float64(zs))) : nothing
	add_mesh_view!(scene, engine, m.points, m.normals, m.texcoords, m.sides, m.indices;
				   name="curtain$(idx)", texture=(; data, w=tw, h=th, comps=tc, emissive=true),
				   transform=mvt) ||
		error("f3d_scene_add_mesh_view failed for vcurtain $(idx)")
	return nothing
end

# Dispatch on the `vcurtain` kwarg: nothing / one spec / a vector|tuple of specs. Separate
# methods keep the type instability of "matrix-or-GMTdataset path" OFF the big viewer body.
_add_curtains!(scene, engine, opts, ::Nothing, zs::Real) = nothing
_add_curtains!(scene, engine, opts, spec::NamedTuple, zs::Real) = _add_curtain!(scene, engine, opts, spec, zs, 1)
function _add_curtains!(scene, engine, opts, specs, zs::Real)
	for (i, s) in enumerate(specs)
		_add_curtain!(scene, engine, opts, s, zs, i)
	end
	return nothing
end

# ─── clip-to-surface resolution (called by view_grid, which has the grid) ──────────────
# A curtain spec with `clip=true` (or `clip=:surface`) gets its top edge cut to the grid
# surface: densify the track so the cut follows real topography, sample the grid z along
# it, and bake that into the spec as `path` (densified) + `topz` (per-column seafloor z).
# Curtains without clip pass straight through. `_curtain_mesh` then drops the wall above z.
_clip_truthy(c) = c === true || c === :surface || c === :clip || c === :grid
_resolve_vcurtain_clip(::Nothing, G) = nothing
_resolve_vcurtain_clip(spec::NamedTuple, G) = _clip_one(spec, G)
_resolve_vcurtain_clip(specs, G) = map(s -> _clip_one(s, G), specs)

function _clip_one(spec::NamedTuple, G)
	(hasproperty(spec, :clip) && _clip_truthy(spec.clip)) || return spec
	px, py = _curtain_xy(spec.path)
	n  = hasproperty(spec, :clip_n) ? Int(spec.clip_n) : 300   # column resolution of the cut
	dx, dy = _densify_polyline(px, py, n)
	z  = Float64.(GMT.grdtrack(G, [dx dy]).data[:, 3])          # seafloor z sampled along the track
	return merge(spec, (; path = hcat(dx, dy), topz = z))       # densified path + per-column clip surface
end

# Resample a polyline (px,py) to `n` points evenly spaced by arc length, so each output
# column is a real position along the track (the clip needs density the 2-point input lacks).
function _densify_polyline(px, py, n::Int)
	N = length(px)
	N == 1 && return (fill(Float64(px[1]), n), fill(Float64(py[1]), n))
	d = zeros(Float64, N)
	@inbounds for i in 2:N;  d[i] = d[i-1] + hypot(px[i]-px[i-1], py[i]-py[i-1]);  end
	tot = d[end]
	tot <= 0 && return (fill(Float64(px[1]), n), fill(Float64(py[1]), n))
	xo = Vector{Float64}(undef, n);  yo = Vector{Float64}(undef, n)
	j = 1
	@inbounds for (k, sk) in enumerate(range(0.0, tot, length = n))
		while j < N && d[j+1] < sk;  j += 1;  end
		seg = d[j+1] - d[j];  t = seg <= 0 ? 0.0 : (sk - d[j]) / seg
		xo[k] = px[j] + t * (px[j+1] - px[j])
		yo[k] = py[j] + t * (py[j+1] - py[j])
	end
	return (xo, yo)
end
