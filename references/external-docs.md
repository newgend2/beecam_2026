# External Documentation Index

Curated links for BeeCam development. PDF manuals live in this directory;
source code for Picamera2, IMX500 models, and Witty Pi is fetched locally via
`./scripts/fetch-opensrc-sources.sh` into the gitignored `opensrc/` folder.

## Picamera2 and AI Camera

| Resource | Location |
|----------|----------|
| Picamera2 manual (PDF) | [RP-008156-DS-2-picamera2-manual.pdf](./RP-008156-DS-2-picamera2-manual.pdf) |
| Picamera2 source (opensrc) | `opensrc/repos/github.com/raspberrypi/picamera2/` |
| Raspberry Pi AI Camera guide | https://www.raspberrypi.com/documentation/accessories/ai-camera.html |
| Picamera2 GitHub | https://github.com/raspberrypi/picamera2 |
| IMX500 models GitHub | https://github.com/raspberrypi/imx500-models |
| IMX500 models source (opensrc) | `opensrc/repos/github.com/raspberrypi/imx500-models/` |

### Matching Picamera2 source to a deployed Pi

Field Pis install Picamera2 via apt (`python3-picamera2`), not directly from
GitHub. The fetch script pins a recent release tag as a baseline. To match a
specific camera, check its installed version and refetch if needed:

```bash
python3 -c "import picamera2; print(picamera2.__version__)"
npx opensrc@0.6 raspberrypi/picamera2@<version> --modify
```

## Witty Pi 4 Mini

| Resource | Location |
|----------|----------|
| Witty Pi 4 Mini manual (PDF) | [WittyPi4Mini_UserManual.pdf](./WittyPi4Mini_UserManual.pdf) |
| Witty Pi 4 manual (PDF, full-size board) | https://www.uugear.com/doc/WittyPi4_UserManual.pdf |
| Witty Pi 4 source (opensrc) | `opensrc/repos/github.com/uugear/Witty-Pi-4/Software/wittypi/` |
| Witty Pi 4 Mini firmware (opensrc) | `opensrc/repos/github.com/uugear/Witty-Pi-4/Firmware/WittyPi4/WittyPi4_Mini.ino.hex` |
| UWI Witty Pi 4 support (opensrc) | `opensrc/repos/github.com/uugear/UUGear-Web-Interface/uwi/wittypi4/` |
| Witty Pi 4 GitHub | https://github.com/uugear/Witty-Pi-4 |

BeeCam runtime overlays are in `wittypi/` and `weather_station/wittypi/`.
Compare against upstream before changing schedule logic.
