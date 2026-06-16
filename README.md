# Sewer Architect

A top-down, RollerCoaster-Tycoon-style management sim where you design and
operate a city's sewer / wastewater system as the city grows around (and on
top of) you. macOS app built with SpriteKit + AppKit.

## Running

Open `Sewer Architect.xcodeproj` in Xcode and run the **Sewer Architect**
scheme (macOS). The project uses a file-system-synchronized group, so all
Swift files in the `Sewer Architect/` folder are compiled automatically.

## How to play

You start as the chief sewer engineer of a small town with a modest budget and
a handful of homes already wired to a primary treatment plant in the low corner
of the map. Press **Play** and keep the city's waste flowing.

### The map

- **Terrain is shaded by elevation** — blue-green is low (toward the river
  outfall in the corner), brown is high ground. Gravity carries flow downhill
  for free; to send flow *uphill* you need a **pump (lift) station**.
- Buildings: residential (R), commercial (C), industrial (I) parcels; treatment
  plants (P1/P2/P3 by tier); pumps (↑); storm drains (≈); retention basins.
- Pipes are color-coded by how full they are (gray → teal → yellow → orange →
  red) and tinted brown when worn. A red ✕ marks a blockage.

### Build tools (top row)

| Tool | What it does |
|------|--------------|
| Res / Com / Ind | Zone a new parcel (these also appear on their own as the city grows) |
| Pipe | Lay pipe in the currently selected material |
| Pump | Lift station — lets flow climb uphill |
| Plant | Treatment plant in the currently selected tier |
| Drain | Storm inlet — diverts rain runoff away from the sanitary network |
| Basin | Retention basin — buffers stormwater during storms |
| Upsize | Dig up the street to upgrade a pipe/plant tier, or add a backup pump |
| Repair | Dispatch a crew to restore condition / clear a blockage |
| Erase | Remove a tile |

Click a tool, then click (or click-drag, for pipe/erase/zoning) on the map.

### Controls (second row)

Play/Pause, speed (1x/2x/4x), Rate −/+ (the sewer fee), Loan (take a bond),
Pipe material cycle, Plant tier cycle, Combined/Separate sewers, preventive
Maintenance on/off, Sandbox/Scenario mode, and Report (quarterly report card).

Keyboard: **Space** play/pause, **R** report card, **]** speed, **+/−** rate.

### Goal

In **Sandbox** you just build and tinker. In **Scenario** you must grow the
town to the target population while keeping overflows and finances in check
before the deadline — bankrupt the department or wreck the river and it's "you've
been fired."

See [`SPEC.md`](SPEC.md) for the full design-spec coverage map.
