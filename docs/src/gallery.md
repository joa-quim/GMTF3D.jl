# Gallery

Every example below is produced by `examples/gallery.jl`, rendered
off-screen with `export_gallery`. Each builds its data offline with a
`demo_*` helper; swap in `gmtread(...)` for real data. Open any example
interactively by calling its function (e.g. `grid_surface()`), or export
it with `; offscreen=true, saveimg="out.png"`.

```julia
using GMTF3D, GMT
```

## Grid / terrain surface

### `grid_surface`

coloured surface, cube axes, Z-up, rotation gizmo.

```julia
f3dview(GMT.peaks(120))
```

![grid_surface](assets/gallery/gallery_grid_surface.png)

### `grid_exaggerated`

taller relief (vfrac on non-geo; vexag on geographic).

```julia
f3dview(GMT.peaks(120); vfrac=0.6)
```

![grid_exaggerated](assets/gallery/gallery_grid_exaggerated.png)

### `grid_block`

extrude the grid down to a solid block.

```julia
f3dview(GMT.peaks(120); thickness=2)
```

![grid_block](assets/gallery/gallery_grid_block.png)

## Image

### `image_plane`

an image as a flat textured quad.

```julia
f3dview(demo_image())
```

![image_plane](assets/gallery/gallery_image_plane.png)

## Grid + image drape

### `drape_stretch`

stretch an image over the whole surface.

```julia
f3dview(demo_grid(); drape=demo_image())
```

![drape_stretch](assets/gallery/gallery_drape_stretch.png)

### `drape_drop`

partial cover: crop grid to the image overlap.

```julia
view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:drop)
```

![drape_drop](assets/gallery/gallery_drape_drop.png)

### `drape_shade`

partial cover: uncovered area = flat grey, relief-shaded.

```julia
view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:shade)
```

![drape_shade](assets/gallery/gallery_drape_shade.png)

### `drape_shademesh`

partial cover: grey fill + wireframe on the uncovered area.

```julia
view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:shademesh)
```

![drape_shademesh](assets/gallery/gallery_drape_shademesh.png)

### `drape_transparent`

partial cover: uncovered area see-through.

```julia
view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:transparent)
```

![drape_transparent](assets/gallery/gallery_drape_transparent.png)

### `drape_satellite`

real DEM (earth_relief) with a Google satellite mosaic draped, oblique view (needs network).

```julia
G = GMT.grdcut("@earth_relief_02m", region=(-12,0,35,45))
I = mosaic(R=G, zoom=8, provider=:goog)
f3dview(G; drape=I, azimuth=10, elevation=45)
```

![drape_satellite](assets/gallery/gallery_drape_satellite.png)

## Vertical curtain (seismic / midwater profile)

### `grid_vcurtain`

a real seismic profile hung under the bathymetry along a ship track, clipped to the seafloor (needs network).

```julia
img = joinpath(pkgdir(GMTF3D), "examples", "assets", "seismic_E46.jpg")
G = GMT.grdcut("@earth_relief_04m", region=(-12,0,35,45))
f3dview(G; vcurtain=(; image=img, path=[-11.045 36.077; -6.9846 36.1846], zrange=(-10000,0), clip=true))
```

![grid_vcurtain](assets/gallery/gallery_grid_vcurtain.png)

## Point cloud

### `cloud_z`

points coloured by z (the default).

```julia
f3dview(demo_cloud(); pointsize=3)
```

![cloud_z](assets/gallery/gallery_cloud_z.png)

### `cloud_sprites`

round shaded splats (needs the f3d_ext DLL).

```julia
f3dview(demo_cloud(); sprites=true, pointsize=6)
```

![cloud_sprites](assets/gallery/gallery_cloud_sprites.png)

## Solids / volumetric bodies (each takes its generator's own parameters)

### `solid_torus`

a torus by name; r,R,nx,ny are torus()'s own kwargs.

```julia
f3dview("torus")
```

![solid_torus](assets/gallery/gallery_solid_torus.png)

### `solid_sphere`

a sphere; n is the subdivision level.

```julia
f3dview("sphere")
```

![solid_sphere](assets/gallery/gallery_solid_sphere.png)

### `solid_revolve`

surface of revolution of a profile curve.

```julia
f3dview("revolve")
```

![solid_revolve](assets/gallery/gallery_solid_revolve.png)

### `solid_loft`

lofted surface between two 3-D curves.

```julia
f3dview("loft")
```

![solid_loft](assets/gallery/gallery_solid_loft.png)

### `solid_extrude`

extrude a 2-D/3-D polygon by a height.

```julia
f3dview("extrude")
```

![solid_extrude](assets/gallery/gallery_solid_extrude.png)

### `solid_fv`

hand in your own GMTfv directly.

```julia
f3dview(torus(r=2, R=6))
```

![solid_fv](assets/gallery/gallery_solid_fv.png)

