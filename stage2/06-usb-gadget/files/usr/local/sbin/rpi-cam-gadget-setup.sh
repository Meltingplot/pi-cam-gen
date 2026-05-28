#!/bin/bash
# Build the USB composite gadget (CDC-NCM network + optional UVC webcam)
# via configfs/libcomposite. Runs once at boot from rpi-cam-gadget.service,
# only on OTG-capable boards (gated by /run/rpi-cam-gadget.enabled).
#
# Phase status:
#   - CDC-NCM is always created and the UDC is bound here, so USB
#     networking comes up at boot with no userspace help.
#   - The UVC function is created only when GADGET_ENABLE_UVC=1 (default
#     off). Until the rpi-camera UVC pump (repo B) is in place there is
#     nothing to feed the gadget, so it stays off and this script binds
#     the UDC itself. Once the pump lands, flip the default on, stop
#     binding the UDC here, and let rpi-camera bind after it has written
#     the real streaming descriptors. See NOTES.md.
set -eu

GADGET_ENABLE_UVC="${GADGET_ENABLE_UVC:-0}"

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

# --- UVC webcam function (optional; placeholder descriptors) ----------
if [ "${GADGET_ENABLE_UVC}" = "1" ]; then
	UVC=functions/uvc.usb0
	mkdir -p "${UVC}"

	# Control interface header.
	mkdir -p "${UVC}/control/header/h"
	ln -sf "${UVC}/control/header/h" "${UVC}/control/class/fs/h"
	ln -sf "${UVC}/control/header/h" "${UVC}/control/class/ss/h"

	# Placeholder MJPEG format, single 640x480 @ 5 fps frame. The real
	# resolution/fps descriptors are rewritten by the rpi-camera pump
	# before it binds the UDC.
	fmt="${UVC}/streaming/mjpeg/m"
	frm="${fmt}/640x480"
	mkdir -p "${frm}"
	echo 640 > "${frm}/wWidth"
	echo 480 > "${frm}/wHeight"
	echo 2000000   > "${frm}/dwMinBitRate"
	echo 30000000  > "${frm}/dwMaxBitRate"
	echo 460800    > "${frm}/dwMaxVideoFrameBufferSize"
	echo 2000000   > "${frm}/dwDefaultFrameInterval"   # 5 fps (units of 100ns)
	echo 2000000   > "${frm}/dwFrameInterval"

	mkdir -p "${UVC}/streaming/header/h"
	ln -sf "${UVC}/streaming/mjpeg"     "${UVC}/streaming/header/h/mjpeg"
	ln -sf "${UVC}/streaming/header/h"  "${UVC}/streaming/class/fs/h"
	ln -sf "${UVC}/streaming/header/h"  "${UVC}/streaming/class/hs/h"

	ln -sf "functions/uvc.usb0" configs/c.1/

	# Hand the streaming descriptor subtree to the rpi-camera service
	# user so the (unprivileged) pump can rewrite resolution/fps later.
	# The UDC bind itself still needs root (rpi-cam-gadget-rebind.sh).
	chgrp -R "${RPI_CAM_USER:-pi}" "${UVC}/streaming" 2>/dev/null || true
	chmod -R g+w "${UVC}/streaming" 2>/dev/null || true
fi

# Bind to the first available UDC. With UVC off this is what brings the
# NCM link up at boot. With UVC on (once the pump exists) this binding
# moves into rpi-camera and should be removed from here.
if [ "${GADGET_ENABLE_UVC}" != "1" ]; then
	udc="$(ls /sys/class/udc | head -n1)"
	if [ -z "${udc}" ]; then
		echo "rpi-cam-gadget: no UDC available (is dwc2 in peripheral mode?)" >&2
		exit 1
	fi
	echo "${udc}" > UDC
	echo "rpi-cam-gadget: bound gadget to UDC ${udc}"
fi
