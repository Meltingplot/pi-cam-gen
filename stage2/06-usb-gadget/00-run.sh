#!/bin/bash -e

# Install the USB composite gadget tree (scripts, systemd units, the
# NetworkManager usb0 profile and the locked-down sudoers entry) and
# enable the two oneshot units. Activation is gated at runtime by
# rpi-cam-gadget-detect.sh, so this is a no-op on non-OTG boards.

install -m 755 files/usr/local/sbin/rpi-cam-gadget-detect.sh "${ROOTFS_DIR}/usr/local/sbin/"
install -m 755 files/usr/local/sbin/rpi-cam-gadget-setup.sh  "${ROOTFS_DIR}/usr/local/sbin/"
install -m 750 files/usr/local/sbin/rpi-cam-gadget-rebind.sh "${ROOTFS_DIR}/usr/local/sbin/"

install -m 644 files/etc/systemd/system/rpi-cam-gadget-detect.service "${ROOTFS_DIR}/etc/systemd/system/"
install -m 644 files/etc/systemd/system/rpi-cam-gadget.service        "${ROOTFS_DIR}/etc/systemd/system/"

install -d -m 700 "${ROOTFS_DIR}/etc/NetworkManager/system-connections"
install -m 600 files/etc/NetworkManager/system-connections/usb0-host.nmconnection \
	"${ROOTFS_DIR}/etc/NetworkManager/system-connections/"

# sudoers: substitute the real first-user name, then install 0440 root:root.
install -m 0440 files/etc/sudoers.d/rpi-camera-gadget "${ROOTFS_DIR}/etc/sudoers.d/rpi-camera-gadget"
sed -i "s/FIRST_USER_NAME/${FIRST_USER_NAME}/g" "${ROOTFS_DIR}/etc/sudoers.d/rpi-camera-gadget"

# Validate the sudoers file inside the chroot so a typo fails the build
# instead of silently disabling sudo on the device.
on_chroot << 'EOF'
visudo -cf /etc/sudoers.d/rpi-camera-gadget
systemctl enable rpi-cam-gadget-detect.service
systemctl enable rpi-cam-gadget.service
EOF
