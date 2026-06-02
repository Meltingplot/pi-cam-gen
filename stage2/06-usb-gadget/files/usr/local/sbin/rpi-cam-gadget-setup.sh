#!/bin/bash
# Build the USB composite gadget (CDC-NCM network + optional UVC webcam)
# via configfs/libcomposite. Runs once at boot from rpi-cam-gadget.service,
# only on OTG-capable boards (gated by /run/rpi-cam-gadget.enabled).
#
# Phase status:
#   - CDC-NCM is always created so USB networking comes up at boot.
#   - The UVC function (GADGET_ENABLE_UVC=1, default on) advertises a single
#     MJPEG format with SEVERAL frame sizes (per-board, see tiers below) and
#     frame intervals up to 30 fps. This script writes the descriptors ONCE
#     and binds the UDC; they are never rewritten at runtime. The USB host
#     picks a resolution/fps via PROBE/COMMIT; the rpi-camera Python pump
#     (uvc_gadget.py) honours that choice, drives picamera2 to it, and feeds
#     frames into the resulting /dev/videoN, pacing delivery itself.
#
#     Because the host negotiates the resolution the regular UVC way, a change
#     needs NO descriptor rewrite and NO forced re-enumeration. The
#     isochronous endpoint is sized for the largest frame and simply idles at
#     low fps, so there is no fps-dependent bandwidth tuning here.
set -eu

GADGET_ENABLE_UVC="${GADGET_ENABLE_UVC:-1}"

GADGET=/sys/kernel/config/usb_gadget/picam
CONFIGFS=/sys/kernel/config

modprobe libcomposite

# configfs must be mounted (systemd mounts sys-kernel-config.mount); bail
# loudly rather than silently producing a half-built gadget.
if [ ! -d "${CONFIGFS}/usb_gadget" ]; then
	echo "rpi-cam-gadget: ${CONFIGFS}/usb_gadget missing (libcomposite/configfs?)" >&2
	exit 1
fi

# Fully tear down any previous gadget so this script is re-runnable: UVC
# descriptors (streaming_interval, frame sizes) are locked once the gadget
# is bound, so changing them means recreating the function from scratch.
# Order matters in configfs: unbind, drop config function links + strings,
# remove every function symlink, then rmdir dirs deepest-first.
teardown_gadget() {
	[ -d "${GADGET}" ] || return 0
	echo "" > "${GADGET}/UDC" 2>/dev/null || true
	# Drop config->function links first, then the config dirs deepest-first
	# (a function cannot be removed while a config still references it).
	find "${GADGET}"/configs -type l -delete 2>/dev/null || true
	find "${GADGET}"/configs -mindepth 1 -depth -type d -exec rmdir {} + 2>/dev/null || true
	# Then the function symlinks (uvc class/header links), then the dirs.
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

# Misc Device / Interface Association Descriptor so a composite
# (UVC + NCM) enumerates correctly on Windows hosts.
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

# Stable serial (and thus stable MACs) from the board serial so the host
# does not hand out a fresh DHCP lease on every reboot.
SERIAL="$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null || true)"
[ -n "${SERIAL}" ] || SERIAL="$(awk '/^Serial/ {print $3}' /proc/cpuinfo 2>/dev/null || true)"
[ -n "${SERIAL}" ] || SERIAL="0000000000000000"

mkdir -p strings/0x409
echo "meltingplot" > strings/0x409/manufacturer
echo "Pi Cam"      > strings/0x409/product
echo "${SERIAL}"   > strings/0x409/serialnumber

# Locally-administered MACs derived from the last 10 hex digits of the
# serial. Host and device get a different first octet so they never clash.
S="$(printf '%s' "${SERIAL}" | tail -c 10)"
S="$(printf '%010s' "${S}" | tr ' ' '0')"
mac_tail="${S:0:2}:${S:2:2}:${S:4:2}:${S:6:2}:${S:8:2}"
DEV_ADDR="02:${mac_tail}"
HOST_ADDR="06:${mac_tail}"

# --- CDC-NCM network function -----------------------------------------
mkdir -p functions/ncm.usb0
echo "${DEV_ADDR}"  > functions/ncm.usb0/dev_addr
echo "${HOST_ADDR}" > functions/ncm.usb0/host_addr

mkdir -p configs/c.1/strings/0x409
echo "Pi Cam (NCM+UVC)" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower
ln -sf functions/ncm.usb0 configs/c.1/

# --- UVC webcam function ----------------------------------------------
# A single MJPEG format advertising SEVERAL frame sizes; the USB host picks
# one via PROBE/COMMIT and the rpi-camera pump (uvc_gadget.py) drives picamera2
# to it. The streaming header is linked into the fs/hs/ss class trees
# (high-speed is required — the Pi enumerates at USB-2 high speed) and
# streaming_maxpacket is raised. The pump answers the control negotiation and
# feeds JPEG frames into the resulting /dev/videoN, pacing delivery itself.
if [ "${GADGET_ENABLE_UVC}" = "1" ]; then
	# Advertised frame sizes (ascending — the order IS the UVC bFrameIndex).
	# MUST match gadget_frames() in rpi-camera's uvc_gadget.py. The largest
	# frame is bounded per board to what the hardware can sensibly stream:
	#   single-core Pi Zero / Zero W -> up to 720p   (ARMv6, mem + CPU bound)
	#   Pi Zero 2 W                  -> up to 1080p
	#   everything else (Pi 4/5/...) -> up to 4608x2592 (IMX708 full sensor)
	MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
	if echo "${MODEL}" | grep -q 'Zero 2'; then
		FRAMES="640x480 1280x720 1920x1080"
	elif echo "${MODEL}" | grep -q 'Zero'; then
		FRAMES="640x480 1280x720"
	else
		FRAMES="640x480 1280x720 1920x1080 2304x1296 4608x2592"
	fi
	# High-bandwidth iso: 2048 B/microframe => 8000 * 2048 ~= 16 MB/s at
	# bInterval 1, comfortably above the ~7.5 MB/s a 1080p30 MJPEG stream
	# needs. Fixed for every frame — see streaming_interval below.
	UVC_MAXPACKET=2048

	UVC=functions/uvc.usb0
	mkdir -p "${UVC}"

	# One frame descriptor per advertised size. dwMaxVideoFrameBufferSize is a
	# 1 byte/pixel MJPEG ceiling (matches the pump's buffer sizing). Each frame
	# advertises the same interval list (100 ns units): 30/15/10/5/4/2/1 fps;
	# the pump clamps and the camera caps what it can actually deliver.
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

	# Control header links into fs/ss.
	mkdir -p "${UVC}/control/header/h"
	ln -s "${GADGET}/${UVC}/control/header/h" "${UVC}/control/class/fs/h"
	ln -s "${GADGET}/${UVC}/control/header/h" "${UVC}/control/class/ss/h"

	echo "${UVC_MAXPACKET}" > "${UVC}/streaming_maxpacket"
	# Service the iso endpoint every microframe (bInterval = 1) so the bus can
	# carry the largest advertised frame. Frame *rate* is paced in userspace by
	# frame availability (uvc_gadget.py), NOT by starving the bus, so this stays
	# fixed: at low fps the endpoint simply sends idle packets instead of the
	# gadget re-transmitting duplicate frames and burning CPU.
	echo 1 > "${UVC}/streaming_interval"

	ln -s "${GADGET}/${UVC}" configs/c.1/
	echo "rpi-cam-gadget: UVC frames [${FRAMES}], default #${default_idx}, streaming_interval=1"
fi

# Bind the composite gadget to the UDC. The UVC /dev/videoN node appears
# once this completes; rpi-camera's pump then opens it and streams.
udc="$(ls /sys/class/udc | head -n1)"
if [ -z "${udc}" ]; then
	echo "rpi-cam-gadget: no UDC available (is dwc2 in peripheral mode?)" >&2
	exit 1
fi
echo "${udc}" > UDC
echo "rpi-cam-gadget: bound gadget to UDC ${udc}"
