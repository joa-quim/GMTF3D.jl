# Regression guard for the zero-copy `mesh_view` C-API path (add_mesh_view! + scivis
# colouring that replaced the palette-texture hack). See memory gmtf3d-mesh-view-bindings.
#
# `_palette_colormap_str` turns a flat UInt8 RGB palette into the F3D scivis colormap
# control-point string ("x,r,g,b,..." all in [0,1], evenly spaced over [0,1]). It is pure
# (no DLL / no window) so it runs everywhere GMTF3D loads. A drift here silently mis-colours
# every grid/point surface on the zero-copy path.

@testset "mesh_view C-API path (palette colormap + add_mesh_view! shape)" begin
    cm = GMTF3D._palette_colormap_str

    # Single colour => one control point pinned at x=0.
    @test cm(UInt8[128, 64, 32], 1) == "0.0,$(128/255),$(64/255),$(32/255)"

    # Two colours black->white => endpoints x=0 and x=1, channels normalised to [0,1].
    @test cm(UInt8[0,0,0, 255,255,255], 2) == "0.0,0.0,0.0,0.0,1.0,1.0,1.0,1.0"

    # Three colours => evenly spaced x at 0, 0.5, 1.0 (n-1 denominator).
    s = cm(UInt8[255,0,0, 0,255,0, 0,0,255], 3)
    @test startswith(s, "0.0,1.0,0.0,0.0,")
    @test occursin("0.5,0.0,1.0,0.0", s)
    @test endswith(s, "1.0,0.0,0.0,1.0")

    # mvscalar packs a named per-element scalar field for scivis colouring.
    sc = GMTF3D.mvscalar("elev", Float32[1, 2, 3])
    @test sc.name == "elev" && sc.comps == 1 && sc.data == Float32[1, 2, 3]

    # add_mesh_view! is the single zero-copy entry point and exposes the c-api knobs
    # (scalars + in-memory texture) the path depends on.
    kws = Base.kwarg_decl(only(methods(GMTF3D.add_mesh_view!)))
    @test :point_scalars in kws
    @test :cell_scalars in kws
    @test :texture in kws
end
