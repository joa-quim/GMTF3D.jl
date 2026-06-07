```@meta
CurrentModule = GMTF3D
```

# GMTF3D

Documentation for [GMTF3D](https://github.com/Joa-quim/GMTF3D.jl) — high-level 3-D
viewers that bridge [GMT.jl](https://github.com/GenericMappingTools/GMT.jl) data
(grids, images, point clouds, Faces–Vertices solids) to the
[F3D](https://f3d.app) / VTK renderer via [F3D.jl](https://github.com/joa-quim/F3D.jl).

```julia
using GMTF3D, GMT

f3dview(GMT.peaks(100))    # one entry point; dispatches to the right viewer
```

- **[3-D viewing of GMT data](viewer3d.md)** — the full guide to `f3dview`,
  `view_grid`, `view_points`, `view_fv`, `view_image`, `view_lines` and the extended
  `f3d_ext` interactions.
- **[Raytracing (OSPRay)](raytracing.md)** — off-screen path-tracing and the live
  `R`-key situation.

## API

```@index
```

```@autodocs
Modules = [GMTF3D]
```
