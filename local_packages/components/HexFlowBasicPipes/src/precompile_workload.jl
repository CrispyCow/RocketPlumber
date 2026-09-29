#=
Scope: Representative headless precompilation for concrete pipe behaviours
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload
using StaticArrays: SVector

@setup_workload begin
    scrap = PlacedPipe(ScrapPipeBehav(), :PrecompileShip)
    big = PlacedPipe(BigPipeBehav(), :PrecompileShip)
    coord = PipeCoord(VertexCoord(TileCoord(0, 0), HexFrame.Q_POS), VertexCoord(TileCoord(0, 0), HexFrame.Q_NEG))
    rotation = HexFrame.Q_POS

    glmap = GLObjectMap()
    glmap.textures[:PrecompileAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(1024), UInt(1024))
    for sprite in (
            :ScrapPipes_Side, :ScrapPipes_ShortDiagonal, :ScrapPipes_LongDiagonal,
            :BigPipes_Side, :BigPipes_Side_fluidmask,
            :BigPipes_ShortDiagonal, :BigPipes_ShortDiagonal_fluidmask,
            :BigPipes_LongDiagonal, :BigPipes_LongDiagonal_fluidmask,
        )
        glmap.sprites[sprite] = GLspriteData(
            :PrecompileAtlas,
            SVector{2, Float32}(0.1f0, 0.1f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
            SVector{2, Float32}(256.0f0, 256.0f0),
            SVector{2, Float32}(256.0f0, 256.0f0),
            SVector{2, Float32}(0.0f0, 0.0f0),
        )
    end
    queue = HexFlowRendering.SpriteRenderCommand[]

    gas = DerivedMapState()
    gas.nodeactualfluids[to_nodecoord(coord.v1)] = HexFluids.COLD_GAS
    liquid = DerivedMapState()
    liquid.nodeactualfluids[to_nodecoord(coord.v1)] = HexFluids.MONOPROP_LIQUID

    @compile_workload begin
        for pipe in (scrap, big)
            get_conductance(pipe)
            get_pipe_tunables(pipe)
            set_pipe_tunables(pipe, (5.0,))
            get_pipe_click_radius(pipe)
            can_pipe_be_moved(pipe)
            produce_abs_elements(pipe, coord)
            render_pipe_base!(queue, pipe; glmap = glmap, rotation = rotation, position = coord, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        end
        render_pipe_map!(queue, scrap; glmap = glmap, rotation = rotation, position = coord, derivedmapstate = gas, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        render_pipe_map!(queue, big; glmap = glmap, rotation = rotation, position = coord, derivedmapstate = gas, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        render_pipe_map!(queue, big; glmap = glmap, rotation = rotation, position = coord, derivedmapstate = liquid, gameticks = 1, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
    end
end
