# Time-Lapse Export Tool

***NOTE: This tool was fully AI-generated and has not been manually reviewed or tested thoroughly, but its base functionality seems to work***

This repository-local command exports schema-version-2 Rocket Plumber
time-lapse saves as ship-world-only H.264 MP4 or palette-optimised animated
GIF. It does not start the game loop, calculator thread, CImGui, or any game UI.

Run it from any directory by selecting the repository environment explicitly:

```bash
julia --project=/path/to/RocketPlumberPrivate \
  /path/to/RocketPlumberPrivate/tools/timelapse_export/export.jl \
  /path/to/save.jld2 --output /path/to/timelapse.mp4
```

The tool needs a working display server and OpenGL driver for its hidden GLFW
context. It is UI-free, but the first implementation is not EGL/OSMesa
headless. `--inspect` performs parsing, save loading, timeline assembly,
camera planning, and timing planning without creating an OpenGL context,
starting FFmpeg, or creating an output file.

## Cameras and timeline

`expand` is the default camera. It fits the first retained keyframe and grows
outwards when later stored surface-tile positions require more space. `fixed`
uses one padded union of all retained surface tiles. `manual` requires
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
exit codes, run:

```bash
julia --project=. tools/timelapse_export/export.jl --help
```

Exit codes are 0 for success/help/inspection, 2 for usage errors, 3 for save
and timeline validation errors, 4 for assets/OpenGL/reconstruction/rendering
errors, 5 for output/FFmpeg/encoded-output errors, and 130 for interruption.

## Tests

The tool's pure parser, timeline, camera, and timing tests do not initialise
GLFW:

```bash
julia --project=. tools/timelapse_export/test/runtests.jl
```

Display-enabled export checks should use a locally recorded save. Generated
videos, GIFs, temporary palettes, and test saves should not be committed.
