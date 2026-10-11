# TypeGroupedDicts

`TypeGroupedDict{K,V}` stores a logical key/value mapping in buckets grouped by
the exact concrete type of each stored value. Ordinary keyed operations and
read-only iteration are dictionary-like; explicit bulk operations specialise on
the concrete buckets.

```julia
using TypeGroupedDicts

entries = TypeGroupedDict{Symbol,Real}([:count => 3, :weight => 2.5])
entries[:count] = 4
total = mapreducevalues(identity, +, entries; init = 0.0) # 6.5
weighted = mapreducepairs(+, entries; init = 0.0) do key, value
    return key === :count ? 2value : value
end
```

The declared key and value types are explicit. The optional entries constructor
accepts dictionaries and iterators of key/value entries and inserts through
normal assignment, including conversion and replacement of duplicate keys.
Assignment replaces an equivalent stored key with the incoming converted key,
as `Dict` does. Bulk value mapping preserves the stored keys.

## Traversal and reduction

| Operation | Callback | Result |
| --- | --- | --- |
| `foreachvalue(f, collection)` | `f(value)` | `nothing` |
| `foreachpair(f, collection)` | `f(key, value)` | `nothing` |
| `mapreducevalues(f, op, collection; init)` | `f(value)` | Accumulated result |
| `mapreducepairs(f, op, collection; init)` | `f(key, value)` | Accumulated result |
| `mapvalues!(f, collection)` | `f(value)` | Collection with replaced values |
| `mapvalueswithkeys!(f, collection)` | `f(key, value)` | Collection with replaced values |

Reductions require `init` and start with that accumulator exactly once across
the entire collection. Each entry contributes through
`op(accumulator, f(value))`, or `op(accumulator, f(key, value))`. An empty
collection returns `init` unchanged without calling either callback, including
when empty buckets remain after deletion. Accumulators may change type and are
not converted to the initial type or to `V`. Both callbacks specialise inside
each concrete bucket; the outer heterogeneous traversal need not infer a single
result type.

All traversal orders are unspecified. Reductions make no additional ordering
guarantee, so order-sensitive operations (including floating-point addition)
may produce different results for different storage histories. Callbacks must
not mutate the collection re-entrantly. Read-only nested traversal is allowed.
Errors propagate; reductions do not roll back callback side effects.

Value mapping visits each initial entry exactly once. Same-type replacements
are immediate; migrations to different concrete buckets are deferred. If a
callback or conversion throws, prior same-type writes remain and deferred
migrations have not been applied. The mapping functions replace values without
rewriting keys.

## Dictionary interoperability

The collection deliberately **does not subtype `AbstractDict`**. Methods whose
signatures require `AbstractDict` do not automatically accept it. Use
`Dict(collection)` to materialise an ordinary dictionary, and
`TypeGroupedDict{K,V}(entries)` to rebuild grouped storage.

Ordinary iteration yields `Pair{K,V}`, even when `V` is abstract. `keys`,
`values`, and `pairs` share the same order while the collection is unchanged.
Ordinary iteration is read-only and has no concrete-type specialisation
guarantee. Collect keys before structural removal.

Equality and hashing compare logical contents rather than bucket layout.
Hashing delegates to a materialised `Dict` for compatibility using public
interfaces; it is an allocating, cold operation.

## Testing

From the package directory:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

The package has no runtime dependencies. Its test workspace uses Julia's `Test`
and `Random` standard libraries. A manifest is generated locally as needed and
is deliberately not tracked for this reusable library.
