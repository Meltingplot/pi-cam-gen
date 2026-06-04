#!/bin/bash
# Decide the USB gadget mode at boot and handle the UVC->NCM fallback.
#
#   init      Pick the boot mode and build the gadget:
#               - if the boot-partition flag file exists -> NCM straight away
#                 (drop the file from any PC to force network mode);
#               - otherwise -> UVC (the default; webcam first).
#   fallback  Run once, ~30 s after boot (rpi-cam-gadget-fallback.timer). If we
#             booted UVC but no host ever opened the video stream, switch to
#             NCM so the host can pull the MJPEG/HTTP stream over USB networking
#             instead.
#
# The composite UVC+NCM gadget does not enumerate reliably on dwc2, so the
# device only ever presents ONE function at a time (see rpi-cam-gadget-setup.sh).
set -eu

SETUP=/usr/local/sbin/rpi-cam-gadget-setup.sh
MODE_FILE=/run/rpi-cam-gadget.mode
# The rpi-camera pump logs this line on UVC_EVENT_STREAMON; we grep the journal
# for it to tell whether a host actually opened the video stream.
UVC_STREAM_LOG='USB host UVC stream started'

# Pi OS mounts the boot partition at /boot/firmware (older images: /boot).
BOOT_FW=/boot/firmware
[ -d "${BOOT_FW}" ] || BOOT_FW=/boot
NCM_FLAG="${BOOT_FW}/ncm-mode"

log() { echo "rpi-cam-gadget-mode: $*"; }

cmd="${1:-init}"
case "${cmd}" in
init)
	if [ -f "${NCM_FLAG}" ]; then
		log "boot flag ${NCM_FLAG} present -> starting in NCM mode"
		mode=ncm
	else
		mode=uvc
	fi
	# dwc2 sizes its RX FIFO from the FIRST gadget bound after a cold boot and
	# keeps it across rebinds. A UVC-first bind computes an RX FIFO larger than
	# the controller's SPRAM (regardless of maxpacket), which leaves ep0's TX
	# FIFO out of bounds -> ep0 can't answer enumeration -> the host drops to
	# full-speed and fails. NCM computes a small RX that fits. So for UVC, bind
	# NCM once to prime dwc2's FIFO, then rebuild as UVC (which inherits the
	# small FIFO and enumerates high-speed). Set GADGET_PRIME=0 to skip.
	if [ "${mode}" = uvc ] && [ "${GADGET_PRIME:-1}" = 1 ]; then
		log "priming dwc2 RX FIFO via NCM before UVC"
		"${SETUP}" ncm || log "warn: NCM prime failed; continuing to UVC anyway"
	fi
	"${SETUP}" "${mode}"
	echo "${mode}" > "${MODE_FILE}"
	;;

fallback)
	# Only relevant if we booted UVC and it is still UVC.
	[ "$(cat "${MODE_FILE}" 2>/dev/null || true)" = uvc ] || exit 0
	# Did a host open the UVC stream since boot? The pump logs it if so.
	if journalctl -b -u rpi-camera.service --no-pager 2>/dev/null | grep -q "${UVC_STREAM_LOG}"; then
		log "UVC stream was opened; staying in UVC mode"
		exit 0
	fi
	log "no UVC stream within grace period; switching to NCM"
	# Release /dev/videoN before tearing the UVC function down, then re-run the
	# pump so it comes up in NCM (HTTP-only) mode.
	systemctl stop rpi-camera.service 2>/dev/null || true
	"${SETUP}" ncm
	echo ncm > "${MODE_FILE}"
	systemctl start rpi-camera.service 2>/dev/null || true
	;;

*)
	echo "usage: $0 [init|fallback]" >&2
	exit 2
	;;
esac
