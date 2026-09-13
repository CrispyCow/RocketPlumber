struct RenderAssets
    shader_dir::String
    texture_atlas_dir::String
end

struct OffscreenTarget
    framebuffer::GLuint
    renderbuffer::GLuint
    width::Int
    height::Int
    readback::Vector{UInt8}
end

mutable struct ExportRenderer
    window
    glmap
    renderqueue
    scratch_renderqueue
    target::OffscreenTarget
    options::ExportOptions
end

function _required_asset_paths(repository_root::AbstractString)
    shader_dir = joinpath(repository_root, "local_packages", "HexFlowRendering", "src", "shaders")
    texture_dir = joinpath(repository_root, "tools", "TexturePacker", "outputs")
    required = [
        joinpath(shader_dir, "BaseTile.vert"),
        joinpath(shader_dir, "BaseTile.frag"),
        joinpath(shader_dir, "BaseTile_LiquidEffect.frag"),
        joinpath(shader_dir, "BaseTile_GasEffect.frag"),
        joinpath(texture_dir, "TileTextureAtlas1.png"),
        joinpath(texture_dir, "TileTextureAtlas1.json"),
    ]
    return shader_dir, texture_dir, required
end

function validate_render_assets!(repository_root::AbstractString)
    shader_dir, texture_dir, required = _required_asset_paths(repository_root)
    missing = filter(path -> !isfile(path), required)
    isempty(missing) || throw(RenderToolError("required renderer asset is missing: $(join(missing, ", "))"))
    return RenderAssets(shader_dir, texture_dir)
end

function _glfw_error_message(error)
    return "Cannot create a hidden OpenGL context. A working display server and OpenGL driver are required ($(sprint(showerror, error)))."
end

function _create_hidden_window()
    glfw = Main.GLFW
    window = nothing
    try
        glfw.DefaultWindowHints()
        glfw.WindowHint(glfw.VISIBLE, Cint(0))
        glfw.WindowHint(glfw.SAMPLES, Cint(0))
        glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, Cint(4))
        glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, Cint(1))
        glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
        @static if Sys.isapple()
            glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, Cint(1))
        end
        window = glfw.CreateWindow(16, 16, "Rocket Plumber Time-Lapse Export")
        window == C_NULL && throw(ErrorException("GLFW returned a null window"))
        glfw.MakeContextCurrent(window)
        return window
    catch error
        if !isnothing(window) && window != C_NULL
            try
                glfw.DestroyWindow(window)
            catch
            end
        end
        error isa InterruptException && rethrow()
        throw(RenderToolError(_glfw_error_message(error)))
    end
end

function _create_offscreen_target(width::Integer, height::Integer)::OffscreenTarget
    maximum = GLint(0)
    @cref glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, &maximum)
    (width <= maximum && height <= maximum) || throw(RenderToolError("requested resolution $(width)x$(height) exceeds GL_MAX_RENDERBUFFER_SIZE $(maximum)"))
    framebuffer = GLuint(0)
    renderbuffer = GLuint(0)
    try
        @cref glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        @cref glGenRenderbuffers(1, &renderbuffer)
        glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer)
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, GLsizei(width), GLsizei(height))
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer)
        glDrawBuffer(GL_COLOR_ATTACHMENT0)
        glReadBuffer(GL_COLOR_ATTACHMENT0)
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
        status == GL_FRAMEBUFFER_COMPLETE || throw(RenderToolError("offscreen framebuffer is incomplete (status $(status))"))
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        glBindRenderbuffer(GL_RENDERBUFFER, 0)
        return OffscreenTarget(framebuffer, renderbuffer, width, height, Vector{UInt8}(undef, width * height * 4))
    catch
        renderbuffer != 0 && @cref glDeleteRenderbuffers(1, &renderbuffer)
        framebuffer != 0 && @cref glDeleteFramebuffers(1, &framebuffer)
        rethrow()
    end
end

function _delete_offscreen_target!(target::OffscreenTarget)
    framebuffer = target.framebuffer
    renderbuffer = target.renderbuffer
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    renderbuffer != 0 && @cref glDeleteRenderbuffers(1, &renderbuffer)
    framebuffer != 0 && @cref glDeleteFramebuffers(1, &framebuffer)
    return nothing
end

function create_renderer(options::ExportOptions, assets::RenderAssets)
    window = nothing
    glmap = nothing
    target = nothing
    try
        window = _create_hidden_window()
        target = _create_offscreen_target(options.width, options.height)
        rendering = Main.HexFlowRendering
        rendering.SHADER_DIR[] = assets.shader_dir
        rendering.TEXTURE_ATLAS_DIR[] = assets.texture_atlas_dir
        glmap = Main.RenderEngine.GLObjectMap()
        rendering.viewtransform_glubo_init(glmap)
        rendering.basesprite_glprog_init(glmap)
        rendering.texatlas1_gltex_init(glmap)
        rendering.liquidsprite_glprog_init(glmap)
        rendering.gassprite_glprog_init(glmap)
        renderqueue = Vector{rendering.SpriteRenderCommand}()
        sizehint!(renderqueue, 512)
        scratch = Vector{rendering.SpriteRenderCommand}(undef, 512)
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        return ExportRenderer(window, glmap, renderqueue, scratch, target, options)
    catch error
        if !isnothing(glmap)
            try
                Main.RenderEngine.teardown_glmap(glmap)
            catch
            end
        end
        !isnothing(target) && _delete_offscreen_target!(target)
        if !isnothing(window)
            try
                Main.GLFW.DestroyWindow(window)
            catch
            end
        end
        try
            Main.GLFW.Terminate()
        catch
        end
        (error isa ToolError || error isa InterruptException) && rethrow()
        throw(RenderToolError("OpenGL renderer initialisation failed: $(sprint(showerror, error))"))
    end
end

function _set_camera!(renderer::ExportRenderer, camera::CameraViewport)
    control = Main.HexFlowControl
    viewstate = control.ViewState(
        fb_width = Int32(renderer.target.width), fb_height = Int32(renderer.target.height),
        window_width = Int32(renderer.target.width), window_height = Int32(renderer.target.height),
        view_x = camera.view_x, view_y = camera.view_y, view_zoom = camera.zoom,
    )
    Main.HexFlowRendering.set_view_ubo(renderer.glmap, control.get_viewtransform(viewstate))
    return nothing
end

function _render_docking_beams!(queue, glmap, gamemap, gameticks::Int64)
    rendering = Main.HexFlowRendering
    primary_centroid = get_surface_centroid(gamemap, :primary)
    isnothing(primary_centroid) && return nothing
    primary_pos = primary_centroid + get_ship_render_offset(gamemap, :primary)
    for (ship_name, ship) in gamemap.ships
        ship_name == :primary && continue
        ship_centroid = get_surface_centroid(gamemap, ship_name)
        isnothing(ship_centroid) && continue
        ship_pos = ship_centroid + get_render_offset(ship)
        status = get_docking_status(ship)
        beam_colour = if status isa ApproachingDockStat
            SVector{4, Float32}(0.2f0, 0.2f0, 0.6f0, 1.0f0)
        elseif status isa ConnectedDockStat
            SVector{4, Float32}(0.2f0, 0.6f0, 0.2f0, 1.0f0)
        elseif status isa DepartingDockStat
            SVector{4, Float32}(0.6f0, 0.2f0, 0.2f0, 1.0f0)
        else
            nothing
        end
        isnothing(beam_colour) && continue
        connected = status isa ConnectedDockStat
        rendering.render_beam!(queue, glmap, gameticks, primary_pos, ship_pos;
            num_elements = 50, noise_magnitude = connected ? 0.025 : 0.1,
            scale = connected ? 0.5f0 : 1.0f0, colour = beam_colour,
            draw_height = Int32(rendering.RENDER_HEIGHT_TRACTOR_BEAM))
    end
    return nothing
end

function _render_keyframe!(renderer::ExportRenderer, context::ReconstructionContext, entry::TimelineEntry, camera::CameraViewport, tick::Int64)
    rendering = Main.HexFlowRendering
    control = Main.HexFlowControl
    _set_camera!(renderer, camera)
    target = renderer.target
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
    glViewport(0, 0, GLsizei(target.width), GLsizei(target.height))
    background = renderer.options.background
    glClearColor(Float32(background[1]) / 255.0f0, Float32(background[2]) / 255.0f0, Float32(background[3]) / 255.0f0, 1.0f0)
    glClear(GL_COLOR_BUFFER_BIT)
    empty!(renderer.renderqueue)
    rendering.ship_surface_queued_render!(renderer.renderqueue, renderer.glmap, entry.gamemap)
    _render_docking_beams!(renderer.renderqueue, renderer.glmap, entry.gamemap, tick)
    gamestate = control.GameState(ticks = tick)
    rendering.tile_queued_render!(renderer.renderqueue, renderer.glmap, entry.gamemap, context.derived, context.mna_snapshot, gamestate)
    rendering.pipe_queued_render!(renderer.renderqueue, renderer.glmap, entry.gamemap, context.derived, gamestate)
    rendering.node_queued_render!(renderer.renderqueue, renderer.glmap, entry.gamemap, context.derived, context.mna_snapshot)
    length(renderer.scratch_renderqueue) < length(renderer.renderqueue) && resize!(renderer.scratch_renderqueue, length(renderer.renderqueue))
    Main.RenderEngine.glrender(renderer.glmap, renderer.renderqueue, renderer.scratch_renderqueue)
    readback = target.readback
    GC.@preserve readback begin
        glReadPixels(GLint(0), GLint(0), GLsizei(target.width), GLsizei(target.height), GL_RGBA, GL_UNSIGNED_BYTE, pointer(readback))
    end
    return target.readback
end

function render_frame!(renderer::ExportRenderer, context::ReconstructionContext, timeline::TimelinePlan, cameras, frame::KeyframeSchedule, local_frame::Int)
    entry = timeline.frames[frame.keyframe_index]
    local_frame == 0 && reconstruct_keyframe!(context, entry; retained_index = frame.keyframe_index, verbose = renderer.options.verbose)
    tick = animation_tick(entry.gamemap, local_frame, renderer.options.fps)
    return _render_keyframe!(renderer, context, entry, cameras[frame.keyframe_index], tick)
end

function each_rendered_frame(callback::Function, renderer::ExportRenderer, timeline::TimelinePlan, cameras, schedule::FrameSchedule; label = "render")
    context = create_reconstruction_context()
    emitted = 0
    for frame in schedule.keyframes
        for local_frame in 0:(frame.frame_count - 1)
            bytes = render_frame!(renderer, context, timeline, cameras, frame, local_frame)
            callback(bytes, emitted, frame, local_frame)
            emitted += 1
            if renderer.options.verbose || emitted == schedule.total_frames || emitted == 1
                println("$(label): $(emitted)/$(schedule.total_frames) frames")
            end
        end
    end
    return emitted
end

function destroy_renderer!(renderer::ExportRenderer)
    try
        Main.RenderEngine.teardown_glmap(renderer.glmap)
    finally
        try
            _delete_offscreen_target!(renderer.target)
        finally
            try
                Main.GLFW.DestroyWindow(renderer.window)
            finally
                Main.GLFW.Terminate()
            end
        end
    end
    return nothing
end
