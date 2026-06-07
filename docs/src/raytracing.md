# Raytracing (OSPRay)

F3D.jl downloads the **raytracing** build of f3d. Its accelerator DLLs
(`ospray_module_cpu`, `ispcrt_device_cpu`, the OpenVKL CPU device modules, …) sit
next to `f3d_c_api.dll` in `src/lib/.../bin/`, but on Windows the Julia process does
not search that directory, so f3d/ospray's bare-name `LoadLibrary` calls fail
(`#ospray: INVALID device --> Load of ospray_module_cpu failed … The specified module
could not be found.`) and toggling raytracing crashes Julia.

`F3D.preload_raytracing()` fixes that: it opens each accelerator DLL once by absolute
path with `LoadLibraryExW` + `LOAD_WITH_ALTERED_SEARCH_PATH`, so each module (and its
sibling dependencies) loads and registers under its base name. Later bare-name loads
then resolve to the resident module. No `PATH` / `__init__` / loader-search mutation.
Idempotent; no-op on non-Windows (Linux/macOS resolve via RPATH).

## Offscreen raytracing (works, fast)

Measured at 1200×900: plain GL ≈ 0.001 s, raytraced ≈ 0.06 s (1 spp) … 0.29 s (5 spp).

```julia
using F3D
F3D.preload_raytracing()                      # Windows: make ospray modules loadable

engine = F3D.f3d_engine_create(Cint(1))       # 1 = offscreen
window = F3D.f3d_engine_get_window(engine)
opts   = F3D.f3d_engine_get_options(engine)
# … set window size, add your mesh to the scene …

F3D.f3d_options_set_as_bool(opts, "render.raytracing.enable",  Cint(1))
F3D.f3d_options_set_as_int( opts, "render.raytracing.samples", Cint(5))   # samples/pixel
img = F3D.f3d_window_render_to_image(window, Cint(0))
F3D.f3d_image_save(img, "out.png", F3D.PNG)
```

## Reactivating the live `R` / `Shift+R` hotkeys

The interactive **GMTF3D** viewers call `_disable_raytracing_bindings(interactor)`
right after `F3D.f3d_interactor_init_bindings(interactor)`. The helper is defined in
`src/common.jl` and called from each viewer implementation (4 sites):

- `_view_fv_impl` — `src/fv.jl` (the engine behind `view_grid` / `view_fv`)
- `_view_image_impl` — `src/image.jl`
- `_view_points_impl` — `src/points.jl`
- `_view_lines_impl` — `src/lines.jl`

That removes the raytracing key binds. To restore the live keys, in each of those
sites replace

```julia
    _disable_raytracing_bindings(interactor)
```

with

```julia
    F3D.preload_raytracing()   # make ospray modules resident so 'R' does not crash
```

**Warning — known issue (unresolved).** With the live keys active, pressing `R` pins
all CPU cores at 100 %, GPU activity drops to zero, and the window freezes hard and
never returns control to the event loop; killing the window then crashes the REPL. The
offscreen path above, using the identical `render.raytracing.*` options, renders in
60–294 ms and exits cleanly — so it is specific to the interactive interactor, not the
raytracer itself. Root cause not isolated. Build: Windows nightly
`F3D-3.5.0-103-gec0d94c6` raytracing.
