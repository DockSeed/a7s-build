# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# What the Debian root filesystem is made of: package sets and the rules that
# hold them. Data only; sourced by scripts/distro/debian/distro.sh.

DEBIAN_SUITE="trixie"
DEBIAN_ARCH="arm64"

# --- every image --------------------------------------------------------------
# mmdebstrap --variant=minbase (Priority: required + apt) plus these. Each one is
# here for what it does on the board:
#   systemd-sysv udev dbus      init, device manager, system bus
#   libpam-systemd              every login a logind session (user slice, OOM
#                               kills of a login's load do not take sshd along)
#   sudo                        the user account is in group sudo
#   ca-certificates             apt and curl over https
#   procps iproute2 kmod        free/ps, ip, modprobe (minbase has libkmod only:
#                               without kmod, systemd's modprobe@ units fail)
#   openssh-server              remote login (no password login until one is set)
#   systemd-timesyncd           the board has no RTC battery; TLS needs the time
#   network-manager             Ethernet and WLAN
#   wpasupplicant iw rfkill     WLAN association, regulatory readout, rfkill
#   wireless-regdb              regulatory.db + .p7s the kernel can verify
#   bluez                       Bluetooth userspace
#   busybox                     its devmem applet clears the boot chain's boot
#                               counter (a7s-boot-good.service)
#   e2fsprogs fdisk             fsck.ext4, resize2fs, sfdisk: a7s-growroot
#   ethtool iputils-ping wget curl xz-utils pciutils usbutils nvme-cli nano less
#                               the tools a board reached only through a
#                               console needs to say what it sees
#   linux-sysctl-defaults       ping_group_range (unprivileged ping)
#   nftables iptables           netfilter userspace (iptables-nft), no ruleset
#   systemd-zram-generator      swap in compressed RAM
#   kmscon                      the console on the screen (tty1); from backports
DEBIAN_BASE_PACKAGES=(
  systemd-sysv udev dbus libpam-systemd sudo ca-certificates procps iproute2 kmod
  openssh-server systemd-timesyncd network-manager
  wpasupplicant iw rfkill wireless-regdb bluez busybox e2fsprogs fdisk
  ethtool iputils-ping wget curl xz-utils pciutils usbutils nvme-cli nano less
  linux-sysctl-defaults nftables iptables systemd-zram-generator kmscon
)

# Debian's standard parts that minbase leaves out, each for what it does:
#   logrotate        logs under /var/log are rotated instead of filling the card
#   bash-completion  Tab completes commands and options
#   libnss-systemd   names for systemd's dynamic users and groups
#   whiptail         debconf's dialog front end, for dpkg-reconfigure
#   debconf-i18n     debconf's translated questions
#   apt-utils        apt-extracttemplates, so debconf can preconfigure packages
STANDARD_IMAGE_PACKAGES=(logrotate bash-completion libnss-systemd whiptail debconf-i18n apt-utils)

# Debian's Mesa from trixie-backports: the 26.1 series carries the PowerVR
# Vulkan driver trixie's 25.0 lacks. Every image gets the same set (kmscon needs
# libgbm1 anyway); the X desktop runs without GPU acceleration.
MESA_IMAGE_PACKAGES=(
  libgbm1 libegl-mesa0 libglx-mesa0 libgl1-mesa-dri
  mesa-libgallium mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers
)
# deb-version(7) of a trixie backport: <upstream>-<revision>~bpo13+<n>.
MESA_BPO_MARK="~bpo13+"
MESA_POWERVR_VK_LIB="usr/lib/aarch64-linux-gnu/libvulkan_powervr_mesa.so"
# kmscon below 10.0.3 frees its per-card state when a DRM card fails to
# initialise and keeps using it; this SoC always has such a card (the GPU's
# render-only node), so every stop of kmscon crashed.
KMSCON_MIN_VERSION="10.0.3"

# Exactly what the two backports pins admit (preferences.d/kmscon-backports,
# preferences.d/mesa-backports). Any other package with a backports version got
# in at apt's default priority 100 because no other suite has it; the build
# fails on that (assert_backports_allow_list).
BACKPORTS_ALLOWED_PACKAGES=(kmscon libtsm4)
BACKPORTS_ALLOWED_SOURCES=(mesa)

# --- A7S_DESKTOP=1: Debian's Xfce task with LightDM -----------------------------
# Named in the same apt-get call as task-desktop and task-xfce-desktop, so each
# meets an alternative before apt picks a provider on its own:
#   mate-polkit      the session's polkit agent (without it apt took one from
#                    backports with a Qt6 stack)
#   evince           the PDF viewer, in place of atril (below)
#   xdg-desktop-portal xdg-desktop-portal-gtk   the desktop portals
#   fonts-liberation the metric twins of Arial, Times and Courier
DESKTOP_TASK_ALSO=(mate-polkit evince xdg-desktop-portal xdg-desktop-portal-gtk fonts-liberation)
# Recommends of the task that the call leaves out (apt-get's `<package>-`):
# atril pulls WebKitGTK (190 MiB); LibreOffice and the data only it reads are
# 426 MiB. A user installs any of them with apt as usual.
DESKTOP_TASK_WITHOUT=(atril libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk3 libreoffice-help-en-us mythes-en-us hyphen-en-us)
# Added after the task, with Recommends:
#   locales libc-l10n             the greeter offers DESKTOP_LOCALES
#   gvfs-backends                 Thunar's network places, phones, cameras
#                                 (clients only; DESKTOP_NEVER holds the servers out)
#   package-update-indicator      a tray icon when updates wait
#   earlyoom                      ends the largest process before the desktop
#                                 freezes in reclaim
#   greybird-gtk-theme elementary-xfce-icon-theme   the desktop's look
#   console-setup                 the keymap of /etc/default/keyboard on tty2..6
#                                 too, as the Debian installer installs it
DESKTOP_ADDITIONS=(locales libc-l10n gvfs-backends package-update-indicator earlyoom
                   greybird-gtk-theme elementary-xfce-icon-theme console-setup)
# Bluetooth audio and its tray applet.
DESKTOP_BLUETOOTH=(pulseaudio-module-bluetooth blueman)
DESKTOP_LOCALES="de_DE.UTF-8 UTF-8, en_GB.UTF-8 UTF-8, en_US.UTF-8 UTF-8"
# Language and keyboard of the desktop image, as the Debian installer sets them
# for English (United States). DESKTOP_LANG must be one of DESKTOP_LOCALES.
DESKTOP_LANG="en_US.UTF-8"
DESKTOP_XKB_LAYOUT="us"
DESKTOP_LOOK_DIR="etc/xdg/xdg-a7s"
DESKTOP_GTK_THEME="Greybird"
DESKTOP_ICON_THEME="elementary-xfce"
DESKTOP_WM_THEME="Greybird"
# Never in a desktop image: a file server or a WS-Discovery responder beside
# gvfs's clients.
DESKTOP_NEVER=(samba ksmbd-tools wsdd wsdd2)
# The only activation points DESKTOP_ADDITIONS may add (activation_points):
DESKTOP_ADDITIONS_MAY_ACTIVATE=(
  # earlyoom: the point of the package; its postinst enables it
  etc/systemd/system/multi-user.target.wants/earlyoom.service
  # packagekit: a UNIX socket in each user's runtime directory for debconf
  # questions during an install; not a network socket
  etc/systemd/user/sockets.target.wants/pk-debconf-helper.socket
  # packagekit: runs only in an offline-update boot (/system-update exists)
  usr/lib/systemd/system/system-update.target.wants/packagekit-offline-update.service
  # package-update-indicator: the tray icon itself, started with the session
  etc/xdg/autostart/org.guido-berhoerster.code.package-update-indicator.desktop
  # console-setup: keymap and font of the text consoles, from /etc/default/keyboard
  etc/systemd/system/sysinit.target.wants/keyboard-setup.service
  etc/systemd/system/multi-user.target.wants/console-setup.service
)

# --- enable links the image adds to or removes from Debian's -----------------
# `<+|-> <link under etc/systemd> <unit it names>`. Every other difference
# between the enable links Debian's packages left and the finished rootfs fails
# the build (debian_check_unit_links).
DEBIAN_OWN_LINKS=(
  "+ system/multi-user.target.wants/a7s-growroot.service a7s-growroot.service"
  "+ system/multi-user.target.wants/a7s-boot-good.service a7s-boot-good.service"
  "+ system/multi-user.target.wants/a7s-ssh-keygen.service a7s-ssh-keygen.service"
  "+ system/multi-user.target.wants/a7s-nvme-hostid.service a7s-nvme-hostid.service"
  "+ system/multi-user.target.wants/a7s-ssl-cert.service a7s-ssl-cert.service"
  "+ system/multi-user.target.wants/a7s-icon-caches.service a7s-icon-caches.service"
  "+ system/getty.target.wants/serial-getty@ttyS0.service serial-getty@.service"
  "+ system/getty.target.wants/kmsconvt@tty1.service kmsconvt@.service"
  "- system/autovt@.service kmsconvt@.service"
  "+ system/autovt@.service getty@.service"
  "+ system/systemd-firstboot.service /dev/null"
  "+ system/default.target graphical.target"
  "- system/default.target.wants/nvmf-autoconnect.service nvmf-autoconnect.service"
  "- system/default.target.wants/nvmefc-boot-connections.service nvmefc-boot-connections.service"
)
