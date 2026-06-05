# Building the pi-cam-gen image

The image is produced by [pi-gen](https://github.com/RPI-Distro/pi-gen) — this
repo is a fork. The CI build is the reference (see
[.github/workflows/build.yml](.github/workflows/build.yml)); locally it's the
standard pi-gen flow.

## Dependencies

pi-gen runs on Debian-based systems (or via Docker on others):

```bash
apt install coreutils quilt parted qemu-user-binfmt debootstrap zerofree zip \
dosfstools e2fsprogs libarchive-tools libcap2-bin grep rsync xz-utils file git curl bc \
gpg pigz xxd arch-test bmap-tools kmod
```

The [`depends`](depends) file is the authoritative tool list (`<tool>[:<debian-package>]`).

## Build

```bash
cat > config <<'EOF'
IMG_NAME='meltingplot-pi-cam'
RELEASE='trixie'
DEPLOY_COMPRESSION='xz'
COMPRESSION_LEVEL='6'
ENABLE_SSH='0'
STAGE_LIST='stage0 stage1 stage2'
EOF

sudo ./build.sh
```

The finished image lands in `deploy/`. To build inside a container instead:

```bash
./build-docker.sh
```

> ⚠️ On x86_64 hosts, building ARM images requires `binfmt_misc` /
> `qemu-user-static`. Under WSL you may need `sudo update-binfmts --enable`.

---

## pi-gen reference

Everything below is upstream pi-gen documentation, retained because this repo is
a fork. The most-used knobs are exposed via the `config` file sourced by
`build.sh`.

### Config variables

 * `IMG_NAME` (Default: `raspios-$RELEASE-$ARCH`) — root name of the image.
 * `RELEASE` (Default: `trixie`) — Debian release to build against.
 * `APT_PROXY` (Default: unset) — apt proxy for the build (not baked into the image).
 * `TEMP_REPO` (Default: unset) — extra temporary apt repo during build.
 * `WORK_DIR` (Default: `$BASE_DIR/work`) — build scratch (tens of GB; must be a Linux FS).
 * `DEPLOY_DIR` (Default: `$BASE_DIR/deploy`) — output directory.
 * `DEPLOY_COMPRESSION` (Default: `zip`) — `none` / `zip` / `gz` / `xz`.
 * `COMPRESSION_LEVEL` (Default: `6`) — 0–9.
 * `USE_QEMU` (Default: `0`) — build a QEMU-mountable image.
 * `LOCALE_DEFAULT` (Default: `en_GB.UTF-8`)
 * `TARGET_HOSTNAME` (Default: `raspberrypi`)
 * `KEYBOARD_KEYMAP` / `KEYBOARD_LAYOUT` (Default: `gb` / `English (UK)`)
 * `TIMEZONE_DEFAULT` (Default: `Europe/London`)
 * `FIRST_USER_NAME` (Default: `pi`) — renamed on first boot unless `DISABLE_FIRST_BOOT_USER_RENAME=1`.
 * `FIRST_USER_PASS` (Default: unset) — first user password; account locked if unset.
 * `PASSWORDLESS_SUDO` (Default: `0`)
 * `WPA_COUNTRY` (Default: unset) — 2-letter WLAN regulatory domain.
 * `ENABLE_SSH` (Default: `0`)
 * `PUBKEY_SSH_FIRST_USER` / `PUBKEY_ONLY_SSH` — SSH key provisioning.
 * `STAGE_LIST` (Default: `stage*`) — explicit ordered stage list.
 * `EXPORT_CONFIG_DIR` (Default: `$BASE_DIR/export-image`)
 * `ENABLE_CLOUD_INIT` (Default: `1`)

The config file can also be passed on the command line: `./build.sh -c myconfig`
(parsed after `config`, so it overrides).

### How the build process works

 * Iterate through stage directories in alphanumeric order.
 * Skip a stage directory containing a `SKIP` file.
 * Run `prerun.sh` (usually copies the build dir between stages).
 * In each stage, iterate subdirectories and run install scripts in order
   (two-digit numeric prefix). Recognized files:
     - **00-run.sh** — shell script (executable).
     - **00-run-chroot.sh** — run inside the image chroot.
     - **00-debconf** — fed to `debconf-set-selections`.
     - **00-packages** — packages to install (space-separated).
     - **00-packages-nr** — installed with `--no-install-recommends -y`.
     - **00-patches** — quilt patch directory.
 * Stages with `EXPORT_NOOBS` / `EXPORT_IMAGE` are added to the image-generation list.

### Docker build

```bash
vi config            # edit config (see above)
./build-docker.sh
```

Output lands in `deploy/`. Remove the container with `docker rm -v pigen_work`.
Continue after a failure with `CONTINUE=1 ./build-docker.sh`; keep the container
with `PRESERVE_CONTAINER=1`. Extra docker args go in `PIGEN_DOCKER_OPTS`.
`binfmt-support` must be enabled on the host kernel.

### Skipping stages to speed up development

 * Add `SKIP_IMAGES` to directories with `EXPORT_*` files.
 * Add `SKIP` files to stages you don't want to build.
 * Run `build.sh`, then add `SKIP` to the already-built stages.
 * Rebuild just the last stage with `sudo CLEAN=1 ./build.sh` (Docker:
   `PRESERVE_CONTAINER=1 CONTINUE=1 CLEAN=1 ./build-docker.sh`).

### Troubleshooting binfmt_misc

Building ARM images on x86_64 needs the
[`binfmt_misc`](https://en.wikipedia.org/wiki/Binfmt_misc) kernel module. If you
see `Couldn't load the binfmt_misc module` or `Exec format error`, ensure these
exist (install if needed):

```
/lib/modules/$(uname -r)/kernel/fs/binfmt_misc.ko
/usr/bin/qemu-arm-static
```

Load it with `modprobe binfmt_misc`. Under WSL: `sudo update-binfmts --enable`.
