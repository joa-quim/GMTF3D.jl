# GMTF3D — f3dview: single front-door dispatcher over all the viewers,
# plus the GMTdataset geometry sniffers it dispatches on.

# SINGLE SOURCE OF TRUTH for the rotation-centre gizmo (Fledermaus scale handle: compass /
# tilt rings + vertical cone). BOTH viewers — view_grid (via _view_fv_impl) and view_points —
# use this as their `scale_handle` kwarg default, so the rings are enabled by the EXACT same
# procedure and can never desync. (They once did: _view_fv_impl defaulted false while
# view_points defaulted true, and the gizmo silently vanished from view_grid.) The actual
# enable runs through the shared `_enable_extras` helper in both viewers.

# kwargs that belong to poly2fv (everything else flows to the viewer).
const _POLY2FV_KW = (:cmap, :zscale, :vfrac, :vexag, :isgeog, :ncolor, :triangulate)
_merge_points(D) = (length(D) == 1) ? D[1] : GMT.mat2ds(reduce(vcat, (d.data for d in D)))

"""
	f3dview(x; kwargs...)

Single front door to the F3D viewers: dispatch on the type of `x` (or, for a
`String`, its content) and forward to the matching specialised viewer. Every
`kwargs...` is passed straight through, so **the keywords are those of the viewer
that ends up handling `x`** — see each one's own docstring.

# Dispatch
| `x` | viewer | notes |
|-----|--------|-------|
| `GMTgrid` | [`view_grid`](@ref) | triangulated surface from a grid |
| `GMTfv` | [`view_fv`](@ref) | a Faces–Vertices solid / mesh |
| `GMTimage` | [`view_image`](@ref) | image as a flat textured quad |
| `GMTdataset` | sniff `.geom` | see below |
| `Vector{<:GMTdataset}` | sniff `.geom` of the 1st | points are merged into one cloud |
| `String` | see below | grid file, `"grid"`/`"peaks"` demo, or a named solid |

# `GMTdataset` geometry
The dataset's WKB `.geom` decides the viewer (falling back, when `.geom` is unset,
to closure — a ring whose first xy equals its last is treated as a polygon):
- **point / multipoint** → [`view_points`](@ref) (a coloured point cloud).
- **line** → [`view_lines`](@ref) (3-D polylines, needs the `f3d_ext` DLL).
- **polygon** → [`poly2fv`](@ref) → [`view_fv`](@ref). One mesh face per polygon,
  any corner count; pass `triangulate=true` for concave / non-planar polygons.
  The `poly2fv` keywords (`cmap, zscale, vfrac, vexag, isgeog, ncolor, triangulate`)
  are routed to it; all other keywords go to `view_fv`.

# `String`
`f3dview("file.grd")` opens a grid file (anything `GMT` can read); `"grid"` or
`"peaks"` shows the `GMT.peaks()` demo; otherwise the name is looked up in the
`SOLIDS` registry — the primitives `cube, sphere, torus, cylinder, icosahedron,
octahedron, dodecahedron, tetrahedron` and the generators `revolve, loft, extrude`
(`keys(SOLIDS)` for the live list).

A named solid takes **the parameters of its GMT generator** (`cube`, `sphere`,
`torus`, `cylinder`, `revolve`, …) — any kwarg that is NOT a viewer keyword is
forwarded straight to the generator, with the generator's **own defaults**
(nothing is restated here). Viewer keywords (`flat`, `azimuth`, `offscreen`, …)
go to the viewer:
```julia
f3dview("cube")                       # the generator's default cube()
f3dview("cube"; r = 3)                # r = circumradius (centre→vertex), side = 2r/√3
f3dview("sphere"; n = 4)              # sphere's own `n` (subdivision); r stays default
f3dview("torus"; R = 8, nx = 200, flat = true, azimuth = 30)   # geom -> torus, flat/azimuth -> viewer
f3dview("revolve"; curve = mycurve)   # your own profile (else a demo profile)
f3dview("extrude"; shape = mypoly, h = 2)
```
Generators that have a REQUIRED positional with no default (`cylinder` r,h;
`revolve` curve; `loft` C1,C2; `extrude` shape,h) fall back to a demo sample when
you omit it. A named solid is z-ramp coloured (`color=true`) and lit with `DEMO_LIGHTS`.

# Examples
```julia
f3dview(GMT.peaks(150))							# a grid surface
f3dview(I)										# a GMTimage
f3dview(G; drape=I, drape_clip=true, outside=:shademesh)	# image draped on a grid
f3dview(D; color=:z, pointsize=3)				# a point cloud coloured by z
f3dview("torus");  f3dview("revolve")			# a named GMT solid / generator demo
f3dview(torus(r=2, R=6))						# or hand in your own GMTfv directly
```
See also [`view_grid`](@ref), [`view_points`](@ref), [`view_fv`](@ref),
[`view_image`](@ref), [`view_lines`](@ref).
"""
f3dview(G::GMT.GMTgrid;  kwargs...) = view_grid(G;  kwargs...)
f3dview(I::GMT.GMTimage; kwargs...) = view_image(I; kwargs...)

# A bare GMTfv (e.g. `f3dview(torus())`) carries no per-face colour, so — like the
# named-solid path `f3dview("torus")` — z-ramp colour it and light it with DEMO_LIGHTS
# by default. `have_color` skips fv's that a real GMT producer already coloured
# (`flatfv`, `poly2fv`, ...); pass `color=false` to opt out.
function f3dview(fv::GMT.GMTfv; color::Bool=true, lights=DEMO_LIGHTS, kwargs...)
	color && !have_color(fv) && colorize_by_z!(fv)
	return view_fv(fv; lights=lights, kwargs...)
end

function f3dview(D::GMT.GMTdataset; kwargs...)
	k = _ds_kind(D)
	(k === :points) && return view_points(D; kwargs...)
	(k === :lines)  && return view_lines(D; kwargs...)
	pk = filter(p -> p.first in _POLY2FV_KW, kwargs)          # polys -> mesh
	vk = filter(p -> !(p.first in _POLY2FV_KW), kwargs)
	return view_fv(poly2fv([D]; pk...); vk...)
end

function f3dview(D::Vector{<:GMT.GMTdataset}; kwargs...)
	isempty(D) && error("empty GMTdataset vector")
	k = _ds_kind(D[1])
	(k === :points) && return view_points(_merge_points(D); kwargs...)
	(k === :lines)  && return view_lines(D; kwargs...)
	pk = filter(p -> p.first in _POLY2FV_KW, kwargs)
	vk = filter(p -> !(p.first in _POLY2FV_KW), kwargs)
	return view_fv(poly2fv(D; pk...); vk...)
end

# String: a grid file path, the `grid`/`peaks` demo, or a named solid from SOLIDS.
# A named solid takes ITS OWN parameters (e.g. `f3dview("cube"; r=3)`,
# `f3dview("torus"; R=8, nx=200)`). Routing is by the VIEWER's keyword set: a kwarg that
# is a view_fv keyword goes to the viewer, EVERY OTHER kwarg goes to the solid builder,
# which forwards it untouched to the GMT generator (so the generator's own defaults
# stand — we never restate them). `color=true` runs the demo z-ramp on the solid.
# (`_view_fv_impl`'s keyword set is read at call time — it is defined later in this file.)
_view_fv_kw() = (Base.kwarg_decl(only(methods(_view_fv_impl)))..., :async)
function f3dview(name::String; color::Bool=true, lights=DEMO_LIGHTS, kwargs...)
	lname = lowercase(name)
	(lname in ("grid", "peaks")) && return view_grid(GMT.peaks(); kwargs...)
	isfile(name)                 && return view_grid(name; kwargs...)
	builder = get(SOLIDS, lname, nothing)
	(builder === nothing) &&
		error("unknown solid '$name'. Choose one of: $(join(sort(collect(keys(SOLIDS))), ", "))")
	vkeys = _view_fv_kw()
	bk = filter(p -> !(p.first in vkeys), kwargs)            # solid params -> generator
	vk = filter(p ->  (p.first in vkeys), kwargs)            # viewer kwargs -> view_fv
	fv = builder(; bk...)
	color && colorize_by_z!(fv)
	return view_fv(fv; title="F3D — GMT $name", lights=lights, vk...)
end

# Geometry helpers for f3dview's GMTdataset dispatch (the docstring is on f3dview).
# WKB geometry code -> kind. Strip the 25D flag bit (0x80000000) and fold the
# Z/ZM thousands (1001, 3003, ...) so every variant maps to its base 1..6:
# 1/4 = (multi)point, 2/5 = (multi)line, 3/6 = (multi)polygon.
_geom_kind(g::Integer) = (c = (g & 0x7fffffff) % 1000;
	c in (1, 4) ? :points : c in (2, 5) ? :lines : c in (3, 6) ? :polys : :unknown)

# Resolve a dataset to :points / :lines / :polys. Prefer the stored geometry; when
# unset (geom 0), fall back to closure — a ring whose first xy == last xy is a polygon.
function _ds_kind(D::GMT.GMTdataset)
	k = _geom_kind(Int(D.geom))
	(k === :unknown) || return k
	(size(D.data, 1) >= 4 && @views D.data[1, 1:2] == D.data[end, 1:2]) ? :polys : :points
end
