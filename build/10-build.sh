#!/usr/bin/bash

set -eoux pipefail

###############################################################################
# Main Build Script
###############################################################################
# This script follows the @ublue-os/bluefin pattern for build scripts.
# It uses set -eoux pipefail for strict error handling and debugging.
###############################################################################

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

# Enable nullglob for all glob operations to prevent failures on empty matches
shopt -s nullglob

echo "::group:: Copy Bluefin Config from Common"

# Copy just files from @projectbluefin/common (includes 00-entry.just which imports 60-custom.just)
mkdir -p /usr/share/ublue-os/just/
shopt -s nullglob
cp -r /ctx/oci/common/bluefin/usr/share/ublue-os/just/* /usr/share/ublue-os/just/
shopt -u nullglob

echo "::endgroup::"

echo "::group:: Copy Custom Files"

# Copy Brewfiles to standard location
mkdir -p /usr/share/ublue-os/homebrew/
cp /ctx/custom/brew/*.Brewfile /usr/share/ublue-os/homebrew/

# Consolidate Just Files
find /ctx/custom/ujust -iname '*.just' -exec printf "\n\n" \; -exec cat {} \; >> /usr/share/ublue-os/just/60-custom.just

# Copy Flatpak preinstall files
mkdir -p /etc/flatpak/preinstall.d/
cp /ctx/custom/flatpaks/*.preinstall /etc/flatpak/preinstall.d/

echo "::endgroup::"

echo "::group:: Install Packages"

# Add Slimbook OBS repository
dnf config-manager addrepo \
    --from-repofile=https://download.opensuse.org/repositories/home:/Slimbook/Fedora_$(rpm -E %fedora)/home:Slimbook.repo

# Install Slimbook Titan hardware packages
# --setopt=tsflags=noscripts skips post-install compile scripts —
# akmod modules are built separately in Containerfile RUN layers
dnf install -y --setopt=tsflags=noscripts \
    slimbook-meta-common \
    slimbook-meta-titan \
    slimbook-meta-gnome \
    slimbook-service \
    slimbook-qc71-kmod \
    slimbook-qc71-kmod-common \
    slimbook-yt6801-kmod \
    slimbook-yt6801-kmod-common \
    slimbook-ite8291-kmod \
    slimbook-ite8291-kmod-common

# Install Slimbook GUI applications (provides icons + desktop entries)
dnf install -y \
    slimbook-battery \
    slimbook-face \
    slimbook-one \
    slimbook-rgb-keyboard || true

# Rebuild icon/desktop caches manually — skipped by --setopt=tsflags=noscripts above
gtk-update-icon-cache -f /usr/share/icons/hicolor/ || true
update-desktop-database /usr/share/applications/ || true

echo "::endgroup::"

echo "::group:: System Configuration"

# Enable/disable systemd services
systemctl enable podman.socket
# Example: systemctl mask unwanted-service

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob

echo "Custom build complete!"
