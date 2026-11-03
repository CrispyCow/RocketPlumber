# Changelog

Notable player-facing changes to Rocket Plumber are recorded here, in loose adherence with [Keep a Changelog](https://keepachangelog.com/en/) guidance.

## Unreleased

## 0.1.1

- Reduced exhaust and background dust clumping at high simulation speeds and made
  particle trajectories more consistent across frame rates.

- Added background autosaving and a main-menu Resume button to continue your last game.

- Added a scalable UI with crisp Tamzen bitmap typography across menus, instruments
  and panels. Choose six scales from 100% to 267% in Settings or with Numpad
  Plus/Minus; the default is 133%.

- Added shared main-menu and in-game Settings for Fullscreen (also F11), VSync,
  UI Scale and Background Dust. Preferences persist between application launches,
  and the game remembers the last-used monitor and tries to restore it on launch.

- Redesigned Properties as a permanent inspector for components, pipes and
  junctions. Hover for temporary operating readouts or select a part for persistent
  inspection and read-only Technical details (Debug), with clearer measurements,
  units and gauges that distinguish missing measurements from zero. Clicking a part
  preserves its Properties display and scroll position until a move becomes active.

- Improved several in-game UI layouts to use space more efficiently and scale
  better, including the velocity tracker, manoeuvre controls, Space Map and
  Galaxy Escape screen.

- Added automatic crash reports to help diagnose and fix issues.

## 0.1.0

First release tracked by this changelog, and it is considered the origin state for change tracking. At this stage the game includes:
- The basic fluid simulation
- Rendering with OpenGL and CImGui
- Cold-gas, mono-propellant, and bi-propellant fuel types
- Gas, pressure fed, and turbopump driven engines
- Explorer mode with randomised encounters on the space map
- The 'Escape the Galaxy' victory condition
