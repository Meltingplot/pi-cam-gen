#!/bin/bash
# Write the WiFi safety watchdog's runtime config from the rpi-camera web UI.
#
# Invoked as root via a pinned sudoers entry (see
# /etc/sudoers.d/rpi-camera-wifi-watchdog). It only ever writes the single
# EnvironmentFile the watchdog unit reads and, if the watchdog is active,
# restarts it so the new value takes effect immediately.
#
#   rpi-cam-wifi-watchdog-config.sh set-ping-target <ipv4|ipv6|"">
#
# An empty target clears the override (the watchdog goes back to auto-detecting
# the live default route). Arguments are validated here, NOT eval'd, so the
# sudoers wildcard cannot be turned into a shell.
set -euo pipefail

CONF="/etc/rpi-camera/wifi-watchdog.conf"
UNIT="reboot_on_wifi_disconnect.service"

usage() {
	echo "usage: ${0##*/} set-ping-target <ip|empty>" >&2
	exit 2
}

# Accept an empty string (clear) or a syntactically valid IPv4/IPv6 literal.
# Hostnames are intentionally rejected: the watchdog pings this every second as
# a safety net, so it must not depend on DNS.
valid_ip() {
	local ip="$1"
	python3 - "$ip" <<-'PY'
		import ipaddress, sys
		try:
		    ipaddress.ip_address(sys.argv[1])
		except ValueError:
		    sys.exit(1)
	PY
}

write_conf() {
	local key="$1" val="$2" tmp
	install -d -m 755 "$(dirname "${CONF}")"
	tmp="$(mktemp "${CONF}.XXXXXX")"
	# 0644: the unit (root) reads it; the camera user reads it back for the UI.
	chmod 644 "${tmp}"
	if [ -n "${val}" ]; then
		printf '%s=%s\n' "${key}" "${val}" > "${tmp}"
	else
		: > "${tmp}"   # empty file == no override
	fi
	mv -f "${tmp}" "${CONF}"
}

apply_live() {
	# Only restart if the watchdog is currently running; never start it here
	# (enabling/disabling stays the job of the separate toggle).
	if systemctl is-active --quiet "${UNIT}"; then
		systemctl restart "${UNIT}"
	fi
}

case "${1:-}" in
	set-ping-target)
		[ "$#" -eq 2 ] || usage
		target="$2"
		if [ -n "${target}" ] && ! valid_ip "${target}"; then
			echo "invalid ping target: ${target}" >&2
			exit 1
		fi
		write_conf "PING_TARGET" "${target}"
		apply_live
		;;
	*)
		usage
		;;
esac
