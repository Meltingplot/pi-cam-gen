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

## OPEN: audit the `rpi-usb-gadget` Debian package (plan step 3)

`rpi-usb-gadget` is pulled in by `stage2/01-sys-tweaks/00-packages`. It
is currently unknown whether it ships its own configfs setup scripts /
systemd units that would fight ours over the same UDC.

Before enabling UVC / shipping widely, on a built rootfs run:

    dpkg -L rpi-usb-gadget
    systemctl list-unit-files | grep -i gadget

Then decide and record here:
- coexist (mask its unit in `00-run.sh`), or
- reuse it (drop our setup script, write its config file instead), or
- drop the package from `00-packages` (nothing else depends on it).

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
