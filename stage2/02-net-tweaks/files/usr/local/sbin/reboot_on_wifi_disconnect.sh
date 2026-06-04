#!/bin/bash
# WiFi safety watchdog: reboot the Pi if wlan0 loses association (radio stuck,
# e.g. overheating) or the default gateway becomes unreachable for too long.
#
# Shipped DISABLED. It is enabled/disabled at runtime from the rpi-camera web
# UI via `systemctl enable/disable --now reboot_on_wifi_disconnect.service`
# (see /etc/sudoers.d/rpi-camera-wifi-watchdog). A system reboot service
# belongs in the image, not in the Python camera package.
#
# Config comes from the systemd unit's Environment= lines.
set -u

WIFI_IFACE="${WIFI_IFACE:-wlan0}"
GATEWAY="${GATEWAY:-10.42.0.1}"
PING_FAILURES_BEFORE_REBOOT="${PING_FAILURES_BEFORE_REBOOT:-30}"
INITIAL_ASSOCIATION_TIMEOUT="${INITIAL_ASSOCIATION_TIMEOUT:-120}"

# Radio still associated with an AP? Loss = chip wedged -> reboot now.
check_wlan_connected() {
	iw dev "${WIFI_IFACE}" link 2>/dev/null | grep -q "Connected"
}

# Prefer the live default route (works on DHCP networks too); fall back to the
# configured GATEWAY so an old static setup never silently breaks.
current_gateway() {
	local gw
	gw="$(ip route show default dev "${WIFI_IFACE}" 2>/dev/null | awk '/^default/ {print $3; exit}')"
	[ -n "${gw}" ] || gw="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
	[ -n "${gw}" ] || gw="${GATEWAY}"
	echo "${gw}"
}

# Slow safety net only: -W 1 bounds the ICMP wait so a 1 Hz loop stays accurate.
check_ip_reachable() {
	local gw
	gw="$(current_gateway)"
	[ -n "${gw}" ] && ping -c 1 -W 1 "${gw}" &> /dev/null
}

# Block until the first association so the monitor's immediate-reboot rule does
# not fire during the initial WiFi scan.
wait_for_initial_association() {
	local waited=0
	while ! check_wlan_connected; do
		if [ "${waited}" -ge "${INITIAL_ASSOCIATION_TIMEOUT}" ]; then
			echo "${WIFI_IFACE} failed to associate within ${INITIAL_ASSOCIATION_TIMEOUT}s. Rebooting..."
			reboot
		fi
		sleep 2
		waited=$((waited + 2))
	done
	echo "${WIFI_IFACE} associated after ${waited}s, starting monitor"
}

monitor_wifi() {
	local ping_failures=0
	while true; do
		if ! check_wlan_connected; then
			echo "${WIFI_IFACE} lost association (chip likely stuck). Rebooting..."
			reboot
		fi
		if ! check_ip_reachable; then
			ping_failures=$((ping_failures + 1))
			if [ "${ping_failures}" -ge "${PING_FAILURES_BEFORE_REBOOT}" ]; then
				echo "Gateway $(current_gateway) unreachable for ${PING_FAILURES_BEFORE_REBOOT}s. Rebooting (safety net)..."
				reboot
			fi
		else
			ping_failures=0
		fi
		sleep 1
	done
}

wait_for_initial_association
monitor_wifi
