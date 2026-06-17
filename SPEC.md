# Spec coverage map

How the design spec ("Sewer system tycoon") maps onto the implementation. ✅ =
implemented, 🟡 = modeled in a simplified form, ⬜ = not yet.

## Core gameplay loop

| Spec | Status | Where |
|------|--------|-------|
| Survey & plan (city map, zones, terrain/elevation) | ✅ | `World.generateTerrain`, terrain shading in `GameScene` |
| Build (pipes, pumps, plants, stormwater) | ✅ | `World.place`, `BuildTool` |
| Simulate flow (elevation, diameter/capacity, demand, real-time + speed) | ✅ | `Simulation.routeFlow`, speed control |
| React to events (blockages, bursts, storms, breakdowns, complaints) | ✅ | `Simulation.rollRandomEvents`, `Weather` |
| Grow & balance (city expands, demand rises, budget) | ✅ | `Simulation.growCity`, `Economy` |
| Score/review (periodic report cards) | ✅ | `Scoring.ReportCard`, report overlay |

## What the player builds/manages

| Spec | Status | Notes |
|------|--------|-------|
| Pipe materials (clay→PVC→concrete→trenchless) w/ capacity/durability/cost | ✅ | `PipeMaterial` |
| Gravity vs. pumped systems; terrain matters | ✅ | BFS gravity rule + pump tiles in `Simulation.findRoute` |
| Pumping/lift stations: capacity, redundancy (backup), maintenance, failure | ✅ | `PumpStation`, `Upsize` adds backup |
| Treatment plant tiers (primary/secondary/tertiary), capacity, smell, effluent | ✅ | `PlantTier` |
| Stormwater: separate vs. combined, CSO events | ✅ | `buildCombinedSewers`, `computeStormwater`, CSO in `handleOverflow` |
| Budget: construction/maintenance costs, loans/bonds, rate-setting | ✅ | `Finance` |
| Workforce: maintenance crews, preventive vs. reactive | 🟡 | `runMaintenanceCrews` (auto crews) + manual `Repair` tool |

## Sources of challenge

| Spec | Status | Notes |
|------|--------|-------|
| City growth dumps load on you, often after the fact | ✅ | `growCity` posts "found out after" events |
| Aging infrastructure, corrosion, root intrusion, deferred maintenance | ✅ | per-tick condition decay, blockages, bursts |
| Weather: storms spike flow → overflows; droughts → blockages/odor | ✅ | `Weather` |
| Terrain constraints (rivers, hills) | 🟡 | elevation + outfall; rivers/bedrock not yet distinct obstacles |
| Regulatory pressure tightening over time (fines for overflows) | ✅ | `applyOverflowFine` scales with quarter |
| Budget constraints, costly rate hikes, loan interest | ✅ | `Finance`, satisfaction reacts to rate |
| Random breakdowns/blockages ("flushed something") | ✅ | `EventFlavor`, `rollRandomEvents` |

## Win / loss / scoring

| Spec | Status | Notes |
|------|--------|-------|
| Sandbox (no win/loss) | ✅ | `GameMode.sandbox` |
| Scenario mode with goals | ✅ | `Scenario` (default: grow to target pop, cap overflows, stay solvent) |
| Career mode (chain of cities, escalating tech/difficulty) | ✅ | `Career.swift` (Mudville → Sprawlburg → Old Town); level transitions in `GameScene` |
| Scoring: coverage, overflow incidents, environment, finances, satisfaction | ✅ | `ReportCard` |
| Loss: bankruptcy / environmental disaster / sanitation crisis | ✅ | `Scenario.evaluate` |

## Game modes

Sandbox ✅, Scenario ✅, Career ✅ (3 chained cities w/ tech unlocks), Disaster
mode 🟡 (tunables exist: `growthRate`, `disastersEnabled`,
`Weather.stormFrequency`).

## Fun mechanical hooks

| Spec | Status |
|------|--------|
| Visible flow simulation (color-coded fullness) | ✅ |
| Overflow events (CSO pollution, incidents) | ✅ animated manhole geysers + river discoloration (`spawnGeyser`, `updateRiver`) |
| Pipe capacity upgrades ("dig up the street" w/ surcharge) | ✅ |
| Treatment plant tech tiers w/ cost/benefit | ✅ |
| "Flush logs" / comedic complaint ticker | ✅ `EventFlavor` |
| Smell radius affecting nearby happiness | ✅ |
| Combined sewer overflow (CSO) tension | ✅ |
| Inspection/maintenance minigame (crew-hours vs. backlog) | 🟡 crew action budget per tick |
| Report card / news ticker w/ headline humor | ✅ |

## Known simplifications / next steps

- Stormwater is modeled per-parcel and folded into the sanitary route rather
  than as a fully separate second network.
- Career progress is per-session (no save/load yet); the 3-city chain resets
  when the app relaunches.
- Distinct terrain obstacles (bedrock, rivers crossing the map) are not yet
  modeled beyond elevation + the outfall corner.
