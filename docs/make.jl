using GMTF3D
using Documenter

DocMeta.setdocmeta!(GMTF3D, :DocTestSetup, :(using GMTF3D); recursive=true)

makedocs(;
    modules=[GMTF3D],
    authors="Joaquim <jluis@ualg.pt> and contributors",
    sitename="GMTF3D.jl",
    format=Documenter.HTML(;
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "3-D viewing of GMT data" => "viewer3d.md",
        "Gallery" => "gallery.md",
        "Raytracing (OSPRay)" => "raytracing.md",
    ],
)
