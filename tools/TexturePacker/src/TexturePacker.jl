module TexturePacker

using FileIO, ImageCore
using GeometryBasics
using Packing
using JSON3
using ArgParse

export pack_textures, trim_images

# configurable padding (pixels) to duplicate around trimmed sprites to avoid
# texture-atlas bleeding. Default chosen as 2 which is a reasonable tradeoff for
# dense atlases and typical use without mipmapping. For mipmapping you may
# increase this value (or compute based on mip levels).
const DEFAULT_PADDING = 2

"Load images from the source directory and return a Dict{Symbol, Any} of name => image"
function load_images(source_dir::AbstractString, filetype::AbstractString)
    image_files = filter(f -> endswith(lowercase(f), filetype), readdir(source_dir; join=true))
    return Dict(Symbol(basename(f)[1:end-length(filetype)]) => load(f) for f in image_files)
end

"Trim fully-transparent rows/columns from the edges of each image.
Returns (trimmed_images::Dict, metadata::Dict) where metadata[name] = (original_size, cropped_size, crop_offset)"
function trim_images(images::Dict{Symbol, <:AbstractMatrix})
    trimmed = Dict{Symbol, AbstractMatrix{RGBA{N0f8}}}()
    meta = Dict{Symbol, Any}()
    for (name, img) in images
        H, W = size(img)  # rows, cols

        # find first/last non-transparent row
        top = findfirst(i -> any(x -> alpha(x) > 0, @view img[i, :]), 1:H)
        bottom = findlast(i -> any(x -> alpha(x) > 0, @view img[i, :]), 1:H)

        # find first/last non-transparent column
        left = findfirst(j -> any(x -> alpha(x) > 0, @view img[:, j]), 1:W)
        right = findlast(j -> any(x -> alpha(x) > 0, @view img[:, j]), 1:W)

        if top === nothing || bottom === nothing || left === nothing || right === nothing
            # fully transparent: don't crop
            trimmed[name] = img
            meta[name] = (original_size = (W, H), cropped_size = (W, H), crop_offset = (0.0, 0.0))
        else
            # crop (rows, cols) -> (top:bottom, left:right)
            crop = img[top:bottom, left:right]
            cw = size(crop, 2)
            ch = size(crop, 1)
            trimmed[name] = copy(crop)
            # compute center shift using pixel-center convention: pixel centers at integer coords
            # original center = ( (W-1)/2, (H-1)/2 )
            # cropped center = ( (left-1) + (cw-1)/2, (top-1) + (ch-1)/2 )
            orig_cx = (W - 1) / 2
            orig_cy = (H - 1) / 2
            cropped_cx = (left - 1) + (cw - 1) / 2
            cropped_cy = (top - 1) + (ch - 1) / 2
            center_shift_x = cropped_cx - orig_cx
            center_shift_y = cropped_cy - orig_cy
            # store as floats (pixels) - renderer will flip Y as needed for its coordinate frame
            meta[name] = (original_size = (W, H), cropped_size = (cw, ch), crop_offset = (float(center_shift_x), float(center_shift_y)))
            # sanity: if cropping occurred but center shift is exactly zero, emit a diagnostic to help track edge cases
            if (cw != W || ch != H) && center_shift_x == 0.0 && center_shift_y == 0.0
                @warn "trim_images produced zero center_shift for cropped image" name=name top=top bottom=bottom left=left right=right W=W H=H cw=cw ch=ch
            end
        end
    end
    return trimmed, meta
end

"""
Return a new Dict of images where each image has `pad` pixels added on all
sides. The padding is filled by duplicating the edge pixels (replicate), which
prevents transparent/bleed artifacts when sampling adjacent atlas regions.
"""
function add_padding(images::Dict{Symbol, <:AbstractMatrix}, pad::Integer=DEFAULT_PADDING)
    if pad <= 0
        return images
    end
    padded = Dict{Symbol, typeof(first(values(images)))}()
    for (name, img) in images
        h, w = size(img)
        new_h = h + 2pad
        new_w = w + 2pad
        # create transparent image of new size
        out = fill(RGBA{N0f8}(0,0,0,0), new_h, new_w)
        # copy center
        out[pad+1:pad+h, pad+1:pad+w] .= img

        # left/right columns: replicate edge columns into padding
        left_col = @view out[pad+1:pad+h, pad+1]
        right_col = @view out[pad+1:pad+h, pad+w]
        for i in 1:pad
            out[pad+1:pad+h, i] .= left_col
            out[pad+1:pad+h, pad+w+i] .= right_col
        end

        # top/bottom rows: replicate edge rows into padding (including already filled cols)
        top_row = @view out[pad+1, 1:new_w]
        bottom_row = @view out[pad+h, 1:new_w]
        for j in 1:pad
            out[j, 1:new_w] .= top_row
            out[pad+h+j, 1:new_w] .= bottom_row
        end

        padded[name] = out
    end
    return padded
end


"""
Simple row-based packer.
Given `names` and `sizes` (Dict name => (w,h)), attempt to pack into a square atlas
starting at `initial_width` and growing by `width_step` until success. Returns
Dict{name => Rect2(x,y,w,h)} on success.
Sprites are sorted by height (descending) before packing to improve efficiency.
"""
function row_pack(names::Vector{Symbol}, sizes::Dict{Symbol, Tuple{Int,Int}}, initial_width::Int, width_step::Int=128)
    # Sort sprites by height (descending), then by width (descending) for consistent packing
    sorted_names = sort(names, by = n -> (-sizes[n][2], -sizes[n][1]))
    
    atlas_width = initial_width
    while true
        x = 0
        y = 0
        row_h = 0
        packed = Dict{Symbol, Rect2{Int}}()
        failed = false
        for n in sorted_names
            w, h = sizes[n]
            if w > atlas_width || h > atlas_width
                failed = true
                break
            end
            if x + w > atlas_width
                x = 0
                y += row_h
                row_h = 0
            end
            if y + h > atlas_width
                failed = true
                break
            end
            packed[n] = Rect2{Int}(x, y, w, h)
            x += w
            row_h = max(row_h, h)
        end
        if failed
            atlas_width += width_step
            continue
        else
            return packed, atlas_width
        end
    end
end


"""
Pack using Packing.jl's RectanglePacker. Returns Dict{name => Rect2(x,y,w,h)}.
Grows atlas if push! fails for any rect by increasing width by width_step.
"""
function rect_pack(names::Vector{Symbol}, sizes::Dict{Symbol, Tuple{Int,Int}}, initial_width::Int, width_step::Int=128)
    atlas_width = initial_width
    iteration = 0
    while true
        iteration += 1
        @info "rect_pack attempt" iteration=iteration atlas_width=atlas_width
        root = RectanglePacker(Rect2(0,0,atlas_width,atlas_width))
        packed = Dict{Symbol, Rect2{Int}}()
        failed = false
        # Build a mapping size -> FIFO queue of names so we can assign placed
        # rectangles back to image names by size. Any image with the same
        # packed size is interchangeable for placement.
        size_map = Dict{Tuple{Int,Int}, Vector{Symbol}}()
        for n in names
            w, h = sizes[n]
            if w > atlas_width || h > atlas_width
                failed = true
                break
            end
            k = (w, h)
            push!(get!(size_map, k, Vector{Symbol}()), n)
        end
        if failed
            atlas_width += width_step
            continue
        end

        # Build rects in original order; packer will sort internally.
        rects = [Rect2{Int}(0, 0, sizes[n][1], sizes[n][2]) for n in names]

        placed_nodes = nothing
        try
            placed_nodes = push!(root, rects)
        catch e
            # push! may throw if placements fail; increase atlas and retry
            atlas_width += width_step
            continue
        end
        # if any placement failed, grow atlas and retry
        if any(x -> x === nothing, placed_nodes)
            atlas_width += width_step
            continue
        end

        # Assign names by popping from size queues in FIFO order
        for node in placed_nodes
            area = node.area
            origin = Int.(area.origin)
            wds = Int.(area.widths)
            x = origin[1]
            y = origin[2]
            pw = wds[1]
            ph = wds[2]
            k = (pw, ph)
            q = get(size_map, k, nothing)
            if q === nothing || isempty(q)
                @warn "no available sprite for packed rect of size" k=k node=node
                failed = true
                break
            end
            name = popfirst!(q)
            packed[name] = Rect2{Int}(x, y, pw, ph)
        end
        if failed
            atlas_width += width_step
            continue
        end
        return packed, atlas_width
    end
end

"Main entry point: pack textures into a single atlas and write to outputs/
Required keyword args: source_dir, out_dir
Optional kwargs with reasonable defaults: filetype, pack_margin, atlas_width_step
"
function pack_textures(; source_dir::AbstractString, out_dir::AbstractString,
                         filetype::AbstractString = ".png",
                         pack_margin::Float64 = 1.1,
                         atlas_width_step::Int = 32,
                         padding::Int = DEFAULT_PADDING,
                         pack_method::Symbol = :row) # :rect uses Packing.RectanglePacker, :row uses simple row packer

    images_dict = load_images(source_dir, filetype)
    # Trim transparent borders to reduce atlas size
    images_dict, trim_meta = trim_images(images_dict)
    # add padding around trimmed images to avoid bleeding when sampling the atlas
    images_dict = add_padding(images_dict, padding)
    # rects are created as Rect2{Int}(x, y, width, height)
    rects = [Rect2{Int}(0, 0, size(img, 2), size(img, 1)) for img in values(images_dict)]

    # compute atlas size (square) using total area and packing margin
    total_area = sum(area.(rects))
    atlas_width = Int(cld(sqrt(total_area * pack_margin), atlas_width_step) * atlas_width_step)
    atlas_rect = Rect(0, 0, atlas_width, atlas_width)
    @info "Initial atlas calculation" total_area=total_area pack_margin=pack_margin initial_atlas_width=atlas_width

    # Choose packing method
    names = collect(keys(images_dict))
    sizes = Dict{Symbol, Tuple{Int,Int}}()
    for (n, img) in images_dict
        sizes[n] = (size(img, 2), size(img, 1))  # width, height
    end

    packed_images_dict = Dict{Symbol, Rect2{Int}}()
    if pack_method == :row
        packed_images_dict, atlas_width = row_pack(names, sizes, atlas_width, atlas_width_step)
    elseif pack_method == :rect
        packed_images_dict, atlas_width = rect_pack(names, sizes, atlas_width, atlas_width_step)
    else
        error("unknown pack_method: ", pack_method)
    end
    atlas_rect = Rect(0, 0, atlas_width, atlas_width)

    # Informational log: number of sprites packed, method used, and final atlas size
    atlas_w, atlas_h = widths(atlas_rect)
    @info "packed sprites" num_sprites=length(packed_images_dict) method=pack_method atlas_size=string(atlas_w, "x", atlas_h)

    # Compute UV transforms (uv_scale, uv_offset) for each packed sprite
    # Mapping: given sprite-local UV (u,v) in [0,1] (origin at top-left to match image)
    # atlas UV = uv_offset + uv_scale .* (u,v)
    uv_transforms = Dict{Symbol, Any}()
    atlas_w, atlas_h = widths(atlas_rect)
    for (name, rect) in packed_images_dict
        x, y = origin(rect)         # rect origin (pixels, zero-based) in atlas
        w, h = widths(rect)         # rect width, height (these include padding)

        # The UV transform should point to the unpadded (cropped) sprite region
        # inside the atlas. We know how much padding we added, so compute inner
        # rect origin/size by subtracting the padding.
        meta = trim_meta[name]
        cw, ch = meta.cropped_size  # cropped width, height (pixels)

        inner_x = x + padding
        inner_y = y + padding

        # convert to Float64 for normalized values (u,v in [0,1])
        uv_scale  = Vec2d(float(cw) / float(atlas_w), float(ch) / float(atlas_h))
        uv_offset = Vec2d(float(inner_x) / float(atlas_w), float(inner_y) / float(atlas_h))

        uv_transforms[name] = Dict(
            "uv_scale" => [uv_scale[1], uv_scale[2]],
            "uv_offset" => [uv_offset[1], uv_offset[2]],
            "original_size" => [meta.original_size...],
            "cropped_size" => [meta.cropped_size...],
            "crop_offset" => [meta.crop_offset...]
        )
    end
    # Save to JSON3
    open(out_dir * ".json", "w") do io
        JSON3.pretty(io, uv_transforms)  # pretty-printed JSON, human-friendly
    end

    # Create a blank RGBA atlas (Images.jl uses (rows, cols) = (height, width))
    atlas_w, atlas_h = widths(atlas_rect)
    atlas_img = fill(RGBA{N0f8}(0, 0, 0, 0), atlas_h, atlas_w)

    # Copy each image into its packed position
    for (name, rect) in packed_images_dict
        img = images_dict[name]
        x, y = origin(rect) # origin in pixels, zero-based
        h, w = size(img)    # (rows, cols) -- these include padding

        # Images.jl arrays are indexed as [row, col] = [y, x]
        atlas_img[y+1:y+h, x+1:x+w] .= img
    end

    save(out_dir * filetype, atlas_img)
end

function parse_commandline()
    s = ArgParseSettings(
        description = "Pack textures into a single atlas and generate UV mapping data.",
        prog = "TexturePacker.jl"
    )

    @add_arg_table! s begin
        "source_dir"
            help = "Directory containing source images"
            required = true
        "output_base"
            help = "Base name for output files (without extension)"
            required = true
        "--pack-method", "-m"
            help = "Packing method: rect (RectanglePacker) or row (simple row packing)"
            arg_type = String
            default = "row"
        "--filetype", "-t"
            help = "Image file extension to process"
            arg_type = String
            default = ".png"
        "--pack-margin"
            help = "Packing margin multiplier for atlas size estimation"
            arg_type = Float64
            default = 1.1
        "--atlas-width-step"
            help = "Atlas width increment step when growing"
            arg_type = Int
            default = 32
        "--padding", "-p"
            help = "Padding pixels around each sprite"
            arg_type = Int
            default = DEFAULT_PADDING
    end

    args = parse_args(s)
    
    # validate pack method
    if !(args["pack-method"] in ["rect", "row"])
        error("Invalid pack method: $(args["pack-method"]). Must be 'rect' or 'row'.")
    end
    
    return args
end

function main()
    try
        args = parse_commandline()
        
        pack_method = Symbol(args["pack-method"])
        
        pack_textures(
            source_dir = args["source_dir"],
            out_dir = args["output_base"],
            filetype = args["filetype"],
            pack_margin = args["pack-margin"],
            atlas_width_step = args["atlas-width-step"],
            padding = args["padding"],
            pack_method = pack_method
        )
        
        println("✓ Successfully packed textures to $(args["output_base"]).png and $(args["output_base"]).json")
    catch e
        println("Error: $e")
        exit(1)
    end
end

# Run main if this file is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module TexturePacker