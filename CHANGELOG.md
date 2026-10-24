# Changelog

Notable player-facing changes to Rocket Plumber are recorded here, in loose adherence with [Keep a Changelog](https://keepachangelog.com/en/) guidance.

## Unreleased

- Redesigned Properties into a compact, permanently visible inspector for components,
  pipes and junctions. Hover for temporary operating readouts, or select a part for
  persistent inspection and expandable, read-only Technical details (Debug).

- Clearer gauges, fluid-coloured contents and condition warnings make ship systems
  easier to understand. Readouts use player-friendly physical units, show current
  and commanded settings together, and distinguish missing measurements from zero.

## 0.1.0

First release tracked by this changelog, and it is considered the origin state for change tracking. At this stage the game includes:
- The basic fluid simulation
- Rendering with OpenGL and CImGui
- Cold-gas, mono-propellant, and bi-propellant fuel types
- Gas, pressure fed, and turbopump driven engines
- Explorer mode with randomised encounters on the space map
- The 'Escape the Galaxy' victory condition
