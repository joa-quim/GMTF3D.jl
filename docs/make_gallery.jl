# Regenerate the docs "Gallery" page (docs/src/gallery.md) and its images.
#
# Renders every example in examples/gallery.jl OFF-SCREEN to a PNG under
# docs/src/assets/gallery/, then writes gallery.md (descriptions + demo call + image),
# grouped exactly like `GALLERY_DEMOS`.
#
# Run it whenever the gallery examples change:
#     julia --project=docs docs/make_gallery.jl
#
# The generated PNGs + gallery.md are committed, so a normal `docs/make.jl` build (and
# CI) needs neither GMT nor the f3d binary — it just renders the committed page. The
# f3d_ext-only examples (drape_*, cloud_sprites) render with full features only when a
# rebuilt f3d_ext DLL is present; on a stock DLL they still produce a (plainer) image.

using GMTF3D, GMT

const DOCSDIR  = @__DIR__
const ASSETS   = joinpath(DOCSDIR, "src", "assets", "gallery")
const PAGE     = joinpath(DOCSDIR, "src", "gallery.md")

include(joinpath(DOCSDIR, "..", "examples", "gallery.jl"))   # GALLERY, GALLERY_DEMOS, export_gallery

mkpath(ASSETS)
@info "Rendering gallery examples off-screen → $ASSETS"
rendered = export_gallery(ASSETS; size=(900, 700))           # [(name, abspath), …]
have = Dict(name => true for (name, _) in rendered)
@info "Rendered $(length(rendered)) / $(length(GALLERY)) examples"

open(PAGE, "w") do io
    println(io, "# Gallery")
    println(io)
    println(io, "Every example below is produced by `examples/gallery.jl`, rendered")
    println(io, "off-screen with `export_gallery`. Each builds its data offline with a")
    println(io, "`demo_*` helper; swap in `gmtread(...)` for real data. Open any example")
    println(io, "interactively by calling its function (e.g. `grid_surface()`), or export")
    println(io, "it with `; offscreen=true, saveimg=\"out.png\"`.")
    println(io)
    println(io, "```julia")
    println(io, "using GMTF3D, GMT")
    println(io, "```")
    println(io)
    for (group, items) in GALLERY_DEMOS
        # Only emit a group if at least one of its examples actually rendered.
        shown = [it for it in items if get(have, it[1], false)]
        isempty(shown) && continue
        println(io, "## ", group)
        println(io)
        for (name, what, demo, _real) in shown
            println(io, "### `", name, "`")
            println(io)
            println(io, what, ".")
            println(io)
            println(io, "```julia")
            println(io, demo)
            println(io, "```")
            println(io)
            println(io, "![", name, "](assets/gallery/gallery_", name, ".png)")
            println(io)
        end
    end
end
@info "Wrote $PAGE"
