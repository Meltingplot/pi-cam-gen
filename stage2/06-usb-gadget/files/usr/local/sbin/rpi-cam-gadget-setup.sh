#!/bin/bash
# Build the composite USB gadget via configfs/libcomposite: a UVC webcam AND a
# CDC-NCM network device, in one configuration, presented together.
#
# History: this used to present ONE function at a time because the composite
# gadget "wouldn't enumerate reliably on dwc2" (it came up full-speed with a
# dead ep0). That was a misdiagnosis — the real cause was the userspace pump
# opening the wrong V4L2 node, so the UVC endpoint was never configured and
# dwc2 kept an oversized RX FIFO that overflowed the SPRAM -> full-speed. With
# the pump on the right node, the composite enumerates high-speed with both
# functions (NCM is linked first so its small bulk-OUT FIFO sizes the RX FIFO
# before the UVC iso-IN endpoint).
#
# Usage: rpi-cam-gadget-setup.sh
# Re-runnable: it fully tears down any existing gadget first.
set -eu

GADGET=/sys/kernel/config/usb_gadget/picam
CONFIGFS=/sys/kernel/config

modprobe libcomposite

# configfs must be mounted (systemd mounts sys-kernel-config.mount); bail
# loudly rather than silently producing a half-built gadget.
if [ ! -d "${CONFIGFS}/usb_gadget" ]; then
	echo "rpi-cam-gadget: ${CONFIGFS}/usb_gadget missing (libcomposite/configfs?)" >&2
	exit 1
fi

# Tear down any previous gadget so this script is re-runnable (and can switch
# modes at runtime). Order matters in configfs: unbind the UDC, drop the
# config->function links + config dirs deepest-first, then the function
# symlinks + dirs, then strings.
#
# Only disturb the UDC if a gadget is ACTUALLY bound: unbinding pulls the USB
# pullup and resets dwc2, and rebinding too soon after can catch the controller
# mid-reset and leave the high-speed PHY wedged (the host then sees a
# full-speed device). So skip the unbind on a fresh boot (nothing bound), and
# when we do unbind, wait for dwc2 to settle before rebuilding.
GADGET_SETTLE_SEC="${GADGET_SETTLE_SEC:-1}"
teardown_gadget() {
	[ -d "${GADGET}" ] || return 0
	if [ -n "$(cat "${GADGET}/UDC" 2>/dev/null | tr -d '[:space:]' || true)" ]; then
		echo "rpi-cam-gadget: unbinding existing gadget, settling ${GADGET_SETTLE_SEC}s"
		echo "" > "${GADGET}/UDC" 2>/dev/null || true
		sleep "${GADGET_SETTLE_SEC}"
	fi
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

# WICHTIG fuer UVC als Composite: Miscellaneous Device + IAD,
# sonst gruppiert v.a. Windows die VideoControl/VideoStreaming-Interfaces nicht.
echo 0xEF > bDeviceClass      # Miscellaneous
echo 0x02 > bDeviceSubClass   # Common Class
echo 0x01 > bDeviceProtocol   # Interface Association Descriptor

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
echo "Pi Cam" > configs/c.1/strings/0x409/configuration
echo 0x80 > configs/c.1/bmAttributes   # 0x80 bus-powered, 0xC0 self-powered
echo 500  > configs/c.1/MaxPower       # mA


# --- CDC-NCM network function -----------------------------------------
build_ncm() {
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
	#   single-core Pi Zero / Zero W -> up to 720p   (1080p too slow over USB UVC)
	#   Pi Zero 2 W                  -> up to 2304x1296 (IMX708 binned, ~3MP)
	#   everything else (Pi 4/5/...) -> up to 4608x2592 (IMX708 full sensor)
	#
	# Iso endpoint wMaxPacketSize. 2048 (high-bandwidth iso, 2 transactions per
	# microframe) is what the host actually negotiates and is verified working
	# on the Pi Zero 2 W; the earlier "dwc2 can't do high-bandwidth iso, keep
	# <=1024" claim was a misdiagnosis (the real cause of the bad behaviour was
	# the pump opening the wrong V4L2 node, not the packet size). Default 2048;
	# each board tier may override below.
	UVC_MAXPACKET=2048

	UVC=functions/uvc.usb0
	mkdir -p "${UVC}"

	# Optional bulk streaming endpoint (GADGET_UVC_TRANSFER=bulk) instead of the
	# default isochronous. Bulk takes a different f_uvc code path with no
	# periodic-bandwidth machinery; on the Zero 2 W the isoc UVC gadget is
	# forced to full-speed by dwc2/f_uvc (NCM and bulk have no isoc endpoint),
	# so this is the lever to test whether the isoc endpoint is the cause.
	# Must be set before the function is linked into the config; guarded so a
	# kernel without the attribute still builds (isoc).
	if [ "${GADGET_UVC_TRANSFER:-isoc}" = "bulk" ]; then
		if [ -e "${UVC}/streaming_transfer" ]; then
			echo bulk > "${UVC}/streaming_transfer" \
				&& echo "rpi-cam-gadget: UVC streaming_transfer=bulk"
		else
			echo "rpi-cam-gadget: warn: kernel has no streaming_transfer; staying isoc" >&2
		fi
	fi

	# create_frame WIDTH HEIGHT FORMAT FPS [FPS...]
	#
	# Adds one frame descriptor to the named streaming format instance
	# (e.g. "mjpeg"). The frame is advertised for every FPS given; the first
	# FPS is the default rate. dwMaxVideoFrameBufferSize / dw{Max,Min}BitRate
	# assume a 1 byte/pixel MJPEG ceiling (matches the pump's buffer sizing).
	# Frames are numbered in call order so bFrameIndex follows creation order;
	# 1280x720 (where present) is recorded as the gadget's default frame.
	idx=0
	idx_720=
	idx_1080=
	FRAMES=
	create_frame() {
		w="$1"; h="$2"; fmt="$3"; shift 3
		idx=$(( idx + 1 ))
		FRAMES="${FRAMES:+${FRAMES} }${w}x${h}"

		# Zero-padded name so the lexical order matches bFrameIndex order.
		frm="$(printf '%s/streaming/%s/m/%04dx%04d' "${UVC}" "${fmt}" "${w}" "${h}")"
		mkdir -p "${frm}"
		echo "${w}" > "${frm}/wWidth"
		echo "${h}" > "${frm}/wHeight"
		echo "$(( w * h * 2 ))" > "${frm}/dwMaxVideoFrameBufferSize"

		# Frame intervals in 100 ns units; track the fps span for the bitrates.
		max_fps="$1"; min_fps="$1"; intervals=
		for fps in "$@"; do
			[ "${fps}" -gt "${max_fps}" ] && max_fps="${fps}"
			[ "${fps}" -lt "${min_fps}" ] && min_fps="${fps}"
			intervals="${intervals} $(( 10000000 / fps ))"
		done
		echo "$(( w * h * 2 * 8 * max_fps / 10 ))" > "${frm}/dwMaxBitRate"   # bit/s
		echo "$(( w * h * 2 * 8 * min_fps / 10 ))" > "${frm}/dwMinBitRate"   # bit/s
		echo "$(( 10000000 / $1 ))" > "${frm}/dwDefaultFrameInterval"
		# Write ALL intervals in a SINGLE write(2). configfs replaces the
		# dwFrameInterval list on every write, and bash's `printf '%s\n' a b c`
		# emits one write PER argument — so it would keep only the last (the
		# slowest rate, e.g. 5 fps). A heredoc/cat hands the whole
		# newline-separated list to one write (the known-good configfs-gadget
		# idiom). NB: <<- strips leading TABS only, so this block must stay
		# tab-indented.
		cat > "${frm}/dwFrameInterval" <<-EOF
			$(printf '%s\n' ${intervals})
		EOF

		# Remember the 720p / 1080p frame indices; the default frame is chosen
		# from them after all frames exist (see below). NB: use `if`, never a
		# bare `[ ... ] && ...` as the function's LAST command — under `set -e`
		# a false test there aborts the whole script (an `if` returns 0).
		if [ "${w}x${h}" = "1280x720" ]; then
			idx_720="${idx}"
		fi
		if [ "${w}x${h}" = "1920x1080" ]; then
			idx_1080="${idx}"
		fi
	}

	# UVC_INTERVAL is the iso endpoint bInterval: it is serviced every
	# 2^(bInterval-1) microframes, so it costs ~8000/2^(bInterval-1)
	# interrupts/sec. bInterval=1 (every microframe, 8000 int/s) buries the
	# single-core ARMv6 Pi Zero in softirqs even at idle; raise it there.
	#
	# The largest frame is bounded per board to what the hardware can stream:
	#   single-core Pi Zero / Zero W -> up to 720p   (1080p too slow over USB UVC)
	#   Pi Zero 2 W                  -> up to 2304x1296 (IMX708 binned, ~3MP)
	#   everything else (Pi 4/5/...) -> up to 4608x2592 (IMX708 full sensor)
	MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
	if echo "${MODEL}" | grep -q 'Zero 2'; then
		UVC_INTERVAL=1
		UVC_MAXPACKET=2048   # HB-iso; verified on Zero 2 W (see note above)
		create_frame  640  480 mjpeg 30 24 20 15 10 5
		create_frame 1280  720 mjpeg 30 24 20 15 10 5
		create_frame 1920 1080 mjpeg 24 20 15 10 5
		create_frame 2304 1296 mjpeg 20 15 10 5   # IMX708 binned full-FoV (~3MP)
	elif echo "${MODEL}" | grep -q 'Zero'; then
		# Single-core ARMv6 Zero / Zero W. 1080p over USB UVC is too slow on
		# one core, so the gadget advertises up to 720p only; 30 fps pins the
		# core even at 640x480, so cap the rate at 20. NOTE: this limits only
		# the USB webcam — the HTTP/web stream is NOT constrained by this list
		# and can still serve 1080p.
		UVC_INTERVAL=2
		UVC_MAXPACKET=2048
		create_frame  640  480 mjpeg 20 15 10 5
		create_frame 1280  720 mjpeg 20 15 10 5
	else
		UVC_INTERVAL=1
		UVC_MAXPACKET=2048   # HB-iso; verified on Zero 2 W (see note above)
		create_frame  640  480 mjpeg 30 24 20 15 10 5
		create_frame 1280  720 mjpeg 30 24 20 15 10 5
		create_frame 1920 1080 mjpeg 30 24 20 15 10 5
		create_frame 2304 1296 mjpeg 30 24 20 15 10 5
		create_frame 4608 2592 mjpeg 10 5
	fi

	# Default frame = 1080p where advertised, else 720p, else the first frame.
	# This matches the camera's per-board boot resolution (rpi-camera
	# server._default_resolution: 1080p on multi-core boards, 720p on the
	# single-core Zero/Zero W), so a host that opens the stream at the gadget's
	# default frame does NOT trigger a capture-pipeline resize (a brief frame
	# stall + iso underruns). Keep in sync with _default_frame_index() there.
	default_idx="${idx_1080:-${idx_720:-1}}"
	echo "${default_idx}" > "${UVC}/streaming/mjpeg/m/bDefaultFrameIndex"

	# Streaming header links the MJPEG format instance, then fs/hs/ss.
	mkdir -p "${UVC}/streaming/header/h"
	ln -s "${GADGET}/${UVC}/streaming/mjpeg/m" "${UVC}/streaming/header/h/m"
	ln -s "${GADGET}/${UVC}/streaming/header/h" "${UVC}/streaming/class/fs/h"
	ln -s "${GADGET}/${UVC}/streaming/header/h" "${UVC}/streaming/class/hs/h"
	ln -s "${GADGET}/${UVC}/streaming/header/h" "${UVC}/streaming/class/ss/h"

	# Control header links into fs/ss (the kernel exposes no hs dir for control).
	mkdir -p "${UVC}/control/header/h"
	# VideoControl clock the payload-header timestamps reference. Set it
	# explicitly so it is deterministic and matches the dwClockFrequency the
	# rpi-camera pump reports in PROBE/COMMIT (uvc_gadget.py reads this back).
	# Guarded: an older kernel without the attribute still brings the gadget up.
	[ -e "${UVC}/control/header/h/dwClockFrequency" ] && { echo 48000000 > "${UVC}/control/header/h/dwClockFrequency" 2>/dev/null \
		|| echo "rpi-cam-gadget: warn: could not set dwClockFrequency" >&2; }
	ln -s "${GADGET}/${UVC}/control/header/h" "${UVC}/control/class/fs/h"
	ln -s "${GADGET}/${UVC}/control/header/h" "${UVC}/control/class/ss/h"

	# Advertise the camera controls the rpi-camera pump maps to libcamera.
	# Best-effort: the Pi's downstream f_uvc keeps these default-entity
	# bmControls READ-ONLY (the write returns EIO), so on the Pi the gadget
	# falls back to the kernel defaults (PU=Brightness, CT=Auto-Exposure-Mode)
	# — both of which the pump's UvcControlBridge services, so nothing stalls.
	# The widths MUST match the kernel arrays: PU is 2 bytes, CT is 3.
	pu_bm="${UVC}/control/processing/default/bmControls"
	ct_bm="${UVC}/control/terminal/camera/default/bmControls"
	[ -e "${pu_bm}" ] && { echo 0x1b 0x12 > "${pu_bm}" 2>/dev/null \
		|| echo "rpi-cam-gadget: warn: PU bmControls read-only; using kernel defaults" >&2; }
	[ -e "${ct_bm}" ] && { echo 0x2a 0x00 0x02 > "${ct_bm}" 2>/dev/null \
		|| echo "rpi-cam-gadget: warn: CT bmControls read-only; using kernel defaults" >&2; }

	echo "${UVC_MAXPACKET}" > "${UVC}/streaming_maxpacket"
	echo "${UVC_INTERVAL}"  > "${UVC}/streaming_interval"

	ln -s "${GADGET}/${UVC}" configs/c.1/
	echo "rpi-cam-gadget: built UVC gadget, frames [${FRAMES}], default #${default_idx}, streaming_interval=${UVC_INTERVAL}"
}

# Link NCM first so it claims interfaces 0-1 (and its small bulk-OUT FIFO sizes
# the dwc2 RX FIFO before the UVC iso-IN endpoint); UVC takes interfaces 2-3.
build_ncm
build_uvc

# Bind the gadget to the UDC. The /dev/videoN (UVC) and usb0 (NCM) nodes appear
# once this completes.
udc="$(ls /sys/class/udc | head -n1)"
if [ -z "${udc}" ]; then
	echo "rpi-cam-gadget: no UDC available (is dwc2 in peripheral mode?)" >&2
	exit 1
fi
echo "${udc}" > UDC
echo "rpi-cam-gadget: bound composite (UVC+NCM) gadget to UDC ${udc}"
