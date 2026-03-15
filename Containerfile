###############################################################################
# PROJECT NAME CONFIGURATION
###############################################################################
# Name: finpilot
#
# IMPORTANT: Change "finpilot" above to your desired project name.
# This name should be used consistently throughout the repository in:
#   - Justfile: export image_name := env("IMAGE_NAME", "your-name-here")
#   - README.md: # your-name-here (title)
#   - artifacthub-repo.yml: repositoryID: your-name-here
#   - custom/ujust/README.md: localhost/your-name-here:stable (in bootc switch example)
#
# The project name defined here is the single source of truth for your
# custom image's identity. When changing it, update all references above
# to maintain consistency.
###############################################################################

###############################################################################
# MULTI-STAGE BUILD ARCHITECTURE
###############################################################################
# This Containerfile follows the Bluefin architecture pattern as implemented in
# @projectbluefin/distroless. The architecture layers OCI containers together:
#
# 1. Context Stage (ctx) - Combines resources from:
#    - Local build scripts and custom files
#    - @projectbluefin/common - Desktop configuration shared with Aurora 
#    - @ublue-os/brew - Homebrew integration
#
# 2. Base Image Options:
#    - `ghcr.io/ublue-os/silverblue-main:latest` (Fedora and GNOME)
#    - `ghcr.io/ublue-os/base-main:latest` (Fedora and no desktop 
#    - `quay.io/centos-bootc/centos-bootc:stream10 (CentOS-based)` 
#
# See: https://docs.projectbluefin.io/contributing/ for architecture diagram
###############################################################################

# Context stage - combine local and imported OCI container resources
FROM scratch AS ctx

COPY build /build
COPY custom /custom
# Copy from OCI containers to distinct subdirectories to avoid conflicts
# Note: Renovate can automatically update these :latest tags to SHA-256 digests for reproducibility
COPY --from=ghcr.io/projectbluefin/common:latest@sha256:b8fe93b16674a547b4cf38493af19caa484d9575956fc3be04ca3d10faec23ff /system_files /oci/common
COPY --from=ghcr.io/ublue-os/brew:latest@sha256:ca91068f51ce663d495ccfc829352d6621ec95f6c7db447ade55023b222f9762 /system_files /oci/brew

# Base Image - Bluefin DX + NVIDIA open drivers, Fedora 43
FROM ghcr.io/ublue-os/bluefin-dx-nvidia-open:43

## Alternative base images (uncomment to use):
# FROM ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable  (tracks latest stable Fedora)
# FROM ghcr.io/ublue-os/bluefin-dx-nvidia:43            (proprietary NVIDIA, older cards)
# FROM ghcr.io/ublue-os/bluefin-dx:43                   (no NVIDIA)
# FROM ghcr.io/ublue-os/bluefin:43                      (no DX, no NVIDIA)

### /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## Make modifications desired in your image and install packages by modifying the build scripts.
## The following RUN directive mounts the ctx stage which includes:
##   - Local build scripts from /build
##   - Local custom files from /custom
##   - Files from @projectbluefin/common at /oci/common
##   - Files from @projectbluefin/branding at /oci/branding
##   - Files from @ublue-os/artwork at /oci/artwork
##   - Files from @ublue-os/brew at /oci/brew
## Scripts are run in numerical order (10-build.sh, 20-example.sh, etc.)

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/10-build.sh
    
### SLIMBOOK TITAN HARDWARE SUPPORT
## Kernel modules must be compiled here (not in build scripts) because:
## - Bluefin ships a stub kernel-devel (RPM registered but no actual header files)
## - akmods refuses to build as root — requires su to akmods user
## - Each step must be a separate RUN layer for correct isolation

# Step 1: Replace stub kernel-devel with real one (provides /usr/src/kernels/)
RUN KVER=$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    echo "Building for kernel: ${KVER}" && \
    rpm -e --nodeps kernel-devel-${KVER} || true && \
    dnf install -y kernel-devel-${KVER} && \
    ls /usr/src/kernels/

# Step 2: Build slimbook-qc71 kernel module (fan control, lightbar, performance modes)
RUN KVER=$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    chmod 1777 /tmp && \
    mkdir -p /var/lib/akmods && chown akmods:akmods /var/lib/akmods && \
    SRPM=$(ls /usr/src/akmods/slimbook-qc71-kmod-*.src.rpm) && \
    su -s /bin/bash akmods -c "cd /var/lib/akmods && HOME=/var/lib/akmods akmodsbuild --target $(uname -m) --kernels ${KVER} ${SRPM}" && \
    dnf install -y /var/lib/akmods/kmod-slimbook-qc71-${KVER}-*.rpm

# Step 3: Build slimbook-yt6801 kernel module (Ethernet driver)
RUN KVER=$(rpm -qa kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    SRPM=$(ls /usr/src/akmods/slimbook-yt6801-kmod-*.src.rpm) && \
    su -s /bin/bash akmods -c "cd /var/lib/akmods && HOME=/var/lib/akmods akmodsbuild --target $(uname -m) --kernels ${KVER} ${SRPM}" && \
    dnf install -y /var/lib/akmods/kmod-slimbook-yt6801-${KVER}-*.rpm

# Step 4: Cleanup — modules compiled, headers no longer needed
RUN dnf remove -y kernel-devel && dnf clean all

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
