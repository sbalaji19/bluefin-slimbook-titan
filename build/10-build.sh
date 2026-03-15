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
    dconf

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

# Papirus — installed first as the fallback (10,000+ app icons, best coverage)
dnf install -y papirus-icon-theme

# Reversal icon theme — rounded square icons, light + dark variants
# https://github.com/yeyushengfan258/Reversal-icon-theme
git clone --depth=1 https://github.com/yeyushengfan258/Reversal-icon-theme /tmp/Reversal-icon-theme
bash /tmp/Reversal-icon-theme/install.sh -d /usr/share/icons
rm -rf /tmp/Reversal-icon-theme

# Patch all Reversal variants to fall back to Papirus then hicolor
# This ensures ANY app without a Reversal icon gets a uniform Papirus square icon
for index_theme in /usr/share/icons/Reversal*/index.theme; do
    sed -i 's/^Inherits=.*/Inherits=Papirus,hicolor/' "${index_theme}"
done

# Install custom GNOME Shell theme (uniform rounded-square icon CSS)
mkdir -p /usr/share/themes/SlimbookTitan/gnome-shell
cp -r /ctx/custom/gnome-shell/themes/SlimbookTitan/gnome-shell/* \
    /usr/share/themes/SlimbookTitan/gnome-shell/

# Set icon theme + shell theme system-wide via dconf profile
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF
cat > /etc/dconf/db/local.d/01-icon-theme <<EOF
[org/gnome/desktop/interface]
icon-theme='Reversal-dark'

[org/gnome/shell/extensions/user-theme]
name='SlimbookTitan'

[org/gnome/shell]
enabled-extensions=['user-theme@gnome-shell-extensions.gcampax.github.com']
EOF
dconf update

# Rebuild icon cache for all affected themes
gtk-update-icon-cache -f /usr/share/icons/Reversal* 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/Papirus 2>/dev/null || true
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

echo "::group:: System Configuration"

# Enable/disable systemd services
systemctl enable podman.socket

# GRUB theme auto-apply service — runs grub2-mkconfig after every bootc deployment
# This is needed because bootc does not re-run grub2-mkconfig after image switch/upgrade
cat > /usr/lib/systemd/system/grub-theme-apply.service <<EOF
[Unit]
Description=Apply GRUB theme configuration
After=local-fs.target
ConditionPathExists=/etc/default/grub

[Service]
Type=oneshot
ExecStart=/usr/sbin/grub2-mkconfig -o /boot/grub2/grub.cfg
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl enable grub-theme-apply.service

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob

echo "Custom build complete!"
