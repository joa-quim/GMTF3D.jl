# GMTF3D

[![Build Status](https://github.com/joa-quim/GMTF3D/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/joa-quim/GMTF3D/actions/workflows/CI.yml?query=branch%3Amaster)

**An interactive 3-D visualization environment for [GMT.jl](https://github.com/GenericMappingTools/GMT.jl).**

GMTF3D turns GMT data — grids, images, point-cloud datasets and Faces–Vertices
solids — into an interactive 3-D scene (or an off-screen image) with a single call,
using the [F3D](https://f3d.app) / VTK renderer through
[F3D.jl](https://github.com/joa-quim/F3D.jl).

```julia
using GMTF3D, GMT

f3dview(GMT.peaks(120))                     # a coloured terrain surface
f3dview(gmtread("lidar.las"); color=:z)     # a point cloud
f3dview("torus")                            # a built-in GMT solid

# drape a satellite mosaic over a real DEM, oblique view
G = GMT.grdcut("@earth_relief_02m", region=(-12,0,35,45))
I = mosaic(R=G, zoom=8, provider=:goog)
f3dview(G; drape=I, azimuth=10, elevation=45)
```

`f3dview` dispatches on what you give it; the specialised viewers — `view_grid`,
`view_points`, `view_fv`, `view_image`, `view_lines` — are also callable directly.
Features include vertical exaggeration, image draping, labelled cube axes, a live
coordinate readout, a rotation/scale gizmo, colour bars, point selection and
off-screen / georeferenced export.

## ⚠️ Status — under development

This package is **work in progress**; the API may still change.

It also relies on a **patched build of the F3D library** (the out-of-tree
`f3d_ext` C-API extensions that add cube axes, coordinate readout, the scale-handle
gizmo, colour bars, coloured point sprites, line overlays and rubber-band picking).
That patched binary has so far **only been built on Windows** — on other platforms,
or on a stock F3D build, the core viewers still work but every extended interaction
is silently skipped with a warning. See the
[3-D viewer guide](docs/src/viewer3d.md) for what each layer needs and how the
`f3d_ext` DLL is built.

## Documentation

- [3-D viewing of GMT data](docs/src/viewer3d.md) — the full guide.
- [Gallery](docs/src/gallery.md) — every example with rendered images.
- [Raytracing (OSPRay)](docs/src/raytracing.md) — off-screen path-tracing notes.

## Installation

Not yet registered. It depends on the patched [F3D.jl](https://github.com/joa-quim/F3D.jl),
so both must be available (e.g. `dev`-ed) in the same environment:

```julia
using Pkg
Pkg.develop(path="path/to/F3D.jl")
Pkg.develop(path="path/to/GMTF3D")
```
