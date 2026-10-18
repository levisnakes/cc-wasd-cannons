# WASD Cannons

Aim and fire Create Big Cannons by hand from a Create Avionics Linked Typewriter (CC:Tweaked).

One computer, wired to the typewriter and, for each cannon, a Create Radar Auto Yaw Controller, Auto Pitch Controller and Fire Controller.

```
wget https://raw.githubusercontent.com/levisnakes/cc-wasd-cannons/main/wasd_cannons.lua startup.lua
```

| Key | Does |
|---|---|
| W / S | pitch up / down |
| A / D | yaw left / right |
| SPACE (hold) | fire |
| LEFT SHIFT | slow aim |
| TAB | aim all / cannon 1 / cannon 2 / ... |
| Q | cannons in TOGGLE_CANNONS (default #3) join SPACE or sit out |
| H, Z, X (computer keyboard) | back to center, set center, safety |
| R / E (computer keyboard) | start/stop tracing the ship edge / erasing it |

Put a wired modem on each Cannon Mount as well: moving or firing while the cannons are disassembled assembles them, and the direction they face on assembly becomes the center.

Bind W A S D, SPACE, LEFT SHIFT, TAB and Q to a frequency on the typewriter; it only sends bound keys.

Turn speed is capped by MAX_YAW_SPEED / MAX_PITCH_SPEED (deg/s), or the controllers' own top speed (RPM / 24 degrees a tick) if that is slower.

## Cannons without controllers

A cannon mount with a wired modem can be aimed and fired by the computer directly, no yaw/pitch/fire controllers. Mounts left over after the controller cannons are used this way (or list them in DIRECT_MOUNTS). If it picks the wrong mount, press M on the computer to step through them. Its row shows the yaw/pitch shaft RPM, or "no yaw spin" / "no pitch spin" when a shaft has no rotation. The mount turns with the rotation going into its own yaw and pitch shafts, so give those power.

## Ship protection

Press R, sweep the barrel along the top edge of your ship (A/D round, W/S so it just clears), press R again. That cannon won't fire below the traced edge (plus SAFE_MARGIN degrees). The angles are the mount's own, so it stays right as the ship turns. TAB on one cannon teaches just that one; on ALL it teaches every cannon. E works the same way but erases.

Settings are at the top of the file (speeds, invert, pitch limits, manual CANNONS pairing). Auto-updates from this repo.
