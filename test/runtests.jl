using GMTF3D
using Test

@testset "GMTF3D.jl" begin
    # Viewer wrapper defaults (ported from F3D.jl's test_view_grid_defaults.jl,
    # which used to drive examples/gmt_solids.jl).
    include("test_view_grid_defaults.jl")

    # Pure (no DLL / no window) helper guards for the two mesh_view features.
    include("test_mesh_view_api.jl")        # zero-copy add_mesh_view! + scivis palette
    include("test_transform_matrix.jl")     # per-mesh GPU transform (vertical exaggeration)
end
