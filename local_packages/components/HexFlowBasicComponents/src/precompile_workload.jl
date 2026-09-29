#=
Scope: Representative headless precompilation for the basic component behaviour
Formatter: Runic
=#

using PrecompileTools: @setup_workload, @compile_workload
using StaticArrays: SVector

@setup_workload begin
    # The persistence fixture is the repository's concrete BasicCompBehav use
    basic = BasicCompBehav(elems = BasicElemBehavFrag(), sprite = PlainSpriteBehavFrag(:PrecompileBasic))
    placed = PlacedComponent(basic, HexFrame.Q_POS, :PrecompileShip)
    tile = TileCoord(2, -1)

    glmap = GLObjectMap()
    glmap.textures[:PrecompileAtlas] = RenderEngine.GLtexData(RenderEngine.GLtexID(0), UInt32(0), UInt(256), UInt(256))
    glmap.sprites[:PrecompileBasic] = GLspriteData(
        :PrecompileAtlas,
        SVector{2, Float32}(0.1f0, 0.1f0),
        SVector{2, Float32}(0.0f0, 0.0f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(256.0f0, 256.0f0),
        SVector{2, Float32}(0.0f0, 0.0f0),
    )
    queue = HexFlowRendering.SpriteRenderCommand[]

    @compile_workload begin
        produce_rel_elements(basic)
        produce_rel_elements(placed)
        produce_abs_elements(placed, tile)
        get_tunables(placed)
        set_tunables(placed, ())
        get_component_mass(placed)
        map_rotation(placed, HexFrame.S_POS)
        can_be_moved(placed)
        render_base_elem!(queue, placed; glmap = glmap, position = tile, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
        render_map_elem!(queue, placed; glmap = glmap, position = tile, pos_offset = AxialCoord(0.0, 0.0), render_height_offset = Int32(0))
    end
end
