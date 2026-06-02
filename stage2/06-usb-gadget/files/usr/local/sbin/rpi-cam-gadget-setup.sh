#!/bin/bash
# Build the USB composite gadget (CDC-NCM network + optional UVC webcam)
# via configfs/libcomposite. Runs once at boot from rpi-cam-gadget.service,
# only on OTG-capable boards (gated by /run/rpi-cam-gadget.enabled).
#
# Phase status:
#   - CDC-NCM is always created so USB networking comes up at boot.
#   - The UVC function (GADGET_ENABLE_UVC=1, default on) advertises a
#     single MJPEG format at the board resolution. This script writes the
#     descriptors and binds the UDC; the rpi-camera Python pump
#     (uvc_gadget.py) then answers PROBE/COMMIT and feeds frames into the
#     resulting /dev/videoN. Dynamic resolution/fps reconfig is not wired
#     yet (fixed resolution per board). See NOTES.md.
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

# Idempotent: if a previous run left the gadget, tear it down first.
if [ -d "${GADGET}" ]; then
	echo "" > "${GADGET}/UDC" 2>/dev/null || true
fi

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
# configfs layout follows a known-good UVC gadget setup: a single MJPEG
# format/frame at the board's default resolution, the streaming header
# linked into the fs/hs/ss class trees (high-speed is required — the Pi
# enumerates at USB-2 high speed), and streaming_maxpacket raised. The
# rpi-camera Python pump (uvc_gadget.py) answers PROBE/COMMIT and feeds
# JPEG frames into the resulting /dev/videoN.
if [ "${GADGET_ENABLE_UVC}" = "1" ]; then
	# Board-dependent default resolution, matching server.py's choice:
	# the single-core Pi Zero / Zero W gets 720p, everything else 1080p.
	MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
	if echo "${MODEL}" | grep -q 'Zero' && ! echo "${MODEL}" | grep -q 'Zero 2'; then
		UVC_W=1280; UVC_H=720
	else
		UVC_W=1920; UVC_H=1080
	fi
	UVC_INTERVAL=1000000   # 10 fps, in 100 ns units (matches capture default)

	UVC=functions/uvc.usb0
	mkdir -p "${UVC}"

	# Single MJPEG frame at the board resolution.
	frm="${UVC}/streaming/mjpeg/m/${UVC_H}p"
	mkdir -p "${frm}"
	echo "${UVC_W}" > "${frm}/wWidth"
	echo "${UVC_H}" > "${frm}/wHeight"
	echo "$(( UVC_W * UVC_H * 2 ))" > "${frm}/dwMaxVideoFrameBufferSize"
	echo "${UVC_INTERVAL}" > "${frm}/dwDefaultFrameInterval"
	printf '%s\n' "${UVC_INTERVAL}" > "${frm}/dwFrameInterval"

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

	echo 2048 > "${UVC}/streaming_maxpacket"

	ln -s "${GADGET}/${UVC}" configs/c.1/
	echo "rpi-cam-gadget: UVC function ${UVC_W}x${UVC_H} MJPEG created"
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
