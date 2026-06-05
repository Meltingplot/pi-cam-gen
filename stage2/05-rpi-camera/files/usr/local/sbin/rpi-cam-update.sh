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

# --- 3. Rebuild the gadget + restart the camera ------------------------------
log "rebuilding gadget and restarting rpi-camera"
systemctl stop rpi-camera.service 2>/dev/null || true
/usr/local/sbin/rpi-cam-gadget-setup.sh || log "gadget rebuild reported an error"
systemctl start rpi-camera.service
log "update complete"
