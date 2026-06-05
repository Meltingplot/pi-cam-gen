#!/bin/bash
# In-place software update, triggered from the rpi-camera web UI ("Update"
# button -> POST /api/update -> systemd-run -> this script, as root in its own
# transient unit so it survives the rpi-camera restart it performs).
#
# STABLE channel only:
#   * meltingplot.rpi_camera (Repo B) is pip-upgraded from PyPI WITHOUT --pre,
#     so it only moves to a non-pre-release; while the project ships rc's this
#     is a no-op (intended — deployed devices update to vetted releases only).
#   * the gadget script + its frame config (Repo A) are refreshed from the
#     latest non-prerelease pi-cam-gen GitHub release.
#   * the WiFi safety watchdog (script, config helper, unit, sudoers) is
#     refreshed from the same release, so devices flashed before it existed
#     pick it up via the Update button (it stays enabled/disabled as it was).
# Then the gadget is rebuilt and the camera service restarted.
#
# Logs to the journal: journalctl -u rpi-cam-update
set -u

REPO_A="Meltingplot/pi-cam-gen"
VENV="/opt/meltingplot/rpi_camera/venv"

log() { echo "rpi-cam-update: $*"; }

# --- 1. Upgrade rpi-camera (Repo B) from PyPI, stable only -------------------
svc_user="$(systemctl show -p User --value rpi-camera.service 2>/dev/null || true)"
[ -n "${svc_user}" ] || svc_user="pi"
if [ -x "${VENV}/bin/pip" ]; then
	log "pip: upgrading meltingplot.rpi_camera from PyPI (stable)"
	runuser -u "${svc_user}" -- "${VENV}/bin/pip" install --upgrade meltingplot.rpi_camera \
		|| log "pip upgrade failed or no stable release available; continuing"
else
	log "venv pip not found at ${VENV}/bin/pip; skipping package upgrade"
fi

# --- 2. Refresh the gadget files (Repo A) from the latest stable release -----
tag="$(curl -fsSL "https://api.github.com/repos/${REPO_A}/releases/latest" 2>/dev/null \
	| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ -n "${tag}" ]; then
	raw="https://raw.githubusercontent.com/${REPO_A}/${tag}/stage2/06-usb-gadget/files"
	log "refreshing gadget files from ${REPO_A} ${tag}"
	tmp="$(mktemp -d)"
	if curl -fsSL "${raw}/usr/local/sbin/rpi-cam-gadget-setup.sh" -o "${tmp}/setup.sh" \
		&& curl -fsSL "${raw}/etc/rpi-camera/frames.conf" -o "${tmp}/frames.conf" \
		&& bash -n "${tmp}/setup.sh"; then
		install -m 755 "${tmp}/setup.sh"   /usr/local/sbin/rpi-cam-gadget-setup.sh
		install -d -m 755 /etc/rpi-camera
		install -m 644 "${tmp}/frames.conf" /etc/rpi-camera/frames.conf
		log "gadget files updated"
	else
		log "gadget file download/validation failed; keeping current files"
	fi
	rm -rf "${tmp}"
else
	log "no stable pi-cam-gen release found; skipping gadget refresh"
fi

# --- 3. Refresh the WiFi safety watchdog (Repo A) ----------------------------
# The watchdog (a system reboot service) ships with the image, not the pip
# package, so an old device never gets it from the package upgrade above. Pull
# the current files from the release and validate each before installing so a
# bad download can never break sudo or systemd on the device.
if [ -n "${tag}" ]; then
	wdsrc="https://raw.githubusercontent.com/${REPO_A}/${tag}/stage2/02-net-tweaks/files"
	log "refreshing WiFi watchdog from ${REPO_A} ${tag}"
	tmp="$(mktemp -d)"
	if curl -fsSL "${wdsrc}/usr/local/sbin/reboot_on_wifi_disconnect.sh"   -o "${tmp}/watchdog.sh" \
		&& curl -fsSL "${wdsrc}/usr/local/sbin/rpi-cam-wifi-watchdog-config.sh" -o "${tmp}/config.sh" \
		&& curl -fsSL "${wdsrc}/etc/systemd/system/reboot_on_wifi_disconnect.service" -o "${tmp}/watchdog.service" \
		&& curl -fsSL "${wdsrc}/etc/sudoers.d/rpi-camera-wifi-watchdog" -o "${tmp}/sudoers.in" \
		&& bash -n "${tmp}/watchdog.sh" \
		&& bash -n "${tmp}/config.sh" \
		&& sed "s/FIRST_USER_NAME/${svc_user}/g" "${tmp}/sudoers.in" > "${tmp}/sudoers" \
		&& visudo -cf "${tmp}/sudoers" >/dev/null; then
		install -m 755 "${tmp}/watchdog.sh"      /usr/local/sbin/reboot_on_wifi_disconnect.sh
		install -m 755 "${tmp}/config.sh"        /usr/local/sbin/rpi-cam-wifi-watchdog-config.sh
		install -m 644 "${tmp}/watchdog.service" /etc/systemd/system/reboot_on_wifi_disconnect.service
		install -m 0440 "${tmp}/sudoers"         /etc/sudoers.d/rpi-camera-wifi-watchdog
		systemctl daemon-reload
		# Apply the refreshed script if running; preserve enabled/disabled state.
		if systemctl is-active --quiet reboot_on_wifi_disconnect.service; then
			systemctl restart reboot_on_wifi_disconnect.service || true
		fi
		log "WiFi watchdog files updated"
	else
		log "watchdog download/validation failed; keeping current files"
	fi
	rm -rf "${tmp}"
fi

# --- 4. Rebuild the gadget + restart the camera ------------------------------
log "rebuilding gadget and restarting rpi-camera"
systemctl stop rpi-camera.service 2>/dev/null || true
/usr/local/sbin/rpi-cam-gadget-setup.sh || log "gadget rebuild reported an error"
systemctl start rpi-camera.service
log "update complete"
