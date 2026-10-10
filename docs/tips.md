# Profiles, commands and SSH

## Profiles

- **Silent**: GPU capped, quiet fan
- **Balanced**: the default
- **Turbo**: big cores pinned high, fan kicks in early

Switch with the Performance button (Pocket FIT), the KONKR Control plugin, the bottom screen dashboard (Thor, Pocket DS), or `konkrctl profile turbo` etc.

## Handy commands

```
konkrctl status               # profile, fan, clocks, temps
konkrctl rgb ff3c00           # stick colour (Pocket FIT)
konkrctl speaker flat         # speakers without the loudness boost (Pocket FIT / S2)
konkr-game fast %command%     # FEX preset for launch options, also fastest / compat
```

## SSH

SSH is off by default. To turn it on, set a password (`passwd` in Konsole), then run `sudo systemctl enable --now sshd`. From your PC: `ssh steamos@<device-ip>`. Root login is off, use sudo. `sudo systemctl disable --now sshd` turns it off again.

## Steam client beta and PyroWave (SM8550)

Both are opt-in, by creating a file in `~/.local/share/Steam` and restarting Steam:

- `touch ~/.local/share/Steam/.allow-client-updates` lets the client update and follow the beta channel you pick in Steam's settings. Without it, client updates stay blocked.
- `touch ~/.local/share/Steam/.pyrowave-box64` enables the PyroWave codec for Remote Play. The arm64 streaming client has no PyroWave decoder, so the x86 one from the client beta runs under box64 instead. Steam's settings still show PyroWave greyed out, but the stream uses it when the host offers it (the client log says "Pyrowave Vulkan decoding"). Delete the file and restart Steam to go back to the arm64 client.
