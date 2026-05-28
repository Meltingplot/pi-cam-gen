#!/bin/bash -e

WORKING_DIR="/opt/meltingplot/rpi_camera"
VENV_DIR="${WORKING_DIR}/venv"

RPI_CAMERA_VERSION="$(cat files/rpi-camera-version)"
[ -n "${RPI_CAMERA_VERSION}" ] || { echo "files/rpi-camera-version is empty" >&2; exit 1; }

on_chroot << EOF
install -d -m 755 -o "${FIRST_USER_NAME}" -g "${FIRST_USER_NAME}" "${WORKING_DIR}"

runuser -u "${FIRST_USER_NAME}" -- python3 -m venv --system-site-packages "${VENV_DIR}"
runuser -u "${FIRST_USER_NAME}" -- "${VENV_DIR}/bin/pip" install --upgrade pip
runuser -u "${FIRST_USER_NAME}" -- "${VENV_DIR}/bin/pip" install "meltingplot.rpi_camera==${RPI_CAMERA_VERSION}"

RPI_CAMERA_SERVICE_USER="${FIRST_USER_NAME}" \\
RPI_CAMERA_SERVICE_GROUP="${FIRST_USER_NAME}" \\
RPI_CAMERA_WORKING_DIRECTORY="${WORKING_DIR}" \\
RPI_CAMERA_PING_FAILURES_BEFORE_REBOOT=30 \\
RPI_CAMERA_INITIAL_ASSOCIATION_TIMEOUT=120 \\
PATH="${VENV_DIR}/bin:\$PATH" \\
rpi-camera install
EOF
