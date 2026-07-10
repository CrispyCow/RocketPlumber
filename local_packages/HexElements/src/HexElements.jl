module HexElements

using HexFrame, StructEquality

# Type Exports
export ElementTypes, ElementID, Element
export RelativeElement, RelativeElementConnections
export AbsoluteElementConnections, AbsoluteElement
# Function Exports
export map_element, is_dependant
export get_typestring, get_unitstring, get_value

# ===============================================================
# Circuit Element Types
# ===============================================================

@enum ElementTypes::UInt8 begin
    CONST_RESISTOR
    CONST_VOLTAGE
    CONST_CURRENT
    C_DEP_CURRENT
    V_DEP_VOLTAGE
end

"Is the element a dependent source?"
function is_dependant(type::ElementTypes)::Bool
    dep_list = (
        C_DEP_CURRENT,
        V_DEP_VOLTAGE,
    )
    return type in dep_list
end

# ===============================================================
# Element Connections
# ===============================================================

abstract type ElementConnections end

"""
Connections for an element relative to tile placement.
`v1` and `v2` indicate connection relative to tile via NodePos.
"""
struct RelativeElementConnections <: ElementConnections
    v1::NodePos
    v2::NodePos

    function RelativeElementConnections(v1::NodePos, v2::NodePos)
        # TODO: Maybe the functions that use this should tolerate either order?
        if v1 === HexFrame.GROUND
            error("only v2 can be grounded")
        end
        return new(v1, v2)
    end
end
@struct_hash_equal RelativeElementConnections

"""
Connections for an element in absolute map coordinates.
`v1` and `v2` indicate absolute connections to nodes via NodeCoord.
"""
struct AbsoluteElementConnections <: ElementConnections
    v1::NodeCoord
    v2::NodeCoord
end
@struct_hash_equal AbsoluteElementConnections

# ===============================================================
# Circuit Elements
# ===============================================================

"Unique identifier for an element, based on the source tile or edge."
struct ElementID
    map_source_hash::UInt64
    index::UInt8
end
@struct_hash_equal ElementID

"ElementID constructor for tile elements."
function ElementID(source::TileCoord, index::Integer)
    return ElementID(hash(source), index)
end

"ElementID constructor for pipe elements (enforces index = 1)."
function ElementID(pipe::PipeCoord)
    return ElementID(hash(pipe), UInt8(1))
end

abstract type Element end

"Circuit element using relative hex axis to define connected nodes."
@kwdef struct RelativeElement <: Element
    connections::RelativeElementConnections
    value::Float64 # conductance for resistors, voltage for voltage sources, current for current sources, gain for dep sources
    type::ElementTypes
    dependent_index::UInt8 = 0 # index to the element which this element is dependant on. 0 if non-dependant, should be ignored
    active::Bool = true # whether this relative element is currently active (not stalled)
end
@struct_hash_equal RelativeElement

"""
Semi-positional constructor for RelativeElement.
Accepts (connections, value, type; dependent_index=0, active=true) and validates dependent types.
"""
function RelativeElement(connections::RelativeElementConnections, value::Real, type::ElementTypes; dependent_index::Integer = 0, active::Bool = true)::RelativeElement
    if is_dependant(type) && dependent_index == 0
        throw(ArgumentError("Cannot create RelativeElement with dependent type without a dependent_index"))
    end
    return RelativeElement(connections = connections, value = Float64(value), type = type, dependent_index = UInt8(dependent_index), active = active)
end

"Circuit element using absolute coordinates to define connected nodes."
@kwdef struct AbsoluteElement <: Element
    connections::AbsoluteElementConnections
    value::Float64 # conductance for resistors, voltage for voltage sources, current for current sources, gain for dep sources
    type::ElementTypes
    id::ElementID # unique identifier
    dependent_id::ElementID = ElementID(id.map_source_hash, 0) # id of the element which this element is dependant on. invalid (0 index) if non-dependant
    active::Bool = true # is this absolute element currently active (not stalled)
end
@struct_hash_equal AbsoluteElement

"""
Semi-positional constructor for AbsoluteElement.
Accepts (connections, value, type, id; dependent_id=ElementID(id.map_source_hash, 0), active=true) and validates dependent types.
"""
function AbsoluteElement(connections::AbsoluteElementConnections, value::Real, type::ElementTypes, id::ElementID; dependent_id::ElementID = ElementID(id.map_source_hash, 0), active::Bool = true)::AbsoluteElement
    if is_dependant(type) && dependent_id.index == 0
        throw(ArgumentError("Cannot create AbsoluteElement with dependent type without a dependent_id"))
    end
    return AbsoluteElement(connections = connections, value = Float64(value), type = type, id = id, dependent_id = dependent_id, active = active)
end

# ===============================================================
# Element Mapping Functions
# ===============================================================

"Map a relative node position to an absolute NodeCoord."
function map_element(relative_pos::NodePos, tile::TileCoord, rotation::HexAxis, mirrored::Bool = false)::NodeCoord
    if !is_axis(relative_pos)
        return NodeCoord(tile, relative_pos)
    end

    relative_axis = to_hexaxis(relative_pos)
    absolute_axis = transform_tile_axis(relative_axis, rotation, mirrored)
    absolute_vertex = VertexCoord(tile, absolute_axis)
    return to_nodecoord(absolute_vertex)
end

"Map relative element connections to absolute connections."
function map_element(relative_element_connections::RelativeElementConnections, tile::TileCoord, rotation::HexAxis, mirrored::Bool = false)::AbsoluteElementConnections
    v1 = map_element(relative_element_connections.v1, tile, rotation, mirrored)
    v2 = map_element(relative_element_connections.v2, tile, rotation, mirrored)
    return AbsoluteElementConnections(v1, v2)
end

"Map a relative element to an absolute element."
function map_element(relative_element::RelativeElement, tile::TileCoord, index::Integer, rotation::HexAxis, mirrored::Bool = false)::AbsoluteElement
    absolute_connections = map_element(relative_element.connections, tile, rotation, mirrored)
    return AbsoluteElement(
        connections = absolute_connections,
        value = relative_element.value,
        type = relative_element.type,
        id = ElementID(tile, UInt8(index)),
        dependent_id = ElementID(tile, relative_element.dependent_index), # dependent index is 0 (invalid) if non-dependant
        active = relative_element.active
    )
end

# ===============================================================
# Element Property Accessors
# ===============================================================

"Get a string description of the ElementType."
function get_typestring(type::ElementTypes)
    element_typestring_lookup = (
        CONST_RESISTOR = "Constant Resistor",
        CONST_VOLTAGE = "Independent Voltage Source",
        CONST_CURRENT = "Independent Current Source",
        C_DEP_CURRENT = "Current Dependent Current Source",
        V_DEP_VOLTAGE = "Voltage Dependent Voltage Source",
    )
    return get(element_typestring_lookup, Symbol(type), "Unknown Element Type")
end

"Get a string description of the element's type."
function get_typestring(elem::T) where {T <: Element}
    return get_typestring(elem.type)
end

"Get a string description of the units for element type."
function get_unitstring(type::ElementTypes)
    element_unitstring_lookup = (
        CONST_RESISTOR = "Conductance (1/R)",
        CONST_VOLTAGE = "Voltage (V)",
        CONST_CURRENT = "Current (A)",
        C_DEP_CURRENT = "Gain (A/A)",
        V_DEP_VOLTAGE = "Gain (V/V)",
    )
    return get(element_unitstring_lookup, Symbol(type), "UNDEF")
end

"Get a string description of the units for element's value."
function get_unitstring(elem::T) where {T <: Element}
    return get_unitstring(elem.type)
end

"Get the element's value."
function get_value(elem::T) where {T <: Element}
    return elem.value
end

end # module HexElements
