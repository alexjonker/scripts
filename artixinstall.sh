#!/usr/bin/env bash
set -euo pipefail

# ----------------------------- CONFIG ----------------------------------------

HOSTNAME="artix"
TIMEZONE="Europe/Amsterdam"
BOOTLOADER_ID="artix"

# -----------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -d /sys/firmware/efi ]] || {
    echo "Not booted in UEFI mode. Boot the live USB in UEFI mode."
    exit 1
}

echo "Checking internet..."
ping -c 4 artixlinux.org

# ----------------------------- USERNAME --------------------------------------

while true; do
    read -rp "Username to create: " USERNAME
    if [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        break
    fi
    echo "Invalid username. Use lowercase letters, digits, _ and -."
done

# ----------------------------- DISK ------------------------------------------

echo
echo "Available disks:"

mapfile -t DISKS < <(
    lsblk -dpno NAME,SIZE,TYPE,MODEL |
        awk '$3 == "disk"'
)

[[ ${#DISKS[@]} -gt 0 ]] || {
    echo "No disks found."
    exit 1
}

PS3="Select disk (number): "
select choice in "${DISKS[@]}"; do
    if [[ -n ${choice:-} ]]; then
        DISK=$(awk '{print $1}' <<< "$choice")
        break
    fi
    echo "Invalid selection."
done

# ----------------------------- PARTITIONING ----------------------------------

echo
lsblk "$DISK"
echo
echo "Create a GPT partition table in cfdisk with:"
echo "  1. EFI System partition: ~1 GiB, type EFI System"
echo "  2. Linux root partition: remaining space, type Linux filesystem"
echo
echo "Write the changes and quit cfdisk."
read -rp "Press Enter to open cfdisk..."
cfdisk "$DISK"

mapfile -t PARTITIONS < <(
    lsblk -lnpo NAME,SIZE,TYPE "$DISK" |
        awk '$3 == "part" {print $1, $2}'
)

[[ ${#PARTITIONS[@]} -ge 2 ]] || {
    echo "Expected at least 2 partitions."
    exit 1
}

# EFI partition
echo
echo "Select the EFI System partition:"
PS3="EFI partition (number): "
select choice in "${PARTITIONS[@]}"; do
    if [[ -n ${choice:-} ]]; then
        BOOT_PART=$(awk '{print $1}' <<< "$choice")
        break
    fi
    echo "Invalid selection."
done

# Root partition
echo
echo "Select the Linux root partition:"
PS3="Root partition (number): "
select choice in "${PARTITIONS[@]}"; do
    if [[ -n ${choice:-} ]]; then
        ROOT_PART=$(awk '{print $1}' <<< "$choice")
        if [[ $ROOT_PART != "$BOOT_PART" ]]; then
            break
        fi
    fi
    echo "Choose a different partition."
done

echo
echo "Disk: $DISK"
echo "EFI:  $BOOT_PART (FAT32)"
echo "Root: $ROOT_PART (Btrfs)"
echo
echo "WARNING: Both selected partitions will be formatted!"
read -rp "Type YES to continue: " answer

[[ $answer == "YES" ]] || {
    echo "Aborted."
    exit 1
}

# ----------------------------- FILESYSTEMS -----------------------------------

echo ">>> Creating filesystems"

mkfs.fat -F32 "$BOOT_PART"
mkfs.btrfs -f "$ROOT_PART"

mount -o compress=zstd,discard=async "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# ----------------------------- BASE INSTALL ----------------------------------

echo ">>> Installing base system"

basestrap /mnt base base-devel dinit elogind-dinit linux-firmware sof-firmware \
    grub efibootmgr dosfstools \
    networkmanager-dinit \
    btrfs-progs sudo \
    nano fastfetch \
	openssh-dinit

# ----------------------------- FSTAB -----------------------------------------

echo ">>> Generating fstab"

fstabgen -U /mnt > /mnt/etc/fstab

# ----------------------------- CHROOT CONFIG ---------------------------------

echo ">>> Time zone"

artix-chroot /mnt /bin/bash -c "
    ln -sf '/usr/share/zoneinfo/$TIMEZONE' /etc/localtime
    hwclock --systohc
"

echo ">>> Locale"

artix-chroot /mnt /bin/bash -c '
    sed -i -E \
        "s/^#(en_US\.UTF-8 UTF-8)/\1/; s/^#(nl_NL\.UTF-8 UTF-8)/\1/" \
        /etc/locale.gen

    locale-gen

    cat > /etc/locale.conf <<EOF
LANG="en_US.UTF-8"
LC_TIME="nl_NL.UTF-8"
EOF
'

echo ">>> Hostname"

artix-chroot /mnt /bin/bash -c "
    echo '$HOSTNAME' > /etc/hostname

    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
EOF
"

echo ">>> Users"

echo "Set root password:"
artix-chroot /mnt /usr/bin/passwd

artix-chroot /mnt /usr/bin/useradd \
    -m -G wheel -s /bin/bash "$USERNAME"

echo "Set password for $USERNAME:"
artix-chroot /mnt /usr/bin/passwd "$USERNAME"

artix-chroot /mnt /bin/bash -c \
    "sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers"

# ----------------------------- EXTRA REPOSITORIES ----------------------------

echo ">>> Extra repositories (Arch, Chaotic-AUR, auris)"

# Add archlinux, chaotic aur and auris repos
artix-chroot /mnt /bin/bash -c '
    set -euo pipefail

    pacman-key --init
    pacman-key --populate artix

    pacman -Sy --needed --noconfirm \
        archlinux-mirrorlist artix-archlinux-support archlinux-keyring
    pacman-key --populate archlinux

    # Chaotic-AUR
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    pacman -U --noconfirm \
        "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst" \
        "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst"

    # auris
    AURIS_FPR="74E5750C4A3C00F037070EF2357B525A97500B9F"
    curl -fsSL https://auris.artixlinux.org/api/packages/auris/arch/repository.key \
        -o /tmp/auris-repository.key
    gpg --show-keys /tmp/auris-repository.key

    FPR=$(gpg --show-keys --with-colons /tmp/auris-repository.key \
        | awk -F: "\$1==\"fpr\" {print \$10; exit}")
    if [[ $FPR != "$AURIS_FPR" ]]; then
        echo "ERROR: auris key fingerprint mismatch ($FPR)." >&2
        exit 1
    fi

    pacman-key --add /tmp/auris-repository.key
    pacman-key --lsign-key "$AURIS_FPR"
    rm -f /tmp/auris-repository.key
'

# Step 2: write the final pacman.conf (mirrorlist files now exist)
cp /mnt/etc/pacman.conf /mnt/etc/pacman.conf.pacnew-backup

cat > /mnt/etc/pacman.conf <<'EOF'
#
# /etc/pacman.conf
#
# See the pacman.conf(5) manpage for option and repository directives

#
# GENERAL OPTIONS
#
[options]
# The following paths are commented out with their default values listed.
# If you wish to use different paths, uncomment and update the paths.
#RootDir     = /
#DBPath      = /var/lib/pacman/
#CacheDir    = /var/cache/pacman/pkg/
#LogFile     = /var/log/pacman.log
#GPGDir      = /etc/pacman.d/gnupg/
#HookDir     = /etc/pacman.d/hooks/
HoldPkg     = pacman glibc
#XferCommand = /usr/bin/curl -L -C - -f -o %o %u
#XferCommand = /usr/bin/wget --passive-ftp -c -O %o %u
#CleanMethod = KeepInstalled
Architecture = auto

ILoveCandy

# Pacman won't upgrade packages listed in IgnorePkg and members of IgnoreGroup
#IgnorePkg   =
#IgnoreGroup =

#NoUpgrade   =
NoExtract    = usr/lib/thunarx-3/thunar-wallpaper-plugin.so

# Misc options
#UseSyslog
Color
#NoProgressBar
CheckSpace
#VerbosePkgLists
ParallelDownloads = 5
DownloadUser = alpm
#DisableSandboxFilesystem
#DisableSandboxSyscalls

# By default, pacman accepts packages signed by keys that its local keyring
# trusts (see pacman-key and its man page), as well as unsigned packages.
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
#RemoteFileSigLevel = Required

# NOTE: You must run `pacman-key --init` before first using pacman; the local
# keyring can then be populated with the keys of all official Artix Linux
# packagers with `pacman-key --populate artix`.

#
# REPOSITORIES
#   - can be defined here or included from another file
#   - pacman will search repositories in the order defined here
#   - local/custom mirrors can be added here or in separate files
#   - repositories listed first will take precedence when packages
#     have identical names, regardless of version number
#   - URLs will have $repo replaced by the name of the current repo
#   - URLs will have $arch replaced by the name of the architecture
#
# Repository entries are of the format:
#       [repo-name]
#       Server = ServerName
#       Include = IncludePath
#
# The header [repo-name] is crucial - it must be present and
# uncommented to enable the repo.
#

# The gremlins repositories are disabled by default. To enable, uncomment the
# repo name header and Include lines. You can add preferred servers immediately
# after the header, and they will be used before the default mirrors.

#[system-gremlins]
#Include = /etc/pacman.d/mirrorlist

[system]
Include = /etc/pacman.d/mirrorlist

#[world-gremlins]
#Include = /etc/pacman.d/mirrorlist

[world]
Include = /etc/pacman.d/mirrorlist

#[galaxy-gremlins]
#Include = /etc/pacman.d/mirrorlist

[galaxy]
Include = /etc/pacman.d/mirrorlist

# If you want to run 32 bit applications on your x86_64 system,
# enable the lib32 repositories as required here.

#[lib32-gremlins]
#Include = /etc/pacman.d/mirrorlist

[lib32]
Include = /etc/pacman.d/mirrorlist

# Arch
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist

# Artix User Repository of Init Scripts
[auris]
SigLevel = Required
Server = https://auris.artixlinux.org/api/packages/auris/arch/$repo/$arch
EOF

# Step 3: sync all databases with the new config
artix-chroot /mnt /usr/bin/pacman -Syy

echo ">>> Install kernel and other stuff"
artix-chroot /mnt /usr/bin/pacman -S --needed --noconfirm linux-cachyos qemu-guest-agent-dinit paru

echo ">>> Initramfs"

artix-chroot /mnt /bin/bash -c '
    sed -i "/^HOOKS=/ {
        s/\<fsck\>//g
        s/  */ /g
        s/( /(/g
        s/ )/)/g
    }" /etc/mkinitcpio.conf

    mkinitcpio -P
'

echo ">>> GRUB (UEFI)"

artix-chroot /mnt /usr/bin/grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id="$BOOTLOADER_ID" \
    --removable \
    --no-nvram

artix-chroot /mnt /usr/bin/grub-mkconfig \
    -o /boot/grub/grub.cfg

# ----------------------------- SERVICES ---------------------------------------

echo ">>> Enabling services"

artix-chroot /mnt /bin/bash -c '
    mkdir -p /etc/dinit.d/boot.d
    ln -sf ../NetworkManager /etc/dinit.d/boot.d/NetworkManager
    ln -sf ../elogind /etc/dinit.d/boot.d/elogind
    ln -sf ../qemu-ga /etc/dinit.d/boot.d/qemu-ga
	ln -sf ../sshd /etc/dinit.d/boot.d/sshd
'

# ----------------------------- FINISH ----------------------------------------

echo ">>> Unmounting"

umount -R /mnt

echo
echo "Installation complete!"
echo "Remove the installation media before rebooting."

read -rp "Reboot now? [y/N] " answer

if [[ $answer =~ ^[Yy]$ ]]; then
    reboot
fi

exit 0