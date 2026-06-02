# stage2/06-usb-gadget — notes & open items

USB composite gadget (CDC-NCM network + UVC webcam) for OTG-capable
boards (Pi Zero / Zero W, Zero 2 W, Pi 4; Pi 5 on the future 64-bit
image). Pi 3 / 3+ have no OTG port and are skipped at runtime by
`rpi-cam-gadget-detect.sh`.

## What this stage ships today (repo A, NCM-first)

- `[pi0]`/`[pi02]`/`[pi4]` dwc2 peripheral/otg sections in
  `stage1/00-boot-files/files/config.txt`, plus
  `modules-load=dwc2,libcomposite` in `cmdline.txt`.
- A board-detection oneshot that writes `/run/rpi-cam-gadget.enabled`
  or `.disabled`.
- A gadget-setup oneshot that builds the composite gadget via
  configfs/libcomposite. **CDC-NCM only by default** — the UVC function
  is written but gated behind `GADGET_ENABLE_UVC=1` (default off).
- NetworkManager `usb0-host.nmconnection` (`method=shared`, 10.55.0.1/24).
- A locked-down `rpi-cam-gadget-rebind.sh` + sudoers entry for the
  (future) rpi-camera pump to re-bind the UDC on resolution changes.

With UVC off, `rpi-cam-gadget-setup.sh` binds the UDC itself, so USB
networking comes up at boot with no userspace help — this is the
Step 2 (NCM-only) deliverable from the implementation plan.

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

## NEXT: turning UVC on (repo B coupling)

When the rpi-camera UVC pump (repo B) is ready:
1. Set `GADGET_ENABLE_UVC=1` for the setup script (env in the unit, or
   flip the default).
2. Remove the self-bind block at the end of `rpi-cam-gadget-setup.sh`
   (the `[ "${GADGET_ENABLE_UVC}" != "1" ]` branch) — rpi-camera will
   bind the UDC after writing the real streaming descriptors.
3. Add the `RPI_CAMERA_ENABLE_UVC` / `RPI_CAMERA_UVC_GADGET_PATH` /
   `RPI_CAMERA_GADGET_REBIND_HELPER` env vars to the
   `stage2/05-rpi-camera/01-run.sh` install call. (Deliberately NOT done
   yet: the released install ignores them, so they'd be dead config.)
4. Fix the `RPI_CAM_USER` fallback in `rpi-cam-gadget-setup.sh` (the UVC
   `chgrp` currently falls back to `pi`) to the real `FIRST_USER_NAME`,
   e.g. bake it in via the unit's `Environment=`.
