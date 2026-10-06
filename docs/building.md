# Building

I build everything in an arm64 Linux VM (Colima on a Mac).

- Kernels: `external-and-mods/kernel-sm8650/build.sh` and `external-and-mods/kernel-sm8550/build.sh` (shared script in `kernel-common/`, chip specific bits in each `soc.env`)
- gamescope: `scripts/build-gamescope-in-rootfs.sh`, source in `external-and-mods/gamescope/`
- the image: `make-steamos-sm8650.sh` (`SOC=sm8550` for the 8 Gen 2 one), or `./make-steamos-sm8750.sh` for the Snapdragon 8 Elite (Odin 3); `./make-steamos-sm8350.sh` turns the rootfs from `make-steamos-sm8650.sh` (or a release image) into the REDMAGIC 6 fastboot kit (kernel: `external-and-mods/kernel-sm8350/build.sh`, see [redmagic6.md](redmagic6.md))

Valve's files and the Steam client aren't in this repo, the build downloads them. How the pieces fit together is in [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

## Update package

SteamOS Update installs a `.tar.gz` update package, so it can be attached to a release next to the `.7z` image. Build it from the release image on any Linux box (needs root to loop-mount the image):

```
sudo python3 external-and-mods/konkr-update/image-to-package.py steamos-arm-handhelds-sm8550-<tag>.7z.001 \
  --soc sm8550 --version <tag> --output steamos-arm-handhelds-sm8550-<tag>-update.tar.gz
sha256sum steamos-arm-handhelds-sm8550-<tag>-update.tar.gz
```

It checks the `.7z` parts against `SHA256SUMS` when it sits next to them, and `konkr-update.py inspect <package>` sanity-checks the result.
