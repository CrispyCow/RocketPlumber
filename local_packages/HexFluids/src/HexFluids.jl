module HexFluids

# Type Exports
export NodeFluidTags, FluidTags
# Function Exports
export prioritise_fluidtag, is_gas, is_liquid, is_behavior

# ===============================================================
# Fluid Types
# ===============================================================

# Bitmasks for fluid tag classification (UInt8):
# Bit 7 (0x80): is_gas - indicates a concrete gas fluid type
# Bit 6 (0x40): is_liquid - indicates a concrete liquid fluid type
# Bit 5 (0x20): is_behavior - indicates a generic behavior tag (ANY_GAS, ANY_LIQUID)
# Lower bits (0-4): unique identifier for each fluid type
const isgas_mask = 1 << 7
const isliquid_mask = 1 << 6
const isbehavior_mask = 1 << 5

@enum FluidTags::UInt8 begin
    # generic behavior
    NONE = 0x00
    ANY_GAS = 0x01 | isbehavior_mask
    ANY_LIQUID = 0x02 | isbehavior_mask
    # concrete fluids
    COLD_GAS = 0x03 | isgas_mask
    MONOPROP_LIQUID = 0x04 | isliquid_mask
    MONOPROP_GAS = 0x05 | isgas_mask
end

"Check if fluid tag is a concrete gas type (determined with bitmask)"
is_gas(tag::FluidTags)::Bool = (UInt8(tag) & isgas_mask) != 0

"Check if fluid tag is a concrete liquid type (determined with bitmask)"
is_liquid(tag::FluidTags)::Bool = (UInt8(tag) & isliquid_mask) != 0

"Check if fluid tag is a behavior type (determined with bitmask)"
is_behavior(tag::FluidTags)::Bool = (UInt8(tag) & isbehavior_mask) != 0

"Maps hex node positions to their fluid tags for a component"
@kwdef struct NodeFluidTags
    NODE_Q_POS::FluidTags = NONE
    NODE_R_NEG::FluidTags = NONE
    NODE_S_POS::FluidTags = NONE
    NODE_Q_NEG::FluidTags = NONE
    NODE_R_POS::FluidTags = NONE
    NODE_S_NEG::FluidTags = NONE
    NODE_INTERNAL::FluidTags = NONE
end

# ===============================================================
# Fluid Priority Logic
# ===============================================================

"""
Return the "highest-priority" fluid tag according to these rules:

1. Identical tags are returned as is.  
2. `NONE` can be overwritten by any other tag.  
3. A behavior tag (`ANY_GAS` or `ANY_LIQUID`) matches only concrete tags of its kind, returning the concrete tag.  
4. Conflicting behavior tags or two distinct concrete tags raise an error—fluids can't be mixed.

Behavior Matrix:

| tag_a                | tag_b                         | outcome                               |
|----------------------|-------------------------------|---------------------------------------|
| tag_a == tag_b       | —                             | returns tag_a                         |
| `NONE`               | any other tag                 | returns the other tag                 |
| any other tag        | `NONE`                        | returns the other tag                 |
| `ANY_GAS`            | concrete gas tag              | returns the concrete gas tag          |
| `ANY_LIQUID`         | concrete liquid tag           | returns the concrete liquid tag       |
| concrete gas tag     | `ANY_GAS`                     | returns the concrete gas tag          |
| concrete liquid tag  | `ANY_LIQUID`                  | returns the concrete liquid tag       |
| `ANY_GAS`            | `ANY_LIQUID`                  | error                                 |
| `ANY_LIQUID`         | `ANY_GAS`                     | error                                 |
| any two distinct concrete tags                       | error                                 |
"""
function prioritise_fluidtag(tag_a::FluidTags, tag_b::FluidTags)::FluidTags
    # Helper for ANY_GAS / ANY_LIQUID behavior
    function handle_behavior(behavior_tag::FluidTags, other_tag::FluidTags)
        if behavior_tag === ANY_GAS && is_gas(other_tag)
            return other_tag
        elseif behavior_tag === ANY_LIQUID && is_liquid(other_tag)
            return other_tag
        else
            error("Behavior $(behavior_tag) incompatible with concrete tag $(other_tag)")
        end
    end

    # Identical or NONE shortcuts
    tag_a === tag_b && return tag_a
    tag_a === NONE && return tag_b
    tag_b === NONE && return tag_a

    # Dispatch on behavior tags
    if is_behavior(tag_a)
        return handle_behavior(tag_a, tag_b)
    elseif is_behavior(tag_b)
        return handle_behavior(tag_b, tag_a)
    end

    # Both concrete but distinct → conflict
    error("Conflicting concrete tags: $(tag_a) vs $(tag_b)")
end

"Single-argument fallback returns the tag unchanged"
prioritise_fluidtag(tag::FluidTags)::FluidTags = tag

"Variadic version combines multiple tags by recursively pairing them"
function prioritise_fluidtag(a::FluidTags, b::FluidTags, rest::FluidTags...)::FluidTags
    first_result = prioritise_fluidtag(a, b)
    return isempty(rest) ? first_result : prioritise_fluidtag(first_result, rest...)
end

end # module HexFluids
