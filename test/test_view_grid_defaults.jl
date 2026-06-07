# Regression guard for the rotation-centre gizmo (Fledermaus scale handle: compass/tilt
# rings + vertical cone) DEFAULT. Ported from F3D.jl's test/test_view_grid_defaults.jl
# when the viewer code moved here out of examples/gmt_solids.jl.
#
# The gizmo default once silently regressed in the old wrapper layer — view_grid stopped
# flipping it on and the rings vanished — and NO test caught it, because only the low-level
# f3d_ext_enable_scale_handle C binding was covered (F3D.jl/test/test_f3d_ext.jl), and it
# kept passing. The wrapper layer the user actually calls had zero coverage.
#
# The default now lives, identically, in every viewer implementation: the surface viewer
# `_view_fv_impl` (used by view_grid / view_fv), the point-cloud viewer `_view_points_impl`
# (used by view_points) and the standalone line viewer `_view_lines_impl`. This asserts the
# default is ON for all of them AND that no viewer hardcodes it OFF — catching a single
# viewer's default drifting away from the others (the desync that caused the regression).

@testset "rotation-ring gizmo default (scale_handle ON for every viewer)" begin
    # Runtime: scale_handle is a keyword of each viewer implementation.
    for impl in (GMTF3D._view_fv_impl, GMTF3D._view_points_impl, GMTF3D._view_lines_impl)
        kws = Base.kwarg_decl(only(methods(impl)))
        @test :scale_handle in kws
    end

    # Source: each viewer binds scale_handle to a literal `true` default (whitespace
    # tolerant), and NONE binds it to `false` (which would reintroduce the desync the
    # original regression caused).
    srcdir = dirname(pathof(GMTF3D))
    for unit in ("fv.jl", "points.jl", "lines.jl")
        src = read(joinpath(srcdir, unit), String)
        @test occursin(r"scale_handle::Bool\s*=\s*true", src)
        @test !occursin(r"scale_handle::Bool\s*=\s*false", src)
    end

    # The surface + point viewers both define their impl here with the shared default —
    # identical procedure, no per-viewer divergence.
    @test occursin(r"function\s+_view_fv_impl\b"s, read(joinpath(srcdir, "fv.jl"), String))
    @test occursin(r"function\s+_view_points_impl\b"s, read(joinpath(srcdir, "points.jl"), String))
end
