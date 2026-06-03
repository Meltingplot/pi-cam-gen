#!/bin/bash
# Build a SINGLE-FUNCTION USB gadget via configfs/libcomposite: either a UVC
# webcam OR a CDC-NCM network device.
#
# Why not both at once? A composite UVC+NCM gadget does NOT enumerate reliably
# on the Pi's dwc2 UDC (it intermittently comes up full-speed with a dead ep0;
# each function works fine on its own). So we run one function at a time and
# switch between them at runtime — see rpi-cam-gadget-mode.sh: boot as UVC and
# fall back to NCM if no host opens the video stream within a grace period.
#
# Usage: rpi-cam-gadget-setup.sh [uvc|ncm]   (default: $GADGET_MODE, else uvc)
# Re-runnable: it fully tears down any existing gadget first, so it doubles as
# the runtime mode-switch primitive.
set -eu

MODE="${1:-${GADGET_MODE:-uvc}}"
case "${MODE}" in
	uvc|ncm) ;;
	*) echo "rpi-cam-gadget: unknown mode '${MODE}' (expected uvc|ncm)" >&2; exit 2 ;;
esac

GADGET=/sys/kernel/config/usb_gadget/picam
CONFIGFS=/sys/kernel/config

modprobe libcomposite

# configfs must be mounted (systemd mounts sys-kernel-config.mount); bail
# loudly rather than silently producing a half-built gadget.
if [ ! -d "${CONFIGFS}/usb_gadget" ]; then
	echo "rpi-cam-gadget: ${CONFIGFS}/usb_gadget missing (libcomposite/configfs?)" >&2
	exit 1
fi

# Fully tear down any previous gadget so this script is re-runnable (and can
# switch modes at runtime). Order matters in configfs: unbind the UDC, drop the
# config->function links + config dirs deepest-first, then the function
# symlinks + dirs, then strings.
teardown_gadget() {
	[ -d "${GADGET}" ] || return 0
	echo "" > "${GADGET}/UDC" 2>/dev/null || true
	find "${GADGET}"/configs -type l -delete 2>/dev/null || true
	find "${GADGET}"/configs -mindepth 1 -depth -type d -exec rmdir {} + 2>/dev/null || true
	find "${GADGET}"/functions -type l -delete 2>/dev/null || true
	find "${GADGET}"/functions -mindepth 1 -depth -type d -exec rmdir {} + 2>/dev/null || true
	rmdir "${GADGET}"/strings/* 2>/dev/null || true
	rmdir "${GADGET}" 2>/dev/null || true
}
teardown_gadget

mkdir -p "${GADGET}"
cd "${GADGET}"

# 0x1d6b:0x0104 = Linux Foundation / Multifunction Composite Gadget.
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

# Stable serial (and thus stable MACs) from the board serial so the host
# does not hand out a fresh DHCP lease on every reboot.
SERIAL="$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null || true)"
[ -n "${SERIAL}" ] || SERIAL="$(awk '/^Serial/ {print $3}' /proc/cpuinfo 2>/dev/null || true)"
[ -n "${SERIAL}" ] || SERIAL="0000000000000000"

mkdir -p strings/0x409
echo "meltingplot" > strings/0x409/manufacturer
echo "Pi Cam"      > strings/0x409/product
echo "${SERIAL}"   > strings/0x409/serialnumber

mkdir -p configs/c.1/strings/0x409
echo "Pi Cam (${MODE})" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# --- CDC-NCM network function -----------------------------------------
build_ncm() {
	# IAD device class so the CDC-NCM function binds cleanly on Windows too.
	echo 0xEF > bDeviceClass
	echo 0x02 > bDeviceSubClass
	echo 0x01 > bDeviceProtocol

	# Locally-administered MACs from the last 10 hex digits of the serial.
	# Host and device get a different first octet so they never clash.
	S="$(printf '%s' "${SERIAL}" | tail -c 10)"
	S="$(printf '%010s' "${S}" | tr ' ' '0')"
	mac_tail="${S:0:2}:${S:2:2}:${S:4:2}:${S:6:2}:${S:8:2}"

	mkdir -p functions/ncm.usb0
	echo "02:${mac_tail}" > functions/ncm.usb0/dev_addr
	echo "06:${mac_tail}" > functions/ncm.usb0/host_addr
	ln -sf functions/ncm.usb0 configs/c.1/
	echo "rpi-cam-gadget: built NCM gadget"
}

# --- UVC webcam function ----------------------------------------------
# A single MJPEG format advertising SEVERAL frame sizes; the USB host picks one
# via PROBE/COMMIT and the rpi-camera pump (uvc_gadget.py) drives picamera2 to
# it and feeds JPEG frames into the resulting /dev/videoN, pacing delivery.
# bDeviceClass is left at its default (per-interface) — a plain UVC webcam; the
# UVC IAD in the config groups VideoControl + VideoStreaming.
build_uvc() {
	# Advertised frame sizes (ascending — the order IS the UVC bFrameIndex).
	# MUST match gadget_frames() in rpi-camera's uvc_gadget.py. The largest
	# frame is bounded per board to what the hardware can sensibly stream:
	#   single-core Pi Zero / Zero W -> up to 720p   (ARMv6, mem + CPU bound)
	#   Pi Zero 2 W                  -> up to 1080p
	#   everything else (Pi 4/5/...) -> up to 4608x2592 (IMX708 full sensor)
	#
	# UVC_INTERVAL is the iso endpoint bInterval: it is serviced every
	# 2^(bInterval-1) microframes, so it costs ~8000/2^(bInterval-1)
	# interrupts/sec. bInterval=1 (every microframe, 8000 int/s) buries the
	# single-core ARMv6 Pi Zero in softirqs even at idle; raise it there.
	MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
	if echo "${MODEL}" | grep -q 'Zero 2'; then
		FRAMES="640x480 1280x720 1920x1080"
		UVC_INTERVAL=1
	elif echo "${MODEL}" | grep -q 'Zero'; then
		FRAMES="640x480 1280x720"
		UVC_INTERVAL=3
	else
		FRAMES="640x480 1280x720 1920x1080 2304x1296 4608x2592"
		UVC_INTERVAL=1
	fi
	# Single-transaction iso, MUST stay <= 1024: a value >1024 forces
	# high-bandwidth iso (>1 transaction/microframe), which the Pi's dwc2 UDC
	# does NOT support in device mode (it then underruns on every request and
	# pins a core at 100%).
	UVC_MAXPACKET=1024

	UVC=functions/uvc.usb0
	mkdir -p "${UVC}"

	# One frame descriptor per advertised size. dwMaxVideoFrameBufferSize is a
	# 1 byte/pixel MJPEG ceiling (matches the pump's buffer sizing). Each frame
	# advertises the same interval list (100 ns units): 30/15/10/5/4/2/1 fps.
	idx=0
	default_idx=1
	for res in ${FRAMES}; do
		idx=$(( idx + 1 ))
		w="${res%x*}"; h="${res#*x}"
		# Zero-padded name so the lexical order matches bFrameIndex order.
		frm="$(printf '%s/streaming/mjpeg/m/%04dx%04d' "${UVC}" "${w}" "${h}")"
		mkdir -p "${frm}"
		echo "${w}" > "${frm}/wWidth"
		echo "${h}" > "${frm}/wHeight"
		echo "$(( w * h ))" > "${frm}/dwMaxVideoFrameBufferSize"
		echo 333333 > "${frm}/dwDefaultFrameInterval"
		printf '%s\n' 333333 666666 1000000 2000000 2500000 5000000 10000000 > "${frm}/dwFrameInterval"
		[ "${w}x${h}" = "1280x720" ] && default_idx="${idx}"
	done
	# Default to 720p where present (safe, widely supported).
	echo "${default_idx}" > "${UVC}/streaming/mjpeg/m/bDefaultFrameIndex"

	# Streaming header links the MJPEG format instance, then fs/hs/ss.
	mkdir -p "${UVC}/streaming/header/h"
	ln -s "${GADGET}/${UVC}/streaming/mjpeg/m" "${UVC}/streaming/header/h/m"
	ln -s "${GADGET}/${UVC}/streaming/header/h" "${UVC}/streaming/class/fs/h"
	ln -s "${GADGET}/${UVC}/streaming/header/h" "${UVC}/streaming/class/hs/h"
	ln -s "${GADGET}/${UVC}/streaming/header/h" "${UVC}/streaming/class/ss/h"

	# Control header links into fs/ss (the kernel exposes no hs dir for control).
	mkdir -p "${UVC}/control/header/h"
	ln -s "${GADGET}/${UVC}/control/header/h" "${UVC}/control/class/fs/h"
	ln -s "${GADGET}/${UVC}/control/header/h" "${UVC}/control/class/ss/h"

	# Advertise the camera controls the rpi-camera pump maps to libcamera.
	# Guarded: an older kernel without writable bmControls still comes up.
	pu_bm="${UVC}/control/processing/default/bmControls"
	ct_bm="${UVC}/control/terminal/camera/default/bmControls"
	[ -e "${pu_bm}" ] && { echo 0x1b 0x12 0x00 > "${pu_bm}" 2>/dev/null \
		|| echo "rpi-cam-gadget: warn: could not set PU bmControls" >&2; }
	[ -e "${ct_bm}" ] && { echo 0x2a 0x00 0x02 > "${ct_bm}" 2>/dev/null \
		|| echo "rpi-cam-gadget: warn: could not set CT bmControls" >&2; }

	echo "${UVC_MAXPACKET}" > "${UVC}/streaming_maxpacket"
	echo "${UVC_INTERVAL}"  > "${UVC}/streaming_interval"

	ln -s "${GADGET}/${UVC}" configs/c.1/
	echo "rpi-cam-gadget: built UVC gadget, frames [${FRAMES}], default #${default_idx}, streaming_interval=${UVC_INTERVAL}"
}

case "${MODE}" in
	ncm) build_ncm ;;
	uvc) build_uvc ;;
esac

# Bind the gadget to the UDC. The /dev/videoN node (UVC) or usb0 (NCM) appears
# once this completes.
udc="$(ls /sys/class/udc | head -n1)"
if [ -z "${udc}" ]; then
	echo "rpi-cam-gadget: no UDC available (is dwc2 in peripheral mode?)" >&2
	exit 1
fi
echo "${udc}" > UDC
echo "rpi-cam-gadget: bound ${MODE} gadget to UDC ${udc}"
