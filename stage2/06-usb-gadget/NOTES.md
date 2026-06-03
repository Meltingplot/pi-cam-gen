# stage2/06-usb-gadget — notes & open items

USB gadget (a **UVC webcam** OR a **CDC-NCM** network device — one at a time,
not a composite) for OTG-capable boards (Pi Zero / Zero W, Zero 2 W, Pi 4;
Pi 5 on the future 64-bit image). Pi 3 / 3+ have no OTG port and are skipped at
runtime by `rpi-cam-gadget-detect.sh`.

## Why single-function (UVC ⇄ NCM switch, not a composite)

A composite UVC+NCM gadget does **not** enumerate reliably on the Pi's dwc2
UDC: it intermittently comes up full-speed with a dead ep0 (the host logs
`device descriptor read … -110`; the device shows `Mode Mismatch Interrupt`
and an over-allocated RX FIFO). Each function works perfectly **alone**;
together they don't. This matches long-standing reports on the RPi forums —
composite UVC+ethernet only "works" in narrow corners (Pi 4 / Ubuntu / ECM).
So we run one function at a time and switch:

- **Boot → UVC** by default (`rpi-cam-gadget-mode.sh init`).
- If **no host opens the UVC stream within ~30 s** (`rpi-cam-gadget-fallback.timer`),
  tear UVC down and bring up **NCM** so the host can pull the MJPEG/HTTP stream
  over USB networking instead. The pump signals an opened stream by touching
  `/run/rpi-camera/uvc-active` (rpi-camera `reconfig.py`).
- **Override:** drop a file named **`ncm-mode`** on the boot partition
  (`/boot/firmware/ncm-mode`) to skip UVC and boot straight to NCM — pull the
  SD card on any PC, create the file, done.
- dwc2 runs in **`dr_mode=peripheral`** (deterministic gadget; `otg` left the
  role to the floating ID pin and caused the mismatch storm).

## What this stage ships today (repo A)

- `[pi0]`/`[pi02]`/`[pi4]` dwc2 peripheral/otg sections in
  `stage1/00-boot-files/files/config.txt`, plus
  `modules-load=dwc2,libcomposite` in `cmdline.txt`.
- A board-detection oneshot that writes `/run/rpi-cam-gadget.enabled`
  or `.disabled`.
- A gadget-setup oneshot that builds the composite gadget via
  configfs/libcomposite: **CDC-NCM + UVC** (`GADGET_ENABLE_UVC=1`,
  default on). UVC advertises a single MJPEG format at the board
  resolution (720p on Zero/Zero W, 1080p else) following a known-good
  configfs layout (fs/hs/ss streaming class, `streaming_maxpacket`),
  then binds the UDC.
- NetworkManager `usb0-host.nmconnection` (`method=shared`, 10.55.0.1/24).
- A locked-down `rpi-cam-gadget-rebind.sh` + sudoers entry for a future
  dynamic-resolution pump to re-bind the UDC (unused by the current
  fixed-resolution MVP).

The rpi-camera service (>= 1.0.0rc11) runs `uvc_gadget.UvcGadget`, which
auto-detects the output `/dev/videoN`, answers UVC PROBE/COMMIT and pumps
the live MJPEG frames. NCM networking + the HTTP/MJPEG web stream keep
working alongside UVC (picamera2 is the single camera owner).

## DONE: `rpi-usb-gadget` Debian package audit (plan step 3)

Audited on a v0.0.7 image (`dpkg -L rpi-usb-gadget` +
`systemctl list-unit-files | grep -i gadget`):

    /usr/bin/rpi-usb-gadget
    /usr/lib/modprobe.d/g_ether.conf
    /usr/lib/systemd/system/rpi-usb-gadget-ics.service   # shipped DISABLED
    /usr/libexec/rpi-usb-gadget/ics-watch
    /etc/update-motd.d/99-rpi-usb-gadget

    rpi-cam-gadget-detect.service   enabled
    rpi-cam-gadget.service          enabled
    rpi-usb-gadget-ics.service      disabled
    usb-gadget.target               static

Verdict: **no conflict.** The package's only unit
(`rpi-usb-gadget-ics.service`) ships disabled and uses the legacy
single-function `g_ether` path (`/usr/lib/modprobe.d/g_ether.conf`),
which we never trigger — we load `libcomposite` + a configfs `ncm`
function instead. The modprobe.d file is inert unless `g_ether` is
loaded.

Action taken: `00-run.sh` now `systemctl mask`s
`rpi-usb-gadget-ics.service` defensively, so a future `raspi-config`
or manual enable can't bring up a second gadget that fights us over
the single UDC. The package stays installed (cheap, and other RPi
tooling may reference it).

## OPEN: single-core performance measurement (plan step 0 / 6.5)

Target board Pi Zero W = BCM2835, ARM1176, single core @ 1 GHz. Before
investing in the rpi-camera UVC pump, measure on real hardware:

- `rpi-camera start` with HTTP MJPEG + UVC pump simultaneously at 720p
  and 1080p; watch `top`/`pidstat`, log both sinks' frame rates.
- If the one core saturates at 1080p: default UVC to 720p, possibly cap
  simultaneous HTTP+UVC at 720p. Record the chosen resolution caps here.

## NEXT: dynamic resolution / fps (deferred to a later rc)

The current UVC is fixed-resolution per board. To follow web-UI
resolution/fps changes live (plan steps 7/8/12), add to rpi-camera:
- `gadget.py` (rewrite configfs streaming descriptors) + the
  `rpi-cam-gadget-rebind.sh` helper (already shipped here) to re-bind the
  UDC, driven by a `CameraController` change listener.
- the subscribe-model frame buffer + `FrameRateGovernor`.
The descriptor resolution would then be written by Python (not this
script), and the UVC `S_FMT`/probe-commit would be re-negotiated.

## FIRST HARDWARE TEST (Pi Zero 2 W), then Zero W

UVC is **untested on hardware** — `uvc_gadget.py` is a from-scratch port
of the kernel uvc-gadget select loop. Expect a HW iteration round. When
testing:
- `journalctl -u rpi-camera` — look for "UVC gadget node: /dev/videoN",
  "streaming WxH started", or ioctl errors.
- Host: the Pi should enumerate a UVC webcam; `v4l2-ctl --list-devices`,
  `ffplay -f v4l2 /dev/videoN` (Linux host) / Camera app (Win/macOS).
- NCM networking + `http://<host>.local:8081/` must keep working
  alongside.
- On the single-core **Zero W**, also watch `top` for CPU saturation at
  720p HTTP+UVC; drop resolution if the one core can't keep up.
