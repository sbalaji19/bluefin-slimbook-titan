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

echo "::group:: Install Build Tools"

# Ensure tools needed for icon theme + extension install are available
dnf install -y \
    git \
    unzip \
    curl \
    dconf \
    python3-pip

# ite8291r3-ctl — userspace RGB control for ITE 8291 keyboard (048d:6004)
# --prefix=/usr installs to /usr/lib/python3.x/site-packages and /usr/bin/
pip3 install --prefix=/usr ite8291r3-ctl

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
    slimbook-yt6801-kmod-common

# Install Slimbook GUI applications (provides icons + desktop entries)
# Use individual installs so one missing package doesn't block the rest
dnf install -y slimbook-battery || echo "slimbook-battery not found, skipping"
dnf install -y slimbook-face    || echo "slimbook-face not found, skipping"
dnf install -y slimbook-one     || echo "slimbook-one not found, skipping"
dnf install -y slimbook-rgb-keyboard || echo "slimbook-rgb-keyboard not found, skipping"

# Rebuild icon/desktop caches manually — skipped by --setopt=tsflags=noscripts above
gtk-update-icon-cache -f /usr/share/icons/hicolor/ || true
update-desktop-database /usr/share/applications/ || true

echo "::endgroup::"

echo "::group:: Icon Themes"

# Papirus + Papirus-Dark — 10,000+ uniform square icons, best app coverage
dnf install -y papirus-icon-theme papirus-icon-theme-dark

# Install custom GNOME Shell theme (uniform rounded-square icon CSS)
mkdir -p /usr/share/themes/SlimbookTitan/gnome-shell
cp -r /ctx/custom/gnome-shell/themes/SlimbookTitan/gnome-shell/* \
    /usr/share/themes/SlimbookTitan/gnome-shell/

# Set icon theme + shell theme system-wide via dconf profile
# NOTE: Do NOT set enabled-extensions here — it would overwrite Bluefin's default extensions
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF
cat > /etc/dconf/db/local.d/01-icon-theme <<EOF
[org/gnome/desktop/interface]
icon-theme='Papirus-Dark'

[org/gnome/shell/extensions/user-theme]
name='SlimbookTitan'
EOF
dconf update

# Rebuild icon cache
gtk-update-icon-cache -f /usr/share/icons/Papirus 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/Papirus-Dark 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

echo "::endgroup::"

echo "::group:: GNOME Extensions"

# P7 Window Borders — intelligent window borders for all windows
# https://extensions.gnome.org/extension/9064/p7-window-borders/
EXTENSION_UUID="p7-borders@prasannavl.com"
EXTENSION_URL="https://extensions.gnome.org/download-extension/${EXTENSION_UUID}.shell-extension.zip?version_tag=68456"
mkdir -p /usr/share/gnome-shell/extensions/${EXTENSION_UUID}
curl -L "${EXTENSION_URL}" -o /tmp/${EXTENSION_UUID}.zip
unzip -o /tmp/${EXTENSION_UUID}.zip -d /usr/share/gnome-shell/extensions/${EXTENSION_UUID}
rm -f /tmp/${EXTENSION_UUID}.zip

echo "::endgroup::"

echo "::group:: Polkit Rules"

# Allow wheel group users to control Slimbook services without password prompt
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-slimbook-rgb.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id.indexOf("com.slimbook") === 0 ||
         action.id.indexOf("org.freedesktop.color-manager") === 0) &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

# Patch any slimbook polkit .policy files to not require password for active users
for policy in /usr/share/polkit-1/actions/com.slimbook*.policy; do
    [ -f "$policy" ] && \
    sed -i 's|<allow_active>auth_admin</allow_active>|<allow_active>yes</allow_active>|g' "$policy" && \
    sed -i 's|<allow_active>auth_admin_keep</allow_active>|<allow_active>yes</allow_active>|g' "$policy" || true
done

echo "::endgroup::"

echo "::group:: Udev Rules — RGB Keyboard + Fan Control"

mkdir -p /etc/udev/rules.d

# ITE 8291 RGB keyboard controller (used in Slimbook Titan)
# Allows users in the 'input' and 'wheel' groups to access the HID device directly
# ITE USB vendor ID: 048d — common product IDs for keyboard RGB controllers
cat > /etc/udev/rules.d/70-slimbook-rgb.rules <<'EOF'
# ITE 8291 RGB keyboard (048d:6004) — allow non-root access for Slimbook RGB app and ite8291r3-ctl
SUBSYSTEM=="usb", ATTRS{idVendor}=="048d", ATTRS{idProduct}=="6004", MODE="0666", GROUP="input"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="048d", ATTRS{idProduct}=="6004", MODE="0666", GROUP="input"
KERNEL=="hidraw*", ATTRS{idVendor}=="048d", ATTRS{idProduct}=="6004", MODE="0666", GROUP="input"
EOF

# qc71 sysfs interface — allow wheel group to write fan/perf mode without sudo
# The qc71_laptop module exposes controls under /sys/devices/platform/qc71_laptop/
cat > /etc/udev/rules.d/71-slimbook-qc71.rules <<'EOF'
# qc71_laptop platform device — fan boost, silent mode, turbo mode, fn-lock
SUBSYSTEM=="platform", KERNEL=="qc71_laptop", RUN+="/bin/chmod -R a+rw /sys/devices/platform/qc71_laptop/"
EOF

echo "::endgroup::"

echo "::group:: Kernel Module Auto-load"

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/slimbook.conf <<'EOF'
# Slimbook Titan kernel modules
qc71_laptop
yt6801
EOF

echo "::endgroup::"

echo "::group:: System Configuration"

# Enable/disable systemd services
systemctl enable podman.socket

# Enable Slimbook service if it exists (name varies by package version)
systemctl enable slimbook-service.service

# GRUB theme apply service
# - Copies theme files from /usr/share (rootfs) to /boot (boot partition, readable by GRUB)
# - Detects UEFI vs BIOS and writes grub.cfg to the correct path
# - Runs on every boot so upgrades via bootc upgrade keep the theme
cat > /usr/lib/systemd/system/grub-theme-apply.service <<'EOF'
[Unit]
Description=Apply Slimbook GRUB theme
After=local-fs.target
ConditionPathExists=/usr/share/grub/themes/slimbook/theme.txt

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  mkdir -p /boot/grub2/themes && \
  cp -r /usr/share/grub/themes/slimbook /boot/grub2/themes/slimbook && \
  touch /etc/default/grub && \
  sed -i "/^GRUB_THEME=/d" /etc/default/grub && \
  sed -i "/^GRUB_GFXMODE=/d" /etc/default/grub && \
  echo "GRUB_THEME=/boot/grub2/themes/slimbook/theme.txt" >> /etc/default/grub && \
  echo "GRUB_GFXMODE=2560x1440x32" >> /etc/default/grub && \
  if [ -d /sys/firmware/efi ]; then \
    EFI_CFG=$(find /boot/efi/EFI -name grub.cfg 2>/dev/null | head -1) && \
    [ -n "$EFI_CFG" ] && grub2-mkconfig -o "$EFI_CFG" || grub2-mkconfig -o /boot/grub2/grub.cfg; \
  else \
    grub2-mkconfig -o /boot/grub2/grub.cfg; \
  fi'
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl enable grub-theme-apply.service

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob

echo "Custom build complete!"
