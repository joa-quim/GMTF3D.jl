# GMTF3D viewer gallery
# ─────────────────────
# One FUNCTION per example — no globals. Each builds its own data locally and
# forwards `; kw...` to the viewer, so you can either:
#   • open an interactive window:   grid_surface()
#   • export it instead:            grid_surface(offscreen=true, saveimg="grid.png")
#
# The viewers are async by default (`h = grid_surface()` returns at once; `close!(h)`).
# The run-all block at the bottom walks them blocking, one window at a time.
#
#   julia --project=. examples/gallery.jl
#
# `export_gallery(dir)` renders every example off-screen to a PNG — this is what the
# docs "Gallery" page is built from (docs/make_gallery.jl).
#
# Swap the demo_* builders for real data any time, e.g.
#   demo_grid()  -> gmtread("@earth_relief_10m", region=(-12,-6,35,40))
#   demo_image() -> gmtread("satellite.tif")
#   demo_cloud() -> gmtread("lidar.las")

using GMTF3D, GMT

# ── data builders (self-contained, offline) ───────────────────────────────
demo_grid() = GMT.peaks(120)                            # a GMTgrid surface

function demo_image(G=demo_grid(); half::Bool=false)    # smooth RGB gradient image
    #return gmtread(GMT.TESTSDIR * "assets/table_flowers.jpg")
    xr = G.range
    ny, nx = 160, 200
    A = Array{UInt8}(undef, ny, nx, 3)
    for j in 1:ny, i in 1:nx
        A[j, i, 1] = round(UInt8, 255i / nx)
        A[j, i, 2] = round(UInt8, 255j / ny)
        A[j, i, 3] = round(UInt8, 255 * (1 - i / nx))
    end
    x1 = half ? (xr[1] + xr[2]) / 2 : xr[2]           # `half` covers only the SW quadrant
    y1 = half ? (xr[3] + xr[4]) / 2 : xr[4]
    return mat2img(A; x = [xr[1], x1], y = [xr[3], y1])
end

function demo_cloud(n = 8000)                          # a GMTdataset point cloud
    x = 8 .* (rand(n) .- 0.5)
    y = 8 .* (rand(n) .- 0.5)
    z = 1.5 .* exp.(-(x.^2 .+ y.^2) ./ 6) .* cos.(1.3 .* x)
    return mat2ds(hcat(x, y, z))
end

# ── 1. Grid / terrain surface ─────────────────────────────────────────────
grid_surface(;     kw...) = f3dview(demo_grid(); kw...)                 # coloured surface, cube axes, Z-up
grid_exaggerated(; kw...) = f3dview(demo_grid(); vfrac = 0.6, kw...)    # taller relief (vfrac: non-geo)
grid_block(;       kw...) = f3dview(demo_grid(); thickness = 2, kw...)  # extrude grid to a solid block

# ── 2. Image ──────────────────────────────────────────────────────────────
image_plane(; kw...) = f3dview(demo_image(); kw...)               # image as a flat textured quad

# ── 3. Grid + image drape ─────────────────────────────────────────────────
drape_stretch(; kw...)     = (G = demo_grid(); f3dview(G; drape = demo_image(G), kw...))   # stretch over all
# Image covering only PART of the grid — `outside` rules the uncovered area:
drape_drop(; kw...)        = (G = demo_grid(); view_grid(G; drape = demo_image(G; half=true), drape_clip=true, outside=:drop, kw...))
drape_shade(; kw...)       = (G = demo_grid(); view_grid(G; drape = demo_image(G; half=true), drape_clip=true, outside=:shade, kw...))
drape_shademesh(; kw...)   = (G = demo_grid(); view_grid(G; drape = demo_image(G; half=true), drape_clip=true, outside=:shademesh, kw...))
drape_transparent(; kw...) = (G = demo_grid(); view_grid(G; drape = demo_image(G; half=true), drape_clip=true, outside=:transparent, kw...))
# Real DEM + Google satellite mosaic draped on it, oblique camera (NEEDS NETWORK).
drape_satellite(; kw...) = (G = GMT.grdcut("@earth_relief_02m", region=(-12, 0, 35, 45));
                            I = mosaic(R=G, zoom=8, provider=:goog);
                            f3dview(G; drape=I, azimuth=10, elevation=45, kw...))

# ── 3b. Vertical curtain (Fledermaus seismic / midwater profile) ───────────
# A real seismic-profile image hung as a vertical wall UNDER the bathymetry, along
# a ship track. `vcurtain` is an option of view_grid/f3dview: the image follows the
# XY `path` (here a straight two-point track in the Gulf of Cádiz) over a fixed
# `zrange` (0 down to -10000 m). The image is given as a FILE PATH so F3D loads it
# itself (no gmtread import); a GMTimage works too. `clip=true` cuts the wall's top
# edge to the seafloor so the part above the relief is dropped. NEEDS NETWORK.
const SEISMIC_IMG = joinpath(@__DIR__, "assets", "seismic_E46.jpg")   # bundled WSW–ENE profile
grid_vcurtain(; kw...) = (G = GMT.grdcut("@earth_relief_04m", region=(-12, 0, 35, 45));
    f3dview(G; vcurtain = (; image = SEISMIC_IMG,
                           path = [-11.045 36.077; -6.9846 36.1846],   # two-point track
                           zrange = (-10000.0, 0.0), clip = true), kw...))

# ── 4. Point cloud ────────────────────────────────────────────────────────
cloud_z(;       kw...) = f3dview(demo_cloud(); pointsize=3, kw...)           # coloured by z (the default)
cloud_sprites(; kw...) = f3dview(demo_cloud(); sprites=true, pointsize=6, kw...)   # round splats (needs f3d_ext)

# ── 5. Solids / volumetric bodies ─────────────────────────────────────────
solid(name::AbstractString; kw...) = f3dview(name; kw...)          # named GMT solid (z-ramp coloured)
solid_fv(; kw...) = f3dview(torus(r=2.0, R=6.0); kw...)         # hand in your own GMTfv directly

# All examples, in display order, as (name => function).
const GALLERY = [
    "grid_surface"      => grid_surface,
    "grid_exaggerated"  => grid_exaggerated,
    "grid_block"        => grid_block,
    "image_plane"       => image_plane,
    "drape_stretch"     => drape_stretch,
    "drape_drop"        => drape_drop,
    "drape_shade"       => drape_shade,
    "drape_shademesh"   => drape_shademesh,
    "drape_transparent" => drape_transparent,
    "drape_satellite"   => drape_satellite,
    "grid_vcurtain"     => grid_vcurtain,
    "cloud_z"           => cloud_z,
    "cloud_sprites"     => cloud_sprites,
    "solid_torus"       => (; kw...) -> solid("torus"; kw...),
    "solid_sphere"      => (; kw...) -> solid("sphere"; kw...),
    "solid_revolve"     => (; kw...) -> solid("revolve"; kw...),
    "solid_loft"        => (; kw...) -> solid("loft"; kw...),
    "solid_extrude"     => (; kw...) -> solid("extrude"; kw...),
    "solid_fv"          => solid_fv,
]

# Printed reference for every example: what it shows, the DEMO call (offline,
# default data) and a hypothetical REAL-DATA call. Grouped by facility.
# `(function-name, one-line description, demo call, real-data call)`.
const GALLERY_DEMOS = [
    "Grid / terrain surface" => [
        ("grid_surface",     "coloured surface, cube axes, Z-up, rotation gizmo",
            "f3dview(GMT.peaks(120))",
            "f3dview(gmtread(\"@earth_relief_10m\", region=(-12,-6,35,40)))"),
        ("grid_exaggerated",  "taller relief (vfrac on non-geo; vexag on geographic)",
            "f3dview(GMT.peaks(120); vfrac=0.6)",
            "f3dview(dem; vexag=20)"),
        ("grid_block",        "extrude the grid down to a solid block",
            "f3dview(GMT.peaks(120); thickness=2)",
            "f3dview(dem; thickness=500)"),
    ],
    "Image" => [
        ("image_plane",       "an image as a flat textured quad",
            "f3dview(demo_image())",
            "f3dview(gmtread(\"satellite.tif\"))"),
    ],
    "Grid + image drape" => [
        ("drape_stretch",     "stretch an image over the whole surface",
            "f3dview(demo_grid(); drape=demo_image())",
            "f3dview(dem; drape=gmtread(\"sat.tif\"))"),
        ("drape_drop",        "partial cover: crop grid to the image overlap",
            "view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:drop)",
            "view_grid(dem; drape=geotiff, drape_clip=true, outside=:drop)"),
        ("drape_shade",       "partial cover: uncovered area = flat grey, relief-shaded",
            "view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:shade)",
            "view_grid(dem; drape=geotiff, drape_clip=true, outside=:shade)"),
        ("drape_shademesh",   "partial cover: grey fill + wireframe on the uncovered area",
            "view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:shademesh)",
            "view_grid(dem; drape=geotiff, drape_clip=true, outside=:shademesh)"),
        ("drape_transparent", "partial cover: uncovered area see-through",
            "view_grid(demo_grid(); drape=demo_image(half=true), drape_clip=true, outside=:transparent)",
            "view_grid(dem; drape=geotiff, drape_clip=true, outside=:transparent)"),
        ("drape_satellite",   "real DEM (earth_relief) with a Google satellite mosaic draped, oblique view (needs network)",
            "G = GMT.grdcut(\"@earth_relief_02m\", region=(-12,0,35,45))\nI = mosaic(R=G, zoom=8, provider=:goog)\nf3dview(G; drape=I, azimuth=10, elevation=45)",
            "G = GMT.grdcut(\"@earth_relief_02m\", region=(-12,0,35,45)); f3dview(G; drape=mosaic(R=G, zoom=8, provider=:goog))"),
    ],
    "Vertical curtain (seismic / midwater profile)" => [
        ("grid_vcurtain",     "a real seismic profile hung under the bathymetry along a ship track, clipped to the seafloor (needs network)",
            "img = joinpath(pkgdir(GMTF3D), \"examples\", \"assets\", \"seismic_E46.jpg\")\nG = GMT.grdcut(\"@earth_relief_04m\", region=(-12,0,35,45))\nf3dview(G; vcurtain=(; image=img, path=[-11.045 36.077; -6.9846 36.1846], zrange=(-10000,0), clip=true))",
            "f3dview(dem; vcurtain=(; image=gmtread(\"seismic.tif\"), path=ship_track, zrange=(-10000,0), clip=true))"),
    ],
    "Point cloud" => [
        ("cloud_z",           "points coloured by z (the default)",
            "f3dview(demo_cloud(); pointsize=3)",
            "f3dview(gmtread(\"lidar.las\"); color=:z)"),
        ("cloud_sprites",     "round shaded splats (needs the f3d_ext DLL)",
            "f3dview(demo_cloud(); sprites=true, pointsize=6)",
            "f3dview(gmtread(\"lidar.las\"); sprites=true, class=:class)"),
    ],
    "Solids / volumetric bodies (each takes its generator's own parameters)" => [
        ("solid_torus",       "a torus by name; r,R,nx,ny are torus()'s own kwargs",
            "f3dview(\"torus\")",
            "f3dview(\"torus\"; r=2, R=8, nx=200)"),
        ("solid_cube",        "a cube; r is the circumradius (centre→vertex)",
            "f3dview(\"cube\")",
            "f3dview(\"cube\"; r=3)"),
        ("solid_sphere",      "a sphere; n is the subdivision level",
            "f3dview(\"sphere\")",
            "f3dview(\"sphere\"; n=4)"),
        ("solid_revolve",     "surface of revolution of a profile curve",
            "f3dview(\"revolve\")",
            "f3dview(\"revolve\"; curve=mycurve)"),
        ("solid_loft",        "lofted surface between two 3-D curves",
            "f3dview(\"loft\")",
            "f3dview(\"loft\"; C1=ring1, C2=ring2)"),
        ("solid_extrude",     "extrude a 2-D/3-D polygon by a height",
            "f3dview(\"extrude\")",
            "f3dview(\"extrude\"; shape=country_poly, h=0.2)"),
        ("solid_fv",          "hand in your own GMTfv directly",
            "f3dview(torus(r=2, R=6))",
            "f3dview(flatfv(\"@earth_day_01m\", shape=Dit, thickness=0.5))"),
    ],
]

"""
	gallery_help([io=stdout])

Print every gallery example: a one-line description, its DEMO call (runs offline on
the `demo_*` builders) and a hypothetical REAL-DATA call (swap in `gmtread(...)` etc).
"""
function gallery_help(io::IO = stdout)
    println(io, "GMTF3D gallery — demos (offline) and real-data equivalents")
    println(io, "Run a demo with no args (opens a window) or `; offscreen=true, saveimg=\"x.png\"`.")
    for (group, items) in GALLERY_DEMOS
        println(io, "\n", group)
        println(io, repeat("─", length(group)))
        for (name, what, demo, real) in items
            println(io, "  • ", rpad(name, 17), " ", what)
            println(io, "      demo: ", demo)
            println(io, "      real: ", real)
        end
    end
    return nothing
end

# Export every example to a PNG (used to verify renders and to build the docs Gallery
# page); returns the list of (name, file) actually written.
function export_gallery(dir=tempdir(); kw...)
    out = Tuple{String,String}[]
    for (name, fn) in GALLERY
        p = joinpath(dir, "gallery_$name.png")
        try
            fn(; offscreen=true, saveimg=p, kw...)
            isfile(p) && push!(out, (name, p))
        catch e
            @warn "gallery example failed" name exception=e
        end
    end
    return out
end

# Run interactively: walk every example, one blocking window at a time.
if (abspath(PROGRAM_FILE) == @__FILE__)
    for (name, fn) in GALLERY
        println("→ ", name, "  (close the window to continue)")
        fn(; async=false)
    end
end
