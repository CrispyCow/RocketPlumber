# Time-Lapse Export Tool

***NOTE: This tool was fully AI-generated and has not been manually reviewed or tested thoroughly, but its base functionality seems to work***

This repository-local command exports Rocket Plumber
time-lapse saves as ship-world-only H.264 MP4 or palette-optimised animated
GIF. It does not start the game loop, calculator thread, CImGui, or any game UI.

## Normal workflow

Open `tools/export_timelapse.jl` in VS Code, edit the input and output paths in
the configuration block, adjust its options if needed, then use **Run File**.
Configuration paths are relative to the repository root. With command-line
arguments, the launcher forwards them to the exporter instead:

```bash
julia tools/export_timelapse.jl
julia tools/export_timelapse.jl maps/save.jld2 --output recordings/save.mp4 --camera fixed
```

The launcher starts a fresh Julia process with the repository root project,
regardless of the environment active in VS Code or the REPL. The underlying
entry point remains available for direct use:

```bash
julia --project=. tools/TimelapseExport/export.jl --help
julia --project=. tools/TimelapseExport/export.jl maps/save.jld2 --inspect
julia --project=. tools/TimelapseExport/export.jl maps/save.jld2 \
  --output recordings/save.mp4 --camera smooth
```

The tool uses the root project because it depends on the game packages,
rendering infrastructure, persisted component registrations, OpenGL, and
FFmpeg. It does not have a separate Julia environment.

The tool needs a working display server and OpenGL driver for its hidden GLFW
context. It is UI-free, but the first implementation is not EGL/OSMesa
headless. `--inspect` performs parsing, save loading, timeline assembly,
camera planning, and timing planning without creating an OpenGL context,
starting FFmpeg, or creating an output file.

## Cameras and timeline

`expand` is the default camera. It fits the first retained keyframe and grows
outwards when later stored surface-tile positions require more space.
`fit` independently centres and zooms each retained keyframe to fit all ships
present, so it can zoom back in when ships disappear or the layout shrinks.
`smooth` plans one continuous camera path from the complete retained history.
It uses a wide 25-snapshot low-pass window, anticipates approaching growth, and
applies an even slower scale recovery after contraction. A shape-preserving
cubic trajectory carries camera velocity across keyframe boundaries and is
sampled by the existing output frames, without adding frames or interpolating
game state.
Changing `--keyframe-seconds` therefore changes playback speed rather than the
underlying camera path. Automatic modes apply `--padding` and `--min-padding`
and preserve the output aspect ratio.

Smooth transition cameras contain the padded geometry on both sides of each
snapshot boundary. Every sampled camera is also checked against the current
snapshot's padded bounds, preventing smoothing lag from clipping new geometry.
The start hold keeps the camera stationary. In smooth mode, up to the first
second (and at most half) of the end hold settles from the filtered construction
camera to a tight padded fit of the final ship; the remaining end hold is
stationary. Other camera modes keep their entire end hold stationary.

`fixed` uses one padded union of all retained surface tiles. `manual` requires
`--viewport XMIN,YMIN,XMAX,YMAX` and aspect-expands that minimum rectangle.

Automatic camera bounds use stored base tile coordinates only. Runtime docking
render offsets affect the artwork and docking beams but never expand the camera.
Expand viewport edges therefore never move inwards. Keyframes receive equal
holds; `--start-hold` and `--end-hold` add endpoint time. Simulated ticks are
used only as deterministic animation phase, not as playback duration.

By default, adjacent render-equivalent candidates are removed. Use
`--no-dedupe` to retain them. `--include-current` accepts `auto` (default),
`always`, or `never`; active galaxy-escape current maps are omitted by `auto`
and rejected by `always`.

## Output and options

MP4 defaults to 1920x1080 at 30 fps, CRF 20, and the `medium` H.264 preset.
GIF defaults to 960x540 at 15 fps and renders deterministic palette and encode
passes. MP4 dimensions must be even. Output is encoded in a temporary
directory inside the destination directory and moved into place only after a
successful FFmpeg exit. `--force` leaves an existing destination untouched if
the new export fails.

For the complete option list, defaults, validation rules, examples, and stable
exit codes, run the exporter's `--help` command shown above. Exit codes are 0
for success/help/inspection, 2 for usage errors, 3 for save and timeline
validation errors, 4 for assets/OpenGL/reconstruction/rendering errors, 5 for
output/FFmpeg/encoded-output errors, and 130 for interruption.

## Tests

The pure parser, timeline, camera, and timing tests do not initialise GLFW. Run
them from the repository root with:

```bash
julia --project=. tools/TimelapseExport/test/runtests.jl
```

Display-enabled export checks should use a locally recorded save. Generated
videos, GIFs, temporary palettes, and test saves should not be committed.
