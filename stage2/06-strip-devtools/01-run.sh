#!/bin/bash -e

on_chroot << EOF
apt-get -y purge build-essential
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF
