#!/usr/bin/env julia

let
    texture_packer_dir = joinpath(@__DIR__, "TexturePacker")
    source_dir = joinpath(texture_packer_dir, "textures")
    output_base = joinpath(texture_packer_dir, "outputs", "TileTextureAtlas1")
    entry_point = joinpath(texture_packer_dir, "src", "TexturePacker.jl")

    run(`$(Base.julia_cmd()) --startup-file=no --project=$(texture_packer_dir) $(entry_point) $(source_dir) $(output_base) --pack-method row`)
end
