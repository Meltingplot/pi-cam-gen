# stage2/06-usb-gadget — notes & open items

USB gadget for OTG-capable boards (Pi Zero / Zero W, Zero 2 W, Pi 4; Pi 5 on the
future 64-bit image). Pi 3 / 3+ have no OTG port and are skipped at runtime by
`rpi-cam-gadget-detect.sh`. **Default: CDC-NCM only** — the product is an IP
camera (MJPEG/HTTP over WiFi or USB networking), so a network function is all it
needs. The **UVC webcam is opt-in**: drop a file named `uvc-enable` on the boot
partition and `rpi-cam-gadget-setup.sh` also builds the UVC function. It works
fine (see below); it's off by default purely because its isochronous pump costs
too much CPU on the small boards.

## UVC composite works — the "it can't enumerate on dwc2" belief was a misdiagnosis

The UVC+NCM composite once appeared to enumerate unreliably: it came up
full-speed with a dead ep0 (`device descriptor read … -110`, an over-allocated
RX FIFO `GRXFSIZ=0x1000`). The real cause was **not** dwc2 and **not** the
composite — it was the userspace pump (`uvc_gadget.py` `find_device()`) opening
the **wrong V4L2 node** (`bcm2835-isp` instead of the `g_uvc` gadget node). The
UVC streaming endpoint was therefore never configured, so dwc2 kept its
oversized default RX FIFO, overflowed the 4080-word SPRAM, and dropped to
full-speed. Once the pump opens the correct node and sets a format, dwc2
recomputes the FIFO (`GRXFSIZ=0x22e`=558, fits) and the device (re-)enumerates
high-speed.

So when UVC is enabled it works, high-speed, alongside NCM:

- NCM is linked **first** (interfaces 0–1), UVC second (2–3). NCM's bulk-OUT
  endpoint sizes the RX FIFO small before the UVC iso-IN endpoint, so the FIFO
  fits the SPRAM from the first bind — no full-speed window, no "prime" step.
- `rpi-cam-gadget-setup.sh` (no args) builds and binds; the
  `rpi-cam-gadget.service` oneshot runs it at boot.
- dwc2 runs in **`dr_mode=otg`** (forced `peripheral` left the HS PHY wedged at
  full-speed on the Zero 2 W; otg does the full bring-up and resolves to
  peripheral when attached).

Per-board capture/UVC **resolutions live in one shared file**,
`/etc/rpi-camera/frames.conf` (`<model-substring>|WxH:fps,...`), read by BOTH
this setup script and rpi-camera's web UI — so the gadget descriptors and the
UI resolution list can never drift. It's a plain file, not configfs, precisely
because UVC (hence configfs) is off by default.

The earlier UVC⇄NCM mode-switch, the `rpi-cam-gadget-mode.sh` helper, the
`-fallback` service/timer, and the `/boot/firmware/ncm-mode` flag are all
**removed**.

## What this stage ships today

- `[pi0]`/`[pi02]`/`[pi4]` dwc2 otg sections in
  `stage1/00-boot-files/files/config.txt`, plus
  `modules-load=dwc2,libcomposite` in `cmdline.txt`.
- A board-detection oneshot that writes `/run/rpi-cam-gadget.enabled`
  or `.disabled`.
- A gadget-setup oneshot that builds the composite gadget via
  configfs/libcomposite: **CDC-NCM + UVC**. UVC advertises one MJPEG format
  with several frame sizes per board (up to 720p on Zero/Zero W, 1080p on
  Zero 2 W, 4608×2592 on Pi 4/5), each with its full advertised fps list, at
  iso `streaming_maxpacket=2048` (high-bandwidth iso), then binds the UDC.
- NetworkManager `usb0-host.nmconnection` (`method=shared`, 10.55.0.1/24).
- NetworkManager `usb0-uplink.nmconnection`: a **macvlan child of usb0**
  (`usb0u`, bridge mode — `mode=2` in the keyfile) running a plain DHCP client. usb0 itself stays the
  captive-portal server (above); this child only ever talks to the external
  host. So out of the box the Pi serves the host (captive portal), and the
  moment the host enables internet sharing (Windows ICS → 192.168.137.x;
  no clash with 10.55.0.0/24) the child gets a lease + default route + DNS and
  the **Pi gains internet over USB** — e.g. so the USB-gated "Update software"
  button can actually reach PyPI/GitHub without WiFi.
  - Why macvlan and not a second address on usb0: NM can't run `method=shared`
    (server) and `method=auto` (client) on one connection, and two DHCP roles
    on one stack race. A macvlan child is a separate netdev/MAC, and **macvlan
    parent↔child isolation** means usb0's dnsmasq never sees the child's
    DISCOVER, so it can't self-lease — no authoritative/MAC-ignore tuning
    needed. Bridging the two would re-merge the L2 segment and reintroduce the
    conflict; macvlan keeps them separate.
  - `route-metric=800` (fallback): WiFi/Ethernet stay preferred when they have a
    route; the USB uplink carries traffic only when nothing better exists.
  - In ICS mode 10.55.0.1 is unreachable from the host (it's now on
    192.168.137.0/24, no route to 10.55.0.0/24). The child therefore also
    carries a FIXED second address `192.168.137.250/24` (Windows ICS is always
    192.168.137.1/24), so the UI is reachable at a predictable
    `http://192.168.137.250` without relying on the DHCP lease or mDNS (Windows
    frequently can't resolve `<hostname>.local` over the ICS NIC). The
    captive-portal auto-popup won't fire in ICS mode either, because the host's
    own uplink answers its connectivity checks — expected.
  - On a non-OTG board (no `usb0`) NM can't activate the child; it stays idle.
- A locked-down `rpi-cam-gadget-rebind.sh` + sudoers entry for the pump to
  re-bind the UDC on a descriptor change (unused by the current fixed-descriptor
  negotiation path).

The rpi-camera service runs `uvc_gadget.UvcGadget`, which selects the `g_uvc`
output node by its QUERYCAP driver string, answers UVC PROBE/COMMIT and pumps
the live MJPEG frames. NCM networking + the HTTP/MJPEG web stream keep working
alongside UVC (picamera2 is the single camera owner).

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
