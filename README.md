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
| TAB | aim both / cannon 1 / cannon 2 |
| H, Z, X (computer keyboard) | back to center, set center, safety |

Bind W A S D, SPACE, LEFT SHIFT and TAB to a frequency on the typewriter; it only sends bound keys.

Turn speed is capped by MAX_YAW_SPEED / MAX_PITCH_SPEED (deg/s), or the controllers' own top speed (RPM / 24 degrees a tick) if that is slower.

Settings are at the top of the file (speeds, invert, pitch limits, manual CANNONS pairing). Auto-updates from this repo.
