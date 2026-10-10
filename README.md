# debian-rescue-toolkit

Custom ultra-lightweight **Debian 12 (Bookworm) Live CLI OS** tailored for hardware diagnostics, storage health monitoring, and network benchmarking.

Single hybrid ISO supporting both **Legacy BIOS** and **UEFI 64-bit**.

---

## 🚀 Pre-installed Features & Tools

- **Hard Disk Sentinel Linux 64-bit (`hdsentinel`):** Fast storage health, temperature, and lifetime diagnostics for HDD/SSD.
- **Network Helper (`setip`):** Interactive script to quickly assign Static IP (IP/CIDR, Gateway, DNS) or trigger DHCP on any LAN interface.
- **smartctl (`smartmontools`):** Low-level S.M.A.R.T. disk inspection (`smartctl -a /dev/sdX`).
- **iperf3:** Network bandwidth and throughput testing (`iperf3 -c <server_ip>`).
- **Memtest86+ (v8.10 in GRUB):** Boot directly into memory testing from the GRUB boot menu without loading the OS.
- **NVMe / Network / PCI Diagnostics:** `nvme-cli`, `ethtool`, `pciutils` (`lspci`), `usbutils` (`lsusb`), `htop`, `parted`.
- **Dual Boot Options in GRUB:**
  - *RAM Boot (Toram):* Copies the entire OS into RAM upon booting so you can unplug the USB drive immediately.
  - *Standard Live Mode.*
- **SSH Server Enabled:** Pre-configured `openssh-server`, auto-starts on boot.
  - User: `root`
  - Password: `root`
  - Port: `22` (PermitRootLogin & PasswordAuthentication enabled)
- **Auto-Login:** Instant root access on TTY1 console without credentials prompt.
- **Auto-DHCP:** Automatic network IP lease upon Ethernet plug-in.

---

## 📥 Download ISO

Download the latest bootable ISO from [GitHub Releases](https://github.com/magdoarch/debian-rescue-toolkit/releases).

- File: `debian-rescue-toolkit.iso` (~255 MB)

---

## 💾 How to Flash to USB

### Option 1: Ventoy (Recommended)
Simply copy `debian-rescue-toolkit.iso` to your Ventoy flash drive.

### Option 2: Direct DD (Linux / Arch)
```bash
sudo dd if=debian-rescue-toolkit.iso of=/dev/sdX bs=4M status=progress oflag=sync
```
*(Replace `/dev/sdX` with your target USB drive).*

---

## 🛠️ How to Build from Scratch

Requirements: Debian or Ubuntu host with `debootstrap`, `xorriso`, `squashfs-tools`, `grub-pc-bin`, `grub-efi-amd64-bin`, `mtools`.

```bash
git clone https://github.com/magdoarch/debian-rescue-toolkit.git
cd debian-rescue-toolkit
chmod +x build.sh
sudo ./build.sh
```

The resulting ISO will be generated inside `output/debian-rescue-toolkit.iso`.
