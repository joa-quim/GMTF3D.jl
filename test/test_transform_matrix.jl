# Regression guard for the per-mesh `mesh_view` transform (vertical-exaggeration via GPU
# 4x4 UserMatrix instead of baking z*scale into the verts). See memory mesh-view-transform-3d.
#
# `_transform_matrix(transform)` builds the row-major 4x4 fed to the C `transform_matrix`
# field. It is pure (no DLL / no window) so it runs everywhere GMTF3D loads. The C side
# reads an ALL-ZERO matrix as identity, so `nothing` must map to all zeros (NOT a real
# identity) — getting that wrong silently disables every transform. The layout is:
#   (sx 0  0  tx   0 sy 0  ty   0 0 sz tz   0 0 0 1)   row-major
# 1-based indices: sx=1 sy=6 sz=11; tx=4 ty=8 tz=12; homogeneous [16]=1.

@testset "_transform_matrix (mesh_view per-mesh transform)" begin
    tm = GMTF3D._transform_matrix

    # nothing => all-zero sentinel (C reads it as identity). NOT a literal identity matrix.
    @test tm(nothing) === ntuple(_ -> 0.0, 16)

    # NamedTuple scale=(1,1,vexag) — the common vertical-exaggeration case.
    m = tm((; scale = (1, 1, 5)))
    @test m[1]  == 1.0          # sx
    @test m[6]  == 1.0          # sy
    @test m[11] == 5.0          # sz (vexag)
    @test m[16] == 1.0          # homogeneous
    @test all(m[i] == 0.0 for i in (2,3,4,5,7,8,9,10,12,13,14,15))   # off-diagonal + translate clear

    # Scalar scale => uniform on all three axes.
    @test tm((; scale = 2)) === (2.0,0.0,0.0,0.0, 0.0,2.0,0.0,0.0, 0.0,0.0,2.0,0.0, 0.0,0.0,0.0,1.0)

    # translate lands in the 4th column (tx,ty,tz at 4,8,12).
    mt = tm((; translate = (10, 20, 30)))
    @test (mt[4], mt[8], mt[12]) == (10.0, 20.0, 30.0)
    @test (mt[1], mt[6], mt[11], mt[16]) == (1.0, 1.0, 1.0, 1.0)   # default scale 1

    # A 16-element iterable is used verbatim (row-major), as Float64.
    raw = collect(1.0:16.0)
    @test collect(tm(raw)) == raw

    # Wrong length is rejected (would silently corrupt the C struct otherwise).
    @test_throws ArgumentError tm(collect(1.0:9.0))

    # The viewer wrapper actually exposes the transform: _view_fv_impl carries it through.
    @test :transform in Base.kwarg_decl(only(methods(GMTF3D.add_mesh_view!)))
end
