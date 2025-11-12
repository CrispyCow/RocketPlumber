# TexturePacker Command Line Usage

TexturePacker can now be executed directly from the command line using Julia, eliminating the need for a separate runner script.

## Usage

```
julia --project=. src/TexturePacker.jl <source_dir> <output_base> [OPTIONS]
```

### Required Arguments

- `source_dir`: Directory containing source images to pack
- `output_base`: Base name for output files (without extension). Both `.png` and `.json` files will be created.

### Optional Arguments

- `--pack-method`, `-m`: Packing method (`rect` or `row`, default: `rect`)
  - `rect`: Uses Packing.jl's RectanglePacker for optimal packing
  - `row`: Uses simple row-based packing
- `--filetype`, `-t`: Image file extension to process (default: `.png`)
- `--pack-margin`: Packing margin multiplier for atlas size estimation (default: `1.5`)
- `--atlas-width-step`: Atlas width increment step when growing (default: `128`)
- `--padding`, `-p`: Padding pixels around each sprite (default: `2`)

### Help

```
julia --project=. src/TexturePacker.jl --help
```

## Examples

### Windows Commands

#### Basic usage (equivalent to old run_pack.jl):
```powershell
cd TexturePacker
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1
```

#### With custom pack method:
```powershell
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1 --pack-method row
```

#### With custom padding:
```powershell
julia --project=. src/TexturePacker.jl textures outputs/MyAtlas --padding 4 --pack-method rect
```

### Linux Commands

#### Basic usage:
```bash
cd TexturePacker
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1
```

#### With custom pack method:
```bash
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1 --pack-method row
```

#### With custom padding:
```bash
julia --project=. src/TexturePacker.jl textures outputs/MyAtlas --padding 4 --pack-method rect
```

## Output Files

The tool generates two files:
- `<output_base>.png`: The packed texture atlas
- `<output_base>.json`: UV mapping data and sprite metadata

## Migration from run_pack.jl

The old `run_pack.jl` script is no longer needed. Replace:

```julia
julia --project=. app/run_pack.jl
```

With:

```julia
julia --project=. src/TexturePacker.jl textures outputs/TileTextureAtlas1 --pack-method rect
```

## Programmatic Usage

The module can still be imported and used programmatically:

```julia
using TexturePacker

pack_textures(
    source_dir="textures",
    out_dir="outputs/TileTextureAtlas1",
    pack_method=:rect
)
```