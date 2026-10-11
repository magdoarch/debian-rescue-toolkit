#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Custom Debian 12 (Bookworm) Live OS Builder
# Tools: HDSentinel, smartctl, iperf3, Memtest86+ in GRUB (BIOS + UEFI)
# ==============================================================================

PROJECT_DIR="/root/CODE/custom-debian-live"
WORK_DIR="${PROJECT_DIR}/work"
CHROOT_DIR="${WORK_DIR}/chroot"
IMAGE_DIR="${WORK_DIR}/image"
ASSETS_DIR="${PROJECT_DIR}/assets"
OUTPUT_DIR="${PROJECT_DIR}/output"
ISO_NAME="debian-rescue-toolkit.iso"

DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_RELEASE="bookworm"

echo "=== [1/6] Cleaning and preparing workspace ==="
# Unmount safely if previous run was interrupted
for m in dev/pts dev proc sys; do
    if mountpoint -q "${CHROOT_DIR}/${m}" 2>/dev/null; then
        umount -lf "${CHROOT_DIR}/${m}" || true
    fi
done

rm -rf "${WORK_DIR}"
mkdir -p "${CHROOT_DIR}" "${IMAGE_DIR}" "${OUTPUT_DIR}" "${ASSETS_DIR}"

echo "=== [2/6] Running debootstrap (Debian ${DEBIAN_RELEASE}) ==="
debootstrap --arch=amd64 \
    --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    --variant=minbase \
    "${DEBIAN_RELEASE}" "${CHROOT_DIR}" "${DEBIAN_MIRROR}"

echo "=== [3/6] Configuring chroot environment & packages ==="
# Mount kernel virtual filesystems
mount --bind /dev "${CHROOT_DIR}/dev"
mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"
mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sysfs "${CHROOT_DIR}/sys"

# Setup sources.list
cat <<EOF > "${CHROOT_DIR}/etc/apt/sources.list"
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

# Hostname & hosts
echo "rescue-live" > "${CHROOT_DIR}/etc/hostname"
cat <<EOF > "${CHROOT_DIR}/etc/hosts"
127.0.0.1   localhost rescue-live
::1         localhost ip6-localhost ip6-loopback
EOF

# Prevent interactive prompts during apt & clear TMPDIR so chroot uses /tmp
export DEBIAN_FRONTEND=noninteractive
unset TMPDIR
export TMP=/tmp
export TEMP=/tmp

chroot "${CHROOT_DIR}" apt-get update
chroot "${CHROOT_DIR}" apt-get install -y --no-install-recommends \
    linux-image-amd64 \
    live-boot \
    systemd-sysv \
    openssh-server \
    smartmontools \
    iperf3 \
    ethtool \
    pciutils \
    usbutils \
    nvme-cli \
    iproute2 \
    iputils-ping \
    isc-dhcp-client \
    curl \
    wget \
    nano \
    htop \
    less \
    kmod \
    dosfstools \
    parted \
    util-linux

# Set root password to empty or 'root' & auto-login on tty1
chroot "${CHROOT_DIR}" bash -c "echo 'root:root' | chpasswd"

# Enable SSH root login with password
mkdir -p "${CHROOT_DIR}/etc/ssh/sshd_config.d"
cat <<EOF > "${CHROOT_DIR}/etc/ssh/sshd_config.d/permit_root.conf"
PermitRootLogin yes
PasswordAuthentication yes
EOF
chroot "${CHROOT_DIR}" systemctl enable ssh

mkdir -p "${CHROOT_DIR}/etc/systemd/system/getty@tty1.service.d"
cat <<EOF > "${CHROOT_DIR}/etc/systemd/system/getty@tty1.service.d/override.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF

# Install HDSentinel binary
cp "${ASSETS_DIR}/HDSentinel" "${CHROOT_DIR}/usr/local/bin/hdsentinel"
chmod 755 "${CHROOT_DIR}/usr/local/bin/hdsentinel"

# Install setip helper script
cat <<'EOF' > "${CHROOT_DIR}/usr/local/bin/setip"
#!/usr/bin/env bash
set -e

echo "=== Network Interface Configuration ==="
echo "Daftar interface yang tersedia:"
ip -br link show | awk '{print " - " $1 " (" $2 ")"}'
echo "----------------------------------------"

# Deteksi interface ethernet/lan pertama selain loopback
DEFAULT_IFACE=$(ip -br link | awk '$1 !~ /^lo/ {print $1; exit}')

read -rp "Pilih Interface [default: ${DEFAULT_IFACE}]: " IFACE
IFACE=${IFACE:-$DEFAULT_IFACE}

if [ -z "$IFACE" ]; then
    echo "Error: Interface tidak ditemukan!"
    exit 1
fi

echo ""
echo "Pilih Mode:"
echo " 1) Static IP (Manual IP, Gateway, DNS)"
echo " 2) DHCP (Otomatis)"
read -rp "Pilihan [1/2, default: 1]: " MODE
MODE=${MODE:-1}

if [ "$MODE" = "2" ]; then
    echo "Mengaktifkan DHCP pada interface $IFACE..."
    dhclient -r "$IFACE" 2>/dev/null || true
    ip addr flush dev "$IFACE"
    ip link set dev "$IFACE" up
    dhclient "$IFACE"
    echo "✓ Selesai! Info IP saat ini:"
    ip -br addr show "$IFACE"
    exit 0
fi

echo ""
read -rp "Masukkan IP & CIDR (contoh: 192.168.1.50/24): " IP_CIDR
read -rp "Masukkan Gateway (contoh: 192.168.1.1, kosongkan jika tanpa GW): " GW
read -rp "Masukkan DNS [default: 1.1.1.1 8.8.8.8]: " DNS
DNS=${DNS:-"1.1.1.1 8.8.8.8"}

if [ -z "$IP_CIDR" ]; then
    echo "Error: IP tidak boleh kosong!"
    exit 1
fi

echo ""
echo "Menerapkan konfigurasi static IP ke $IFACE..."

# Matikan dhclient jika sedang running pada interface ini
dhclient -r "$IFACE" 2>/dev/null || true

# Set link up & flush alamat lama
ip link set dev "$IFACE" up
ip addr flush dev "$IFACE"

# Pasang IP baru
ip addr add "$IP_CIDR" dev "$IFACE"

# Pasang default gateway jika diisi
if [ -n "$GW" ]; then
    ip route add default via "$GW" dev "$IFACE" 2>/dev/null || ip route replace default via "$GW" dev "$IFACE"
fi

# Update /etc/resolv.conf
if [ -n "$DNS" ]; then
    > /etc/resolv.conf
    for d in $DNS; do
        echo "nameserver $d" >> /etc/resolv.conf
    done
fi

echo "✓ IP Berhasil dikonfigurasi!"
echo "----------------------------------------"
ip -br addr show "$IFACE"
if [ -n "$GW" ]; then
    echo "Gateway: $GW"
fi
echo "DNS: $DNS"
echo "----------------------------------------"
EOF
chmod 755 "${CHROOT_DIR}/usr/local/bin/setip"

# Setup Welcome MOTD
cat <<'EOF' > "${CHROOT_DIR}/etc/motd"

============================================================
       DEBIAN RESCUE & BENCHMARK TOOLKIT (LIVE CLI)
============================================================
 SSH Access:
   - User     : root
   - Password : root
   - Port     : 22

 Quick Commands:
   - setip                  : Interactive helper to set Static IP or DHCP
   - hdsentinel             : Run Hard Disk Sentinel health report
   - smartctl -a /dev/sdX   : Detailed SMART health report
   - iperf3 -c <ip>         : Run network bandwidth test
   - nvme list              : List NVMe SSD drives
   - ethtool <interface>    : Check network link speed/duplex
============================================================

EOF

# Clean apt cache inside chroot
chroot "${CHROOT_DIR}" apt-get clean
rm -rf "${CHROOT_DIR}/var/lib/apt/lists/"* "${CHROOT_DIR}/tmp/"*

# Unmount filesystems safely
umount -lf "${CHROOT_DIR}/sys"
umount -lf "${CHROOT_DIR}/proc"
umount -lf "${CHROOT_DIR}/dev/pts"
umount -lf "${CHROOT_DIR}/dev"

echo "=== [4/6] Creating SquashFS filesystem ==="
mkdir -p "${IMAGE_DIR}/live"
mksquashfs "${CHROOT_DIR}" "${IMAGE_DIR}/live/filesystem.squashfs" -comp xz -wildcards

# Copy kernel & initrd to live image
KERNEL_FILE=$(ls -1 "${CHROOT_DIR}/boot/vmlinuz-"* | sort -V | tail -n 1)
INITRD_FILE=$(ls -1 "${CHROOT_DIR}/boot/initrd.img-"* | sort -V | tail -n 1)

cp "${KERNEL_FILE}" "${IMAGE_DIR}/live/vmlinuz"
cp "${INITRD_FILE}" "${IMAGE_DIR}/live/initrd.img"

# Copy Memtest86+ binary
mkdir -p "${IMAGE_DIR}/boot"
cp "${ASSETS_DIR}/mt86p_810_x86_64" "${IMAGE_DIR}/boot/memtest86+.bin"

echo "=== [5/6] Setting up GRUB Bootloader (BIOS + UEFI) ==="
mkdir -p "${IMAGE_DIR}/boot/grub"

# Early configuration to find real boot medium and set prefix
cat <<'EOF' > "${IMAGE_DIR}/boot/grub/early-grub.cfg"
search --no-floppy --set=root --file /live/vmlinuz
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EOF

cat <<'EOF' > "${IMAGE_DIR}/boot/grub/grub.cfg"
# Locate the root filesystem device
search --no-floppy --set=root --file /live/vmlinuz
set prefix=($root)/boot/grub

# Preload modules
insmod linux
insmod reboot
insmod halt

set default="0"
set timeout=5

insmod font
if loadfont /boot/grub/fonts/unicode.pf2 ; then
    insmod gfxterm
    set gfxmode=auto
    terminal_output gfxterm
fi

menuentry "Debian Live (RAM Boot - Toram)" {
    search --no-floppy --set=root --file /live/vmlinuz
    linux /live/vmlinuz boot=live toram components quiet splash
    initrd /live/initrd.img
}

menuentry "Debian Live (Standard)" {
    search --no-floppy --set=root --file /live/vmlinuz
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "Memory Test (Memtest86+ v8.10)" {
    search --no-floppy --set=root --file /boot/memtest86+.bin
    linux /boot/memtest86+.bin
}

menuentry "Reboot" {
    insmod reboot
    reboot
}

menuentry "Poweroff" {
    insmod halt
    halt
}
EOF

# Copy GRUB runtime modules so dynamic commands (reboot, halt, etc.) work without error
mkdir -p "${IMAGE_DIR}/boot/grub/i386-pc"
cp -r /usr/lib/grub/i386-pc/*.mod "${IMAGE_DIR}/boot/grub/i386-pc/"
cp -r /usr/lib/grub/i386-pc/*.lst "${IMAGE_DIR}/boot/grub/i386-pc/"

mkdir -p "${IMAGE_DIR}/boot/grub/x86_64-efi"
cp -r /usr/lib/grub/x86_64-efi/*.mod "${IMAGE_DIR}/boot/grub/x86_64-efi/"
cp -r /usr/lib/grub/x86_64-efi/*.lst "${IMAGE_DIR}/boot/grub/x86_64-efi/"

# Copy unicode font if available
mkdir -p "${IMAGE_DIR}/boot/grub/fonts"
if [ -f /usr/share/grub/unicode.pf2 ]; then
    cp /usr/share/grub/unicode.pf2 "${IMAGE_DIR}/boot/grub/fonts/"
fi

# Build EFI image
mkdir -p "${IMAGE_DIR}/EFI/BOOT"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="${IMAGE_DIR}/EFI/BOOT/BOOTX64.EFI" \
    --install-modules="linux normal iso9660 search search_fs_file efi_gop efi_uga reboot halt font gfxterm test" \
    --modules="linux normal iso9660 search search_fs_file reboot halt font gfxterm" \
    --locales="" \
    --fonts="" \
    "boot/grub/grub.cfg=${IMAGE_DIR}/boot/grub/early-grub.cfg"

# Create EFI FAT image for hybrid ISO
dd if=/dev/zero of="${IMAGE_DIR}/boot/grub/efiboot.img" bs=1M count=8
mkfs.vfat "${IMAGE_DIR}/boot/grub/efiboot.img"
mmd -i "${IMAGE_DIR}/boot/grub/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "${IMAGE_DIR}/boot/grub/efiboot.img" "${IMAGE_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/

# Build BIOS image with grub-mkimage embedded with early search config
grub-mkimage \
    --format=i386-pc \
    --output="${IMAGE_DIR}/boot/grub/core.img" \
    --config="${IMAGE_DIR}/boot/grub/early-grub.cfg" \
    --prefix="/boot/grub" \
    iso9660 biosdisk search search_fs_file normal linux reboot halt test

cat /usr/lib/grub/i386-pc/cdboot.img "${IMAGE_DIR}/boot/grub/core.img" > "${IMAGE_DIR}/boot/grub/bios.img"

echo "=== [6/6] Generating Hybrid ISO (BIOS + UEFI) with xorriso ==="
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "DEBIAN_RESCUE" \
    -eltorito-boot boot/grub/bios.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --eltorito-catalog boot/grub/boot.cat \
    --grub2-boot-info \
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot \
    -e boot/grub/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "${OUTPUT_DIR}/${ISO_NAME}" \
    "${IMAGE_DIR}"

echo "============================================================"
echo " BUILD SUCCESSFUL!"
echo " ISO File: ${OUTPUT_DIR}/${ISO_NAME}"
ls -lh "${OUTPUT_DIR}/${ISO_NAME}"
echo "============================================================"
