# Interactive 3-D viewing of GMT data

This guide documents the high-level 3-D viewers in **GMTF3D**, built on top of
[F3D.jl](https://github.com/joa-quim/F3D.jl) (a Julia wrapper of the
[F3D](https://f3d.app) / VTK C API). They turn GMT objects — grids, point-cloud
datasets and Faces–Vertices solids — into an interactive VTK window (or an
off-screen image) with a single call.

> **Loading.** The viewers live in the **GMTF3D** package, a thin glue layer over
> [F3D.jl](https://github.com/joa-quim/F3D.jl) and
> [GMT.jl](https://github.com/GenericMappingTools/GMT.jl). The public names
> (`f3dview`, `view_grid`, `view_points`, `view_fv`, `view_image`, `view_lines`) are
> exported by `using GMTF3D`.

```julia
using GMTF3D
using GMT          # the GMT data constructors used throughout (peaks, gmtread, …)
```

## Contents

- [Two layers: stock vs. extended](#two-layers-stock-vs-extended)
- [Quick start](#quick-start)
  - [`f3dview` — one entry point](#f3dview--one-entry-point)
- [`view_grid` — grids / terrain](#view_grid--grids--terrain)
- [`view_points` — point clouds](#view_points--point-clouds)
- [`view_fv` — solids and meshes](#view_fv--solids-and-meshes)
- [Vertical scale (exaggeration)](#vertical-scale-exaggeration)
- [Draping images over a surface](#draping-images-over-a-surface)
- [Camera, background, materials, export](#camera-background-materials-export)
- [Non-blocking (async) windows](#non-blocking-async-windows)
- [Extended interactions (`f3d_ext`)](#extended-interactions-f3d_ext)
  - [Cube axes](#cube-axes)
  - [Coordinate readout](#coordinate-readout)
  - [Vertical-scale drag](#vertical-scale-drag)
  - [Rotation-ring gizmo (scale handle)](#rotation-ring-gizmo-scale-handle)
  - [Rubber-band point selection](#rubber-band-point-selection)
- [Keyboard reference](#keyboard-reference)
- [The low-level `f3d_ext` C API](#the-low-level-f3d_ext-c-api)
- [Building / deploying the `f3d_ext` DLL](#building--deploying-the-f3d_ext-dll)

---

## Two layers: stock vs. extended

Everything splits into two layers:

| Layer | Needs | What you get |
|-------|-------|--------------|
| **Stock** | the shipped libf3d binary | geometry, colour, draping, lights, materials, camera, off-screen export, the orientation gizmo and origin grid |
| **Extended** (`f3d_ext`) | a libf3d rebuilt with `c/f3d_ext_*.cxx` | labelled **cube axes**, **coordinate readout**, **vertical-scale drag**, the **rotation-ring gizmo**, **colour bar**, coloured **point sprites**, **line overlays**, **rubber-band point selection** |

The viewer probes the running binary at run time (`Libdl.dlsym`). On a stock
binary the extended options are silently ignored with a one-line warning; nothing
else changes. See [Building / deploying the `f3d_ext` DLL](#building--deploying-the-f3d_ext-dll).

---

## Quick start

```julia
using GMTF3D, GMT

f3dview(GMT.peaks(100))                          # a surface (grid)
f3dview("@earth_relief_10m", region=(-12,-6,35,40))   # real DEM (read by GMT)

D = GMT.gmtread("lidar.las")                     # an N×≥3 table
f3dview(D; color=:z, cmap=:turbo)                # a coloured point cloud

f3dview("torus")                                 # a built-in GMT solid
```

### `f3dview` — one entry point

`f3dview(x; kwargs...)` dispatches on what you hand it and forwards every keyword to
the matching viewer:

| `x` | goes to | shows |
|-----|---------|-------|
| `GMTgrid` or a grid filename/remote name | [`view_grid`](#view_grid--grids--terrain) | a surface |
| `GMTdataset` (or vector) | `view_points` / `view_lines` / `view_fv` by geometry | cloud / lines / polygons |
| `GMTfv` | [`view_fv`](#view_fv--solids-and-meshes) | a solid / mesh |
| `GMTimage` | `view_image` | image as a flat textured quad |
| `"name"` (`"cube"`, `"sphere"`, `"torus"`, …, or `"grid"`/`"peaks"`/a filename) | the matching viewer | a built-in GMT solid |

A bare solid — by name (`f3dview("torus")`) or a hand-built `GMTfv`
(`f3dview(torus())`) — is z-ramp coloured (`color=true`) and lit with `DEMO_LIGHTS`;
pass `color=false` to opt out. The underlying `view_grid` / `view_points` / `view_fv`
remain callable directly.

All viewers open a window and run **`async=true`** by default (REPL stays free; see
[Non-blocking windows](#non-blocking-async-windows)). Pass `offscreen=true`/`saveimg=...`
for no window, or `async=false` to block until closed.

---

## `view_grid` — grids / terrain

```julia
view_grid(G; cmap=:turbo, zscale=:auto, vfrac=0.2, vexag=:auto, ncolor=256,
          thickness=0.0, isbase=false, downsample=0, ratio=0.01,
          bottom=false, wall_only=false, top_only=false, geog=false,
          drape=GMTimage(), drape_clip=false, outside=:drop, outside_color=200,
          colorbar=true, kwargs...)
```

`G` is a `GMTgrid` or a filename/remote name GMT can read. The grid is
triangulated (`GMT.grid2tri` → `grid2fv`) into a coloured surface and handed to
[`view_fv`](#view_fv--solids-and-meshes), so **every `view_fv` keyword also works
here** (camera, lights, materials, export, the extended interactions …).

Grid-specific defaults applied by `view_grid` (override any of them):

- **`up="+Z"`** — grids are `z = f(x,y)`, so the scene is laid flat with **Z up**
  (X and Y on the floor, Z the vertical/elevation axis). The stock default `+Y`
  would stand the grid up like a wall.
- **`cube_axes=true`**, **`coord_readout=true`**, **`vscale_drag=true`**,
  **`scale_handle=true`** — labelled axes, cursor readout, Ctrl+left-drag scale and
  the rotation-ring gizmo are all on by default (all need `f3d_ext`).
- **`azimuth=-40`, `elevation=25`** — an oblique view so the floor, vertical axis and
  gizmo are visible from the start (a flat top/edge-on view looks empty).

Colouring: faces are coloured by mean *z* through a GMT colormap
(`cmap`, `ncolor` levels). Colours always key off the **true** (unscaled) *z*.

Solid / wall options are forwarded to `GMT.grid2tri`: `thickness`, `bottom`,
`wall_only`, `top_only`, `isbase`, `downsample`, `ratio`.

```julia
view_grid(G)                          # flat-shaded surface, cube axes, Z up
view_grid(G; vexag=10)                # 10× vertical exaggeration
view_grid(G; cube_axes=false)         # turn the cube axes off
view_grid(G; coord_readout=true, vscale_drag=true)   # add the extra gestures
view_grid(G; thickness=500)           # extrude to a solid block
```

---

## `view_points` — point clouds

```julia
view_points(D; color=:z, class=nothing, cmap=nothing, ncolor=256, clim=nothing,
            categorical=false, pointsize=1, sprites=false, splat="sphere",
            zscale=:auto, vfrac=0.2, vexag=:auto, isgeog=nothing,
            up="+Z", cube_axes=true, coord_readout=true,
            vscale_drag=true, vscale_step=0.01, scale_handle=true, colorbar=true,
            onpick=nothing, pickcolor=(0.83,0.83,0.83), async=true, <view/export kwargs>)
```

`D` is a `GMTdataset` (an `N×≥3` table of `x y z [...]`).

**Colour**
- `color=:z` — value driving the colour: `:z` (column 3, the default), a column
  index `Int` (`1`=x, `2`=y, …), or a length-`N` vector.
- `class=...` — nominal/categorical source (e.g. LIDAR ASPRS class): one distinct
  colour per unique value; implies `categorical=true` and a qualitative cmap.
- `cmap=:turbo`, `ncolor=256`, `clim=(lo,hi)` (default = data min/max).

**Points**
- `pointsize=1` — size in pixels (`1` = true single-pixel points).
- `sprites=false` — round splats coloured by value (gap #9). The sprite mapper
  ignores texture coords, so per-point colour is baked on via
  `f3d_ext_color_point_sprites` — **needs an f3d built with `c/f3d_ext_*.cxx`**; on a
  stock binary the splats render uniform grey (a warning is shown).
- `splat="sphere"` — sprite shape: `"sphere"` (shaded disc), `"circle"` (flat ring),
  or `"gaussian"` (soft, can look fuzzy/dark on a dark background).

Vertical scale, camera and export keywords match `view_grid`/`view_fv`.

```julia
view_points(D)                            # colour by depth
view_points(D; class=:class, cmap=:categorical)   # LIDAR classes
view_points(D; vexag=10, pointsize=2)
```

Rubber-band selection (`onpick`, `pick`) is documented under
[Rubber-band point selection](#rubber-band-point-selection).

---

## `view_fv` — solids and meshes

```julia
view_fv(fv; title, size=(1600,1200), bg=(0.1,0.1,0.15), lights=(),
        flat=false, axes=true, grid=true, _edges=false, _edge_width=1.0,
        up="+Z", cube_axes=true, coord_readout=true,
        vscale_drag=true, vscale_step=0.01, scale_handle=true, colorbar=nothing,
        offscreen=false, saveimg="", mapexport="",
        azimuth=-40, elevation=25, topdown=false,
        drape=GMTimage(), drape_clip=false, drape_emis=GMTimage(),
        drape_light=1.0, drape_unlit=false,
        metallic=NaN, roughness=NaN, emissive=nothing, georef=nothing,
        lines=nothing, line_color=nothing, line_width=2.0, line_zfac=1.0, L=nothing,
        async=true)
```

`fv` is a `GMT.GMTfv` (Faces–Vertices). This is the workhorse the other two
viewers funnel into; the most useful general knobs:

- `flat=false` — flat (per-face) vs. smooth (per-vertex normal) shading.
- `_edges=false` / `_edge_width=1.0` — draw mesh wireframe edges (also the live `e` key).
- `axes=true` — orientation gizmo (corner X/Y/Z). `grid=true` — origin floor grid.
- `cube_axes` / `coord_readout` / `vscale_drag` / `scale_handle` — on by default (see
  [Extended interactions](#extended-interactions-f3d_ext)).
- `lines`/`L` — overlay GMT line data on the mesh (`line_color`, `line_width`, `line_zfac`).
- `lights=()` — see [materials](#camera-background-materials-export).

To show a bundled GMT solid use `f3dview("torus")` (or `f3dview(torus())` on a
hand-built `GMTfv`); see [`f3dview`](#f3dview--one-entry-point). It z-ramp colours and
lights the solid, then calls `view_fv`.

---

## Vertical scale (exaggeration)

Geographic grids have X/Y in degrees and Z in metres; at a raw 1:1 scale the
relief is an invisible sheet, while a cube-fit makes fake mountains. The viewer
therefore never puts x,y and z on the same raw scale unless you ask:

- **`zscale=:auto`** (default) computes a sensible vertical scale:
  - **geographic** data (auto-detected via `GMT.isgeog`, or forced with
    `isgeog=`/`geog=`): a true 1:1 metres→degrees scale times `vexag`.
  - **non-geographic**: a flat slab whose relief is `vfrac` of the horizontal
    span (`vfrac=0.2` → relief ≈ 20 % of width).
- **`vexag`** — vertical exaggeration multiplier. `:auto` (geographic) picks an
  exaggeration that yields a pleasant relief; a number is a literal multiplier.
- **`zscale=<number>`** overrides everything (e.g. `zscale=1` = raw 1:1).

Colours always key off the **true** *z*, regardless of the display scale.

```julia
view_grid(G; vexag=20)         # geographic DEM, 20× relief
view_grid(G; zscale=1)         # raw 1:1
view_points(D; vfrac=0.3)      # non-geographic cloud, taller slab
```

> Interactively you can also exaggerate/flatten with **Ctrl + left-drag** —
> see [Vertical-scale drag](#vertical-scale-drag).

---

## Draping images over a surface

Drape a `GMTimage` (satellite tile, geological map, …) over a grid surface:

```julia
view_grid(G; drape=I)                       # stretch image over the whole surface
view_grid(G; drape=I, drape_clip=true)      # honour image coords: paint only G ∩ I
```

`drape_clip=true` (same-CRS, efficient) crops both grid and image to their bbox
intersection and stretch-drapes the overlap. The `outside` keyword controls the
grid area **not** covered by the image:

| `outside` | uncovered area |
|-----------|----------------|
| `:drop` (default) | not shown (grid cropped to the overlap) |
| `:shade` | flat `outside_color` fill, relief-shaded, no edges |
| `:shademesh` | `:shade` + mesh edges on top |
| `:transparent` | see-through |

`outside_color=200` is the grey level (0–255) of the fill. `drape_light=1.0` is the
emissive factor for the draped image (1.0 = true colour, lower = more relief
shading).

---

## Camera, background, materials, export

**Camera**
- `azimuth=-40`, `elevation=25` — orbit / tilt (degrees) applied after framing
  (an oblique default so the scene isn't seen edge-on).
- `topdown=false` — orthographic straight-down view (north up), good for maps.

**Background / size**
- `bg=(0.1,0.1,0.15)` — background RGB (0–1). `size=(w,h)` — window pixels.

**Materials (PBR; only set when given)**
- `metallic`, `roughness` — scalars 0–1.
- `emissive` — scalar grey or `(r,g,b)` self-illumination factor.
- `lights=(...)` — a tuple of light specs, e.g.
  `lights=[(; type=:scene, direction=(-1,-1,-1), intensity=1.3)]`
  (`type` ∈ `:headlight`, `:camera`, `:scene`). No lights → F3D's default headlight.

**Export (no window)**
- `offscreen=true` — render without opening a window.
- `saveimg="out.png"` — save the frame; format from the extension (png/jpg/tif/bmp).
- `mapexport="map.tiff"` — one-shot georeferenceable map: forces orthographic
  top-down + off-screen and writes the file.
- `georef=(x0,x1,y0,y1,proj)` — with a `.tiff` target, write a GeoTIFF (set
  automatically by `view_grid` from the grid's range/projection).

```julia
view_grid(G; offscreen=true, saveimg="relief.png")
view_grid(G; mapexport="relief.tiff")          # georeferenced GeoTIFF
view_grid(G; azimuth=-30, elevation=25)         # oblique
```

Off-screen **raytracing** (OSPRay path-tracing) is also available — see
[`F3D.preload_raytracing`](raytracing.md). It is fast off-screen (60–294 ms/frame) but
the live `R` key is disabled in the viewers (it freezes the window).

> The [extended interactions](#extended-interactions-f3d_ext) (cube axes,
> readout, drag, pick) are **interactive only** — they are not added to an
> off-screen/`saveimg` render.

---

## Non-blocking (async) windows

By default `view_grid`/`view_points`/`view_fv` run `async=true`: the viewer runs on
a worker thread and you get a `ViewHandle` back immediately, so the REPL stays
free. (Off-screen renders ignore `async` — there is no window.)

```julia
h = view_grid(G)        # returns at once; window is live
isopen(h)               # true while the window is open
close!(h)               # ask the window to close
```

Requires Julia started with more than one thread
(`julia -t auto`, or `JULIA_NUM_THREADS`). Pass `async=false` for the classic
blocking call.

---

## Extended interactions (`f3d_ext`)

These need a libf3d rebuilt with the `c/f3d_ext_*.cxx` sources. Enable them per
viewer with boolean keywords; on a stock binary they warn and no-op.

### Cube axes

Labelled bounding-box axes (numbered X/Y/Z ticks) sized to the **exact data
extent** (the F3D floor grid / skybox / gizmo are excluded). **On by default in
all viewers** (`view_grid` / `view_fv` / `view_points`); pass `cube_axes=false` to
turn off.

```julia
view_grid(G)                       # cube axes on by default
view_fv(fv)                        # and here
view_points(D; cube_axes=false)    # opt out
```

The look is composed from flags (via the C API / `f3d_ext_enable_cube_axes`):

| flag | meaning | default |
|------|---------|---------|
| `EDGES`   | cube edges + X/Y tick labels | on |
| `FLOOR`   | semi-transparent bottom plane | on |
| `ZLABELS` | Z (elevation) tick labels | on |
| `GRID`    | gridlines on every face (the "walls") | off |

For a flat-on-the-floor layout the scene must be **Z-up** (`up="+Z"`), which
`view_grid` sets automatically.

### Coordinate readout

Live world **X/Y/Z under the cursor**, shown bottom-left. `coord_readout=true`.

### Vertical-scale drag

**Ctrl + left-drag** to exaggerate (drag up) / flatten (drag down) the relief in
real time. `vscale_drag=true`; `vscale_step=0.01` is the change per pixel.

> When the rotation-ring gizmo is on (the default), it takes over vertical scaling and
> `vscale_drag` is automatically turned off — the two are mutually exclusive.

### Rotation-ring gizmo (scale handle)

A Fledermaus-style gizmo at the rotation centre, **on by default** in `view_grid`,
`view_points` and `view_fv` (`scale_handle=true`; pass `scale_handle=false` to hide it,
which re-enables `vscale_drag`). Drag its parts:

- **vertical arrowhead** — vertical scale (exaggerate / flatten);
- **horizontal arrows** — tilt (elevation);
- **compass ring** — azimuth (spin about the vertical).

### Rubber-band point selection

Select points by dragging a box. **Point-cloud only** — `view_points`. It is
deliberately **not** wired into surfaces (`view_grid`/`view_fv`), because the
frustum pick also returns points hidden behind the surface.

It is **always on** (no arming, no option): **Ctrl + right-drag** a box to select;
plain right-drag stays normal navigation. Selected points are overlaid in `pickcolor`
(light grey by default). Re-dragging the same box deselects; **Ctrl + Z** undoes.

By default the picked rows are stashed for you — read them back as a `GMTdataset`:

```julia
h   = view_points(D)         # async; Ctrl+right-drag in the window to select
sel = selection(h)           # the picked rows as a GMTdataset
# async=false instead returns the selection directly when the window closes:
sel = view_points(D; async=false)
```

For full control pass `onpick = rows -> ...`, called with the row indices into
`D.data` on every change (this replaces the default stash):

```julia
view_points(D; onpick = rows -> @show rows)
```

---

## Keyboard reference

The viewer keeps F3D's default bindings (**except** the raytracing keys `R` /
`Shift+R`, which are stripped — see the note below) and adds a few. Frequently useful:

| Key | Action |
|-----|--------|
| left-drag / wheel | rotate / zoom |
| `Ctrl + Z` / `Ctrl + Y` | set scene up-direction `+Z` / `+Y` (F3D built-in) |
| `1`–`9` | preset camera views (front, top, isometric, …) |
| `E` | toggle mesh edges · `G` grid · `X` axis gizmo · `B` scalar bar |
| **`Ctrl + right-drag`** | **rubber-band point select** (point clouds; ours) |
| **`Ctrl + Z`** | **undo last selection** *(while a selection exists)* (ours) |
| **`Ctrl + left-drag`** | **vertical-scale drag** (ours; only when the gizmo is off) |
| drag the rotation-ring gizmo | vertical scale / tilt / azimuth (ours; on by default) |
| `Ctrl + Q` | quit |

> `Ctrl + Z` is overloaded: F3D binds it to "up-direction +Z", while the rubber-band
> extension uses it for selection undo. When the selector is enabled, undo wins.
>
> **Raytracing keys removed.** F3D's `R` (raytracing) / `Shift+R` (denoiser) binds are
> stripped from the live viewers: enabling raytracing in the interactive window pins all
> CPU cores and freezes it. Off-screen raytracing still works — see
> [`F3D.preload_raytracing`](raytracing.md).

---

## The low-level `f3d_ext` C API

The high-level viewers wrap these. They are exported from `F3D` (Julia wrappers in
F3D.jl's `src/libf3d.jl`) and resolve to symbols in a rebuilt `f3d_c_api` DLL.

```julia
# Cube axes
f3d_ext_enable_cube_axes(window; edges=true, floor=true, grid=false, zlabels=true)
f3d_ext_enable_cube_axes(window, flags::Integer)   # F3D.F3D_EXT_CUBE_AXES_* | …
f3d_ext_disable_cube_axes(window)

# Coordinate readout
f3d_ext_enable_coord_readout(window);  f3d_ext_disable_coord_readout(window)

# Vertical-scale drag (opts = engine options handle; step per pixel)
f3d_ext_enable_vertical_scale_drag(window, opts, step);  f3d_ext_disable_vertical_scale_drag(window)

# Rotation-ring gizmo / scale handle (opts = engine options; sensitivity per pixel)
f3d_ext_enable_scale_handle(window, opts, sensitivity);  f3d_ext_disable_scale_handle(window)

# Colour bar (right edge)
f3d_ext_enable_colorbar(window, rgb, ncolors, vmin, vmax, title="", fmt="%.1f"; draggable=false)
f3d_ext_disable_colorbar(window)

# Rubber-band selection
f3d_ext_enable_rubber_band_pick(window, callback, user_data)   # installs DISARMED
f3d_ext_set_rubber_band_armed(window, armed)                   # 1 = arm, 0 = disarm
f3d_ext_get_rubber_band_armed(window)                          # 1 / 0
f3d_ext_disable_rubber_band_pick(window)
# one-shot area pick (no observers): returns a heap id array, free with f3d_ext_free_ids
f3d_ext_area_pick_points(window, x0, y0, x1, y1, count)
```

`callback` is a C function pointer
`void(const size_t* ids, size_t count, void* user_data)`; ids are 0-based VTK point
ids. Constants: `F3D.F3D_EXT_CUBE_AXES_EDGES|FLOOR|GRID|ZLABELS|DEFAULT`.

Further `f3d_ext` symbols (wrapped in F3D.jl's `src/libf3d.jl`) cover point sprites
(`f3d_ext_color_point_sprites`, `f3d_ext_round_points`, `f3d_ext_enable_sprite_size_keys`,
`f3d_ext_enable_sprite_zscale_sync`), line overlays (`f3d_ext_add_lines` /
`_remove_lines` / `_clear_lines`) and per-cell edges (`f3d_ext_set_edge_visibility`,
`f3d_ext_add_cell_edges`, …).

A low-level demo of the raw `f3d_ext` C API lives in F3D.jl's
[`examples/extensions_demo.jl`](https://github.com/joa-quim/F3D.jl/blob/master/examples/extensions_demo.jl).

---

## Building / deploying the `f3d_ext` DLL

The extended features are out-of-tree C-API files (`f3d_GIT/c/f3d_ext_*.cxx`,
`f3d_ext.h`) compiled **inside** the f3d source tree so they can reach the private
renderer/interactor; their symbols land in the existing `f3d_c_api.dll`. Outline
(Windows):

1. copy the edited `c/f3d_ext_*.cxx` + `f3d_ext.h` into the superbuild f3d `src/c/`;
2. build the `c_api` target (MSVC `vcvars64` + CMake, Release);
3. copy `build/bin/f3d_c_api.dll` over the one bundled in
   `F3D.jl/src/lib/F3D-*/bin/`.

See `f3d_GIT/c/f3d_ext_REBUILD.md` for the exact commands. On a stock (un-rebuilt)
binary everything in this guide still works except the extended interactions,
which warn once and no-op.
