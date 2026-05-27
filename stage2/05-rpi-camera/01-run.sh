#!/bin/bash -e

WORKING_DIR="/opt/meltingplot/rpi_camera"
VENV_DIR="${WORKING_DIR}/venv"

on_chroot << EOF
install -d -m 755 "${WORKING_DIR}"
python3 -m venv --system-site-packages "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install "meltingplot.rpi_camera>=1.0.0rc3"

RPI_CAMERA_SERVICE_USER="${FIRST_USER_NAME}" \\
RPI_CAMERA_SERVICE_GROUP="${FIRST_USER_NAME}" \\
RPI_CAMERA_WORKING_DIRECTORY="${WORKING_DIR}" \\
RPI_CAMERA_PING_FAILURES_BEFORE_REBOOT=30 \\
RPI_CAMERA_INITIAL_ASSOCIATION_TIMEOUT=120 \\
PATH="${VENV_DIR}/bin:\$PATH" \\
rpi-camera install
EOF
