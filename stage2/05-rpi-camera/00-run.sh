#!/bin/bash -e

# Install the locked-down sudoers entry that lets the rpi-camera service user
# run the two-stage frame watchdog's recovery actions (systemctl restart of
# its own unit, then reboot) without a password. The watchdog itself lives in
# the meltingplot.rpi_camera package; the matching RuntimeDirectory= for its
# /run marker ships with that package's systemd unit (installed by
# `rpi-camera install` in 01-run.sh), so only the sudoers needs adding here.

# sudoers: substitute the real first-user name, then install 0440 root:root.
install -m 0440 files/etc/sudoers.d/rpi-camera-watchdog "${ROOTFS_DIR}/etc/sudoers.d/rpi-camera-watchdog"
sed -i "s/FIRST_USER_NAME/${FIRST_USER_NAME}/g" "${ROOTFS_DIR}/etc/sudoers.d/rpi-camera-watchdog"

# Validate inside the chroot so a typo fails the build instead of silently
# disabling sudo on the device.
on_chroot << 'EOF'
visudo -cf /etc/sudoers.d/rpi-camera-watchdog
EOF
