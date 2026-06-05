#!/bin/bash -e

# Install the WiFi safety watchdog (reboot on lost wlan0 association / gateway
# unreachable). A system reboot service belongs in the image, not in the Python
# camera package — so it lives here, NOT in `rpi-camera install`.
#
# Shipped DISABLED: the unit file is laid down but never enabled (no wants/
# symlink). The rpi-camera web UI turns it on/off at runtime via
# `systemctl enable/disable --now` (the sudoers entry below grants exactly that).

install -m 755 files/usr/local/sbin/reboot_on_wifi_disconnect.sh \
	"${ROOTFS_DIR}/usr/local/sbin/reboot_on_wifi_disconnect.sh"
# Helper the web UI calls (via sudo) to set the watchdog's ping target.
install -m 755 files/usr/local/sbin/rpi-cam-wifi-watchdog-config.sh \
	"${ROOTFS_DIR}/usr/local/sbin/rpi-cam-wifi-watchdog-config.sh"
install -m 644 files/etc/systemd/system/reboot_on_wifi_disconnect.service \
	"${ROOTFS_DIR}/etc/systemd/system/reboot_on_wifi_disconnect.service"

# sudoers: substitute the real first-user name, then install 0440 root:root.
install -m 0440 files/etc/sudoers.d/rpi-camera-wifi-watchdog \
	"${ROOTFS_DIR}/etc/sudoers.d/rpi-camera-wifi-watchdog"
sed -i "s/FIRST_USER_NAME/${FIRST_USER_NAME}/g" "${ROOTFS_DIR}/etc/sudoers.d/rpi-camera-wifi-watchdog"

# Validate the sudoers file inside the chroot so a typo fails the build instead
# of silently disabling sudo on the device. Intentionally NOT enabled here.
on_chroot << 'EOF'
visudo -cf /etc/sudoers.d/rpi-camera-wifi-watchdog
EOF
