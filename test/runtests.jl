using GMTF3D
using Test

@testset "GMTF3D.jl" begin
    # Viewer wrapper defaults (ported from F3D.jl's test_view_grid_defaults.jl,
    # which used to drive examples/gmt_solids.jl).
    include("test_view_grid_defaults.jl")
end
