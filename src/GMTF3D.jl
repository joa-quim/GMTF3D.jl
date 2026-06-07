module GMTF3D

# 3-D viewers bridging GMT.jl data (grids, images, datasets, GMTfv solids) to F3D.
# Originally examples/gmt_solids.jl in F3D.jl; split here into one unit per viewer
# plus a shared `common.jl`.
#
#   common.jl   – shared mesh/colour/lighting/async/extras/line/probe machinery
#   fv.jl       – view_fv: GMTfv solids & meshes (+ poly2fv, SOLIDS catalogue)
#   grid.jl     – view_grid: GMTgrid surfaces (+ grid2tri→fv bridges)
#   image.jl    – view_image: flat 2-D image viewer
#   points.jl   – view_points: point clouds (+ rubber-band pick)
#   lines.jl    – view_lines: standalone 3-D polylines
#   f3dview.jl  – f3dview: single front-door dispatcher over all viewers

using F3D
using GMT
# dlopen/dlsym to probe for optional f3d_ext symbols (rubber-band pick, etc.). Reached
# through Base rather than `using Libdl` so it needs NO extra package dependency — the
# Libdl stdlib is always present here as Base.Libc.Libdl.
const Libdl = Base.Libc.Libdl

export f3dview, view_fv, view_grid, view_image, view_points, view_lines,
       selection, close!

include("common.jl")
include("fv.jl")
include("grid.jl")
include("image.jl")
include("points.jl")
include("lines.jl")
include("f3dview.jl")

end # module GMTF3D
