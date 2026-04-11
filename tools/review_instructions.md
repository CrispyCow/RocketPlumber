# Code Review Instructions for AI Agents

I am doing a formatting and code cleanup pass through my codebase, one file at a time, in preparation for a release. I would like you to help me review and clean up the code.

## Editorial Guidelines

### Spelling and Documentation
- **Typos and spelling mistakes**: Note that I use Australian English spellings
- **Em Dash**: Avoid the em dash, it makes things look too AI generated
- **Comments that should be docstrings**: Convert function/type documentation to proper docstrings
  - **Single-line docstrings**: Use single quotes `"x"` to keep file length reasonable
  - **Multi-line docstrings**: Use triple quotes `"""x"""`
- **Verbose doxygen-esque comments**: I find these too verbose; prefer a simple description of what the function does
- **Overly verbose docstrings**: Docstrings should convey the function's purpose, not repeat its name/signature or describe step-by-step workings. Only include detailed notes when there is genuine complexity or a non-obvious quirk worth flagging
- **Duplicate returns added by Runic**: Runic often adds `return` wrapping a block of code that doesn't produce a meaningful return. In this case, add a `return nothing` line to the end of the function instead
- **Base function extensions**: When extending Base functions (e.g., `Base.convert`, `Base.promote_rule`, `Base.:+`), include docstrings explaining what each does—the implementation alone can be confusing

### Comment Style

The goal is to balance readability with conciseness. Comments should convey intent and explain complex logic, not narrate every operation. The appropriate level of commenting depends on code complexity:

**Simple functions** (like coordinate conversions, getters/setters):
- Rely primarily on docstrings
- Minimal to no inline comments
- Code should be self-documenting through good naming

**Intermediate complexity** (like rendering helpers, data structure manipulation):
- Use inline comments to explain the purpose of code sections
- Comment unintuitive operations or edge cases
- Combine multiple related operations under a single explanatory comment
- Move short comments inline with the code they describe to save vertical space

**Complex algorithms** (like graph traversal, matrix operations, physics solvers):
- Keep substantial algorithm-explaining comments
- Use comments to describe what a section accomplishes, with a focus on why
- Explain the mathematical or algorithmic concepts being implemented
- Reference external resources (papers, documentation) where applicable
- Retain comments that help readers understand non-obvious invariants or state

**Comment placement guidelines**:
- **Single line of code**: Place comment inline (same line) with the code
  ```julia
  G[v1_index, v1_index] += conductance # v1 always appears on diagonal
  ```
- **Few lines of code** (2-5 lines): Place comment on its own line just above the code block
  ```julia
  # Check if any adjacent tile is on the ship surface
  for (tile, _) in adjacent_tiles
      if is_on_surface_tile(tile, gamemap)
          return (true, "")
      end
  end
  ```
  And don't remove this style of comment if it's already present in the code
- **Larger code sections**: Use block comments or multiple single-line comments to explain the section
  ```julia
  #=
  The G matrix is an N×N matrix formed in two steps.
  Each element in the diagonal matrix is equal to the sum of conductances...
  =#
  ```

**Comment consolidation strategies**:
- Replace multiple single-line comments with one comment describing a code block
- Move comments explaining a single line from above to inline with that line
- Keep descriptive comments that explain guard clauses, edge cases, or "why" decisions
- Remove comments that merely restate what the code obviously does

**Struct field comments**:
- Brief inline comments on struct fields are valuable for documentation
- Keep these unless they're completely redundant

**Examples to guide the balance**:
- For simple code: focus on clear naming, use comments sparingly
- For moderately complex code: comment to convey intent of sections and unintuitive parts
- For algorithm-heavy code: retain substantial explanatory comments that aid understanding

### Section Dividers
Major section dividers should use this style:
```julia
# ===============================================================
# Game Main Loop
# ===============================================================
```

Minor section dividers should use this style:
```julia
#= ---------- Pipe Behaviors ----------- =#
```

Some sections that are currently minor dividers should probably be major, and vice versa.

### Line Length and Argument Layout

Do not excessively break function signatures across multiple lines. I have a wide screen and prefer keeping things compact. Follow these rules:

- **Short signatures** (positional args + a few kwargs that fit comfortably on one line): keep everything on a single line
  ```julia
  function render_pipe(glmap::GLObjectMap, pipe::EdgeCoord, colour::ColourType; transparency::AbstractFloat = 1.0f0, gameticks::Integer = 0)
  ```
- **Medium signatures**: if a line break is needed, prefer breaking at the `;` between positional and keyword arguments. Positional args go on the first line; kwargs start on the next, each on its own indented line
  ```julia
  function render_basic_sprite(
          glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position;
          pos_offset = nothing,
          draw_height::Int32 = RENDER_HEIGHT_OVERLAY_BASE,
          kwargs...
      )::RenderCommand
  ```
- **Long signatures** (many kwargs): break positional args onto the first continuation line, then one kwarg per line
  ```julia
  function setup_basesprite_uniforms(
          glmap::GLObjectMap, sprite::Symbol, rotation_matrix::SMatrix{2, 2, GLfloat}, position::SVector{2, Float32};
          colour::SVector{4, Float32} = SVector{4, Float32}(1.0, 1.0, 1.0, 1.0),
          scale::AbstractFloat = 1.0,
          transparency::AbstractFloat = 1.0,
          x_unclipped::AbstractFloat = 1.0,
          sprite_offset_tweak_px::SVector{2, <:AbstractFloat} = SVector{2, Float32}(0.0, 0.0),
          sprite_rotation_tweak_mat::SMatrix{2, 2, GLfloat} = SMatrix{2, 2, GLfloat}(1, 0, 0, 1)
      )
  ```
- **General principle**: don't split a line that reads comfortably at ~120–140 columns. Only break when a single line would genuinely be hard to scan
- The same rules apply to function calls, constructor invocations, and similar long expressions
- We do make an exception for rendering functions in component definition files, as their args are always the same and its best to just hide them on one line so we don’t have to look at all of it.

## Code Quality Checks

**General Priority**: Readability and simplicity over performance outside of critical hot loops. In hot loops, limiting allocations is more important than CPU cycles—prefer `filter!`, `copyto!`, and similar built-ins over bespoke implementations when they're simpler.

### Correctness and Edge Cases
- All this code works, but there could be ghosts in the machine I haven't run into yet
- If you can identify any obvious issues or edge cases, present them along with a fix

### Code Structure
- **Duplicate code**: Look for code that could be easily extracted into a helper function; present a suggested pattern.
- **Excessive abstraction**: Do not add excessive helper functions that do not address code duplication, they just add complexity and indirection
- **Deeply nested flow control**: If unnecessary, propose approaches to simplify it (early returns, guard clauses, etc.)
- **Missing functions**: Sometimes I might have implemented interface/type functions for some things but not others. Search the codebase and if you see utility in a simple additional function, suggest it

### Naming
- **Bad variable naming**, especially inside functions
- **Bad function naming**, taking into account their use within the codebase

### Julia Idioms and Best Practices
- **Idiomatic Julia code**: Use dispatch, iterators, and appropriate standard library functions
- **Functional patterns**: Prefer `map`, `filter`, `filter!`, `copyto!` and similar stdlib functions over manual loops where it improves clarity
- **Type stability and allocations**: These are optimizations. Only suggest easy wins that don't change interfaces. Otherwise note them for a future optimization pass
  - **NOTE**: Much of the code allocates more than necessary. This will be addressed in a separate benchmarking-driven optimization pass. Code outside hot loops is called infrequently enough that allocations don't matter

### Code Organization
- **Function grouping**: Ensure similar/related functions are grouped together under appropriate minor or major section headings
- **Broader codebase context**: Search the wider codebase for patterns and context as needed (note: not all code may have been reviewed yet)

## Review Process

### Step 0: Formatting Pass
Before making any manual edits, run the Runic formatter on the file being reviewed:
```shell
julia --project=@runic --startup-file=no -e "using Runic; exit(Runic.main(ARGS))" -- -i <filepath>
```
This formats the file in place. Review and commit the formatting changes separately from editorial/code changes.

### Step 1: Low-Friction Editorial Changes
Implement any low-friction editorial changes directly in the file (typos, comment cleanup, section divider formatting, etc.)

### Step 2: Review Controversial Changes
Present any more controversial editorial changes or recommended code changes to me for review **without executing them**. This includes:
- Structural refactoring
- Function extraction
- Naming changes that affect multiple call sites
- Potential bug fixes or edge case handling

### Step 3: Execute Approved Changes
Execute those changes after my feedback and direction.

### Step 4: Package Tests
If the file being reviewed belongs to a package that has tests, run them:
```shell
julia --project=. -e "using Pkg; Pkg.test(string(:PackageName))"
```
Note: use the `string(:Symbol)` notation, as other quoting styles tend to break with shell escaping.

Packages with tests: `FlowMap`, `FlowEngine`, `HexFlowCalculator`, `HexFlowProcGen`, `HexFlowRendering`, `HexFrame`, `SquirrelNoise`.

### Step 5: Integration Testing
Test the changes by running the development script and iteratively solve any errors that result:
- Execute: `julia --project=. --threads=2,1 --gcthreads=1,1 src/repl_launch.jl`
- Note: The game can take a very long time to fully load
- I will have to interact with it to test the new features
- **Do not consider testing done until you see the script exits on its own without errors**
- **Do not execute this in the background** — you can wait until the program has closed and evaluate the outputs all at once
