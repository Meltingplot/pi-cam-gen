#!/bin/bash
# rpi-cam-gadget-reconfig.sh <width> <height> <fps>
#
# Rewrite the UVC streaming descriptors (resolution, frame interval and the
# isochronous bandwidth) for a new capture format and re-bind the UDC, so a
# web-UI resolution/fps change takes effect on the host. Runs as root via
# the rpi-camera service's sudoers grant; the arguments are validated to be
# numeric so this stays a narrow gadget-only primitive.
#
# The descriptor/bitrate maths is kept in sync with rpi-cam-gadget-setup.sh.
set -eu

W="${1:?usage: $0 <width> <height> <fps>}"
H="${2:?usage: $0 <width> <height> <fps>}"
FPS="${3:?usage: $0 <width> <height> <fps>}"
case "${W}${H}${FPS}" in
	''|*[!0-9]*) echo "rpi-cam-gadget-reconfig: non-numeric argument" >&2; exit 2 ;;
esac
[ "${FPS}" -ge 1 ] || { echo "rpi-cam-gadget-reconfig: fps must be >= 1" >&2; exit 2; }

GADGET=/sys/kernel/config/usb_gadget/picam
UVC="${GADGET}/functions/uvc.usb0"
[ -d "${UVC}" ] || { echo "rpi-cam-gadget-reconfig: no uvc function" >&2; exit 1; }

MAXPACKET=2048
INTERVAL=$(( 10000000 / FPS ))   # dwFrameInterval, 100 ns units

# streaming_interval: highest bInterval (lowest bandwidth/CPU) whose iso
# capacity still covers the bitrate budget. Same formula as the setup script.
budget=$(( FPS * W * H * 12 / 100 ))
si=1
for i in $(seq 1 16); do
	cap=$(( 8000 / (1 << (i - 1)) * MAXPACKET ))
	if [ "${cap}" -ge "${budget}" ]; then
		si=${i}
	else
		break
	fi
done

# Descriptors are only mutable while unbound.
echo "" > "${GADGET}/UDC" 2>/dev/null || true

frm="$(find "${UVC}/streaming/mjpeg/m" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "${frm}" ] || { echo "rpi-cam-gadget-reconfig: no uvc frame dir" >&2; exit 1; }
echo "${W}" > "${frm}/wWidth"
echo "${H}" > "${frm}/wHeight"
echo "$(( W * H * 2 ))" > "${frm}/dwMaxVideoFrameBufferSize"
echo "${INTERVAL}" > "${frm}/dwDefaultFrameInterval"
printf '%s\n' "${INTERVAL}" > "${frm}/dwFrameInterval"
echo "${si}" > "${UVC}/streaming_interval"

udc="$(ls /sys/class/udc | head -n1)"
[ -n "${udc}" ] || { echo "rpi-cam-gadget-reconfig: no UDC" >&2; exit 1; }
echo "${udc}" > "${GADGET}/UDC"
echo "rpi-cam-gadget: reconfigured to ${W}x${H} @ ${FPS}fps (streaming_interval=${si})"
