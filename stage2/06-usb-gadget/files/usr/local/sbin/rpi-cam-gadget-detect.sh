#!/bin/sh
# Decide whether USB-gadget mode is supported on this board and leave a
# flag file the gadget-setup service (and rpi-camera) can condition on.
#
# Supported (dedicated OTG / peripheral port):
#   Pi Zero / Zero W (BCM2835, micro-USB)
#   Pi Zero 2 W      (BCM2710A1, micro-USB)
#   Pi 4 Model B     (BCM2711, USB-C)
#   Pi 5             (BCM2712; relevant on the future 64-bit image)
# NOT supported (USB is host-only via an on-board hub):
#   Pi 2, Pi 3, Pi 3+, Compute Modules on carrier boards.
set -eu

MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"

rm -f /run/rpi-cam-gadget.enabled /run/rpi-cam-gadget.disabled

case "${MODEL}" in
	*"Zero 2"*|*"Zero"*|*"Pi 4"*|*"Pi 5"*)
		echo "${MODEL}" > /run/rpi-cam-gadget.enabled
		echo "rpi-cam-gadget: OTG-capable board detected: ${MODEL}"
		;;
	*)
		echo "${MODEL}" > /run/rpi-cam-gadget.disabled
		echo "rpi-cam-gadget: board has no OTG port, skipping gadget: ${MODEL}"
		;;
esac
