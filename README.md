# pi-cam-gen

**Turn a Raspberry Pi + camera module into a plug-and-play network camera.**

`pi-cam-gen` builds a ready-to-flash, headless Raspberry Pi OS image that boots
straight into [`meltingplot.rpi_camera`](https://github.com/Meltingplot/rpi-camera) —
a camera streaming service with a web UI. Flash it, set your WiFi, boot, and you
have an IP camera (MJPEG/HTTP) on your network. Plug it into a computer over USB
and a captive-portal page pops the same UI open automatically.

It's a customized fork of [RPi-Distro/pi-gen](https://github.com/RPI-Distro/pi-gen),
so everything you know about building pi-gen images still applies — see
[Building the image yourself](#building-the-image-yourself) below.

---

## What you get

One **universal 32-bit image** (Raspbian *trixie* `armhf`, ARMv6) that runs on
every Pi from the **Zero W** up to the **Pi 4** — including the **Zero 2 W** and
**Pi 3 / 3+**. No per-model downloads.

| Feature | What it does |
| --- | --- |
| 📷 **`meltingplot.rpi_camera` service** | Camera capture + MJPEG/HTTP stream with a web UI, started at boot. |
| 🌐 **IP camera over WiFi** | Reach the stream and web UI from any browser on your network. |
| 🔌 **USB gadget (OTG boards)** | Plug the Pi into a host over USB; it appears as a network device (CDC-NCM). A UVC webcam function is opt-in (drop `uvc-enable` on the boot partition). |
| 🪟 **Captive portal on USB** | On connect, the host's OS connectivity check is hijacked to the Pi, so the webcam UI pops up automatically (Windows/macOS/Linux). |
| 🩺 **WiFi & frame watchdogs** | Auto-reboot if the WiFi radio wedges; restart/reboot if the camera stops delivering frames. Toggleable from the web UI. |
| ⬆️ **In-place updater** | An "Update" button (or SSH) upgrades the camera package and refreshes the gadget files from the latest release, then restarts the service. |
| ☁️ **First-boot customization** | WiFi, SSH, user, hostname, locale, etc. are applied on first boot via Raspberry Pi Imager's wizard (cloud-init). |
| 🔒 **Hardened by default** | Headless, no default user/password, locked-down `sudoers` for each privileged helper. |

---

## Quick start — flash it with Raspberry Pi Imager

The easiest way to install. Point [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
(v1.9+) at this repo's image catalog so the **customization wizard** (WiFi, SSH,
user, hostname, locale) is available:

```bash
rpi-imager --repo https://github.com/Meltingplot/pi-cam-gen/releases/latest/download/os_list.json
```

Then:

1. Pick **Meltingplot Pi Camera → 32-bit · Zero W to Pi 4**.
2. Click the gear / **Edit Settings** and set at least your **WiFi network** and
   country. Optionally enable SSH, set the username/password, hostname, and locale.
3. Choose your SD card and **Write**.

> 💡 You *can* flash the `.img.xz` directly via Imager's **Use Custom** option,
> but that disables the customization wizard — that's Imager's behavior, not a
> property of the image. Use `--repo` to keep the wizard.

### First boot

- The Pi joins your WiFi, renames the first user, and starts the camera service.
- Open the web UI in a browser. If you set a hostname `mycam`, try
  `http://mycam.local` (mDNS). Otherwise find the Pi's IP from your router.

### Connect over USB (OTG boards: Zero / Zero 2 W / Pi 4)

Plug the Pi's USB **data** port into your computer. It enumerates as a USB
network device and serves DHCP on `10.55.0.1`. Your OS's connectivity check is
redirected to the Pi, so the **webcam UI opens automatically** — no IP to type.

To also expose a **USB webcam (UVC)** device — so apps like a video-conferencing
client see it as a regular camera — create an empty file named `uvc-enable` on
the boot (FAT) partition and reboot. It's off by default because the UVC pump is
CPU-heavy on the smaller boards.

---

## How releases work

Tagging a `v*` release triggers the [build workflow](.github/workflows/build.yml),
which builds the image on an ARM runner (~2h) and publishes a GitHub Release
containing:

- `meltingplot-pi-cam-<codename>-<date>-<cam-version>-armhf.img.xz` + `.sha256`
- `os_list.json` — the Raspberry Pi Imager v4 catalog the `--repo` flag consumes.

URLs inside `os_list.json` are pinned to the tag, but the catalog is also
reachable at the stable `releases/latest/download/os_list.json` path used above.

A scheduled workflow,
[`check-rpi-camera-version.yml`](.github/workflows/check-rpi-camera-version.yml),
watches the upstream `meltingplot.rpi_camera` package for new releases and opens
a PR to bump the pinned version in
[`stage2/05-rpi-camera/files/rpi-camera-version`](stage2/05-rpi-camera/files/rpi-camera-version).

---

## What's in the image — stage layout

This repo runs only **stage0–stage2** (a headless Lite image); the desktop
stages (3–5) from upstream pi-gen are not built.

| Path | Purpose |
| --- | --- |
| [stage0/](stage0/) | Bootstrap — debootstrap, apt sources, firmware. |
| [stage1/](stage1/) | Minimal bootable system — boot files, `dwc2`/`libcomposite` for USB gadget, fstab, networking. |
| [stage2/05-rpi-camera/](stage2/05-rpi-camera/) | Installs `meltingplot.rpi_camera` into a venv, its systemd service, watchdog + updater sudoers. |
| [stage2/06-usb-gadget/](stage2/06-usb-gadget/) | Composite USB gadget (CDC-NCM + optional UVC), captive portal, `usb0` NetworkManager profile. See [NOTES.md](stage2/06-usb-gadget/NOTES.md). |
| [stage2/02-net-tweaks/](stage2/02-net-tweaks/) | WiFi safety watchdog (reboot on radio wedge). |
| [stage2/04-cloud-init/](stage2/04-cloud-init/) | cloud-init for Imager's first-boot customization. |
| [export-image/](export-image/) | Image finalization — first-user rename, sources, PARTUUID. |

Per-board capture / UVC resolutions are the single source of truth in
[`stage2/06-usb-gadget/files/etc/rpi-camera/frames.conf`](stage2/06-usb-gadget/files/etc/rpi-camera/frames.conf),
read by both the UVC gadget descriptors and the web UI's resolution list so they
can never drift.

---

## Building the image yourself

The image is produced by pi-gen (this repo is a fork). The full build
instructions, config reference, Docker build, and troubleshooting live in
**[BUILDING.md](BUILDING.md)**.

The short version:

```bash
cat > config <<'EOF'
IMG_NAME='meltingplot-pi-cam'
RELEASE='trixie'
DEPLOY_COMPRESSION='xz'
COMPRESSION_LEVEL='6'
ENABLE_SSH='0'
STAGE_LIST='stage0 stage1 stage2'
EOF

sudo ./build.sh   # or ./build-docker.sh
```

The finished image lands in `deploy/`.

---

## License

Based on [pi-gen](https://github.com/RPI-Distro/pi-gen) — see [LICENSE](LICENSE)
(Copyright © Raspberry Pi (Trading) Ltd.).
