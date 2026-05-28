#!/bin/bash
# Privileged helper: bind or unbind the picam USB gadget's UDC.
#
# The rpi-camera service runs unprivileged but needs to trigger a USB
# re-enumeration when it rewrites the UVC streaming descriptors (e.g. on
# a resolution change). Writing the UDC node requires root, so this thin,
# argument-whitelisted wrapper is the only thing granted via sudoers
# (see /etc/sudoers.d/rpi-camera-gadget). Keep it minimal to avoid
# turning it into a general-purpose root primitive.
set -eu

GADGET=/sys/kernel/config/usb_gadget/picam

case "${1:-}" in
	bind)
		udc="$(ls /sys/class/udc | head -n1)"
		[ -n "${udc}" ] || { echo "no UDC available" >&2; exit 1; }
		echo "${udc}" > "${GADGET}/UDC"
		;;
	unbind)
		echo "" > "${GADGET}/UDC"
		;;
	*)
		echo "usage: $0 {bind|unbind}" >&2
		exit 2
		;;
esac
