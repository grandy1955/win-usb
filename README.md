# win-usb: Windows installation USB on Linux with wimlib

`make-win-usb.sh` turns an official Windows 10 or Windows 11 ISO into a bootable
installer stick, entirely from Linux, with nothing but standard packages. No Rufus,
no Windows machine, no `woeusb`, no Ventoy.

```bash
sudo ./make-win-usb.sh --list                                  # find the stick
sudo ./make-win-usb.sh /dev/sdX ~/Downloads/Win11.iso          # dry run, changes nothing
sudo ./make-win-usb.sh /dev/sdX ~/Downloads/Win11.iso --yes    # erase /dev/sdX and build
```

The result is a plain GPT + FAT32 stick that boots on any UEFI machine, including
with Secure Boot enabled, and installs exactly what the ISO contains.

## Contents

- [Why `dd` does not work for Windows ISOs](#why-dd-does-not-work-for-windows-isos)
- [How the script solves it](#how-the-script-solves-it)
- [What ends up on the stick](#what-ends-up-on-the-stick)
- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
- [Safety checks](#safety-checks)
- [Booting and installing Windows](#booting-and-installing-windows)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Doing it by hand](#doing-it-by-hand)
- [Script walkthrough](#script-walkthrough)

## Why `dd` does not work for Windows ISOs

Linux ISOs are "hybrid" images: the file carries a partition table and boot sector,
so writing it byte for byte to a stick with `dd` produces a bootable disk.
Windows ISOs are not hybrid. They are a plain UDF filesystem meant for a DVD, so a
`dd` copy gives you a stick with no partition table and no boot sector that firmware
does not recognise.

The obvious fix, "format the stick and copy the files", runs into a second problem:

- UEFI firmware boots removable media by looking for `EFI/BOOT/BOOTX64.EFI` on a
  **FAT32** partition. FAT32 is the only filesystem the UEFI specification
  requires firmware to read. NTFS sticks only boot on firmware that happens to ship
  an NTFS driver, which many do not.
- FAT32 cannot store a file larger than 4 GiB, and every current Windows ISO ships
  `sources/install.wim` at 4.5 to 7 GB.

Tools like Rufus and `woeusb` work around this by adding a tiny FAT32 partition with
a third-party NTFS driver (`UEFI:NTFS`) that chain-loads into an NTFS partition.
It works on most machines, but it is the part that breaks on picky firmware, and
Secure Boot may reject the unsigned driver.

## How the script solves it

The install image, `install.wim`, is a Windows Imaging Format archive. Microsoft's
own tooling supports **split WIM** files, a set of `install.swm`, `install2.swm`,
`install3.swm`, ... parts. Windows Setup looks for `sources/install.swm` when
`install.wim` is absent and transparently reads across the parts. Nothing else on the
ISO needs to change.

[wimlib](https://wimlib.net/) is an open-source implementation of the WIM format,
and `wimlib-imagex split` produces those parts on Linux. That turns the whole task
into something FAT32 can hold. The script:

1. Unmounts anything mounted from the target stick.
2. Mounts the ISO read-only on a loop device.
3. Wipes the stick, writes a GPT table with a single partition of type
   "Microsoft basic data", and formats it FAT32.
4. Copies every file from the ISO except `sources/install.wim` with `rsync`.
5. Runs `wimlib-imagex split install.wim install.swm 3800`, writing the parts
   straight to the stick. 3800 MB keeps each part safely under the 4 GiB limit.
6. Runs `sync` and waits until the kernel has flushed everything to the stick.
   This is the slow step: the copy is buffered in RAM, and a USB 2 stick only
   drains at 5 to 15 MB/s.
7. Remounts the stick read-only, checks that `boot.wim` and the install image are
   present, unmounts and ejects.

Two special cases are handled automatically:

- If the ISO ships `install.esd` instead of `install.wim` (Media Creation Tool ISOs
  and some MSDN downloads), the script first runs `wimlib-imagex export` to convert
  it to a normal WIM in `/var/tmp`, because ESD files use "solid" LZMS compression
  that cannot be split in place. This needs free space equal to the ESD size and
  takes several minutes of CPU time.
- If the install image is already under 4 GiB, it is copied unchanged.

## What ends up on the stick

```
/dev/sdX            GPT
└── /dev/sdX1       FAT32, label WINUSB, whole disk
    ├── autorun.inf
    ├── bootmgr, bootmgr.efi, bootmgfw.efi
    ├── boot/                 BCD store, boot fonts, memtest
    ├── efi/
    │   ├── boot/bootx64.efi  what UEFI firmware loads
    │   └── microsoft/boot/   BCD, fonts
    ├── sources/
    │   ├── boot.wim          Windows PE that runs Setup
    │   ├── install.swm       ┐
    │   ├── install2.swm      │ the split install image
    │   └── ...               ┘
    ├── support/
    └── setup.exe
```

Because it is an ordinary FAT32 volume you can mount it on any OS afterwards and
add drivers, an `autounattend.xml`, or other files. Keep each added file under 4 GiB.

## Requirements

| Tool | Fedora / RHEL | Debian / Ubuntu | Arch |
|------|---------------|-----------------|------|
| `wimlib-imagex` | `wimlib-utils` | `wimtools` | `wimlib` |
| `mkfs.fat` | `dosfstools` | `dosfstools` | `dosfstools` |
| `sfdisk`, `wipefs`, `lsblk`, `blockdev` | `util-linux` | `util-linux` | `util-linux` |
| `rsync` | `rsync` | `rsync` | `rsync` |
| `partprobe` | `parted` | `parted` | `parted` |
| `udevadm` | `systemd-udev` | `udev` | `systemd` |

Install on Fedora, for example:

```bash
sudo dnf install wimlib-utils dosfstools rsync parted
```

The script checks for every tool at start and names the missing one.

Hardware: any USB stick at least ~10 % larger than the ISO. A 16 GB stick is enough
for every current Windows 11 ISO (about 7 to 8 GB). Faster sticks (USB 3, or a USB
SSD) cut the build time from 20 minutes to 2 or 3.

## Usage

### 1. Get the ISO

Download from Microsoft directly: <https://www.microsoft.com/software-download/windows11>
(choose "Download Windows 11 Disk Image (ISO)"). Verify the SHA-256 shown on that
page:

```bash
sha256sum ~/Downloads/Win11_25H2_English_x64.iso
```

Official ISOs are Microsoft-signed and boot with Secure Boot enabled. Third-party
"tweaked" ISOs may not.

### 2. Find the stick

```bash
$ sudo ./make-win-usb.sh --list
/dev/sdc        14,5G  Verbatim STORE N GO
```

Only devices attached over USB are listed. If you are not sure which is which,
unplug the stick, run `--list` again, and see which entry disappears.

### 3. Dry run

```bash
$ sudo ./make-win-usb.sh /dev/sdc ~/Downloads/Win11_25H2_English_x64.iso
Target disk (ALL DATA WILL BE ERASED):
NAME    SIZE FSTYPE LABEL      MOUNTPOINT             VENDOR   MODEL
sdc    14,5G                                          Verbatim STORE N GO
├─sdc1 14,5G ntfs   NTFS       /run/media/gn/NTFS
└─sdc2    1M vfat   RUFUS_BOOT /run/media/gn/RUFUS_BOOT
ISO:        /home/gn/Downloads/Win11_25H2_English_x64.iso (8095 MB)
Table:      gpt, one FAT32 partition, label WINUSB, .swm parts of 3800 MB

Dry run. Add --yes to proceed.
```

Nothing is written without `--yes`. Read the disk name and size carefully.

### 4. Build

```bash
sudo ./make-win-usb.sh /dev/sdc ~/Downloads/Win11_25H2_English_x64.iso --yes
```

Progress is printed for each stage. The final "flushing writes" stage can look
stuck for several minutes on a slow stick. It is not; wait for the `done` line
before unplugging.

## Options

| Option | Effect |
|--------|--------|
| `--list` | List USB disks and exit. Needs no other arguments. |
| `--yes` | Actually erase and write. Without it the script only prints its plan. |
| `--mbr` | Write an MBR (DOS) partition table instead of GPT. Some older UEFI implementations only offer sticks with an MBR table in the boot menu. Try this if the stick does not appear. |
| `--label NAME` | FAT32 volume label, 11 characters max. Default `WINUSB`. |
| `--split MB` | Size of each `.swm` part in MB. Default 3800. Must stay below 4096. |
| `--keep-tmp` | Keep the temporary `install.wim` made from an `install.esd` in `/var/tmp` for reuse. |
| `-h`, `--help` | Print the usage header. |

Arguments starting with `/dev/` are taken as the target disk, anything else as the
ISO path, so their order does not matter.

## Safety checks

Wiping the wrong disk is the one way this can go badly, so the script refuses to run if:

- it is not root;
- no `--yes` was given (dry run instead);
- the target is a partition (`/dev/sdc1`) rather than a whole disk (`/dev/sdc`);
- the target is not attached via USB (internal SATA/NVMe disks are never touched);
- the stick is smaller than the ISO plus about 10 % headroom;
- the ISO does not mount, or has no `sources/boot.wim` (not a Windows install ISO);
- the partition does not appear after partitioning (flaky stick or hub).

Every partition of the target is unmounted before it is wiped, and temporary mount
points and the loop device are cleaned up on exit, including on failure.

## Booting and installing Windows

1. Plug the stick in and open the firmware boot menu while powering on. The key is
   usually F12, F11, F8, F2 or Esc depending on the vendor.
2. Choose the entry that starts with `UEFI:` followed by the stick's name. If there
   is also a plain entry without `UEFI:`, that one is legacy boot and will not work.
3. Windows Setup starts from `boot.wim`. Choose language, then "Install now".
4. When asked where to install, delete or format the partitions as needed. Setup
   creates the EFI, MSR and recovery partitions itself on an empty disk.

Windows 11 checks for TPM 2.0, Secure Boot capability, 4 GB of RAM and a supported
CPU. On unsupported hardware, at the first Setup screen press `Shift+F10` for a
command prompt, run `regedit`, and under `HKEY_LOCAL_MACHINE\SYSTEM\Setup` create a
key `LabConfig` with DWORD values `BypassTPMCheck`, `BypassSecureBootCheck` and
`BypassRAMCheck` set to `1`. Then close regedit and continue.

## Limitations

- **UEFI only.** Legacy BIOS boot needs a boot sector that `ms-sys` writes, which
  most distributions do not package. Windows 11 does not support legacy boot anyway,
  and every machine sold since about 2012 supports UEFI.
- **x64 and ARM64.** The script accepts ISOs with `bootx64.efi` or `bootaa64.efi`.
  The stick will only boot on the matching architecture.
- **One ISO per stick.** For a multi-boot stick use Ventoy instead. This script
  exists for the machines where Ventoy or NTFS-based sticks do not boot.
- **Windows 7 ISOs** are UEFI-bootable only in their x64 edition and need
  `bootx64.efi` extracted by hand from `install.wim`. Not handled.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| Stick missing from the boot menu | CSM/legacy-only mode, Fast Boot, or firmware that dislikes GPT sticks. Enable UEFI boot, disable Fast Boot, or rebuild with `--mbr`. |
| "Secure Boot Violation" | Unofficial ISO with unsigned boot files. Use a Microsoft ISO, or disable Secure Boot for the install. |
| "Windows cannot open the required file install.wim" or error 0x80070570 | Incomplete copy, usually from unplugging before the final sync. Rebuild. |
| `mount: wrong fs type` when mounting the ISO | Corrupt download or not an ISO. Check the SHA-256. |
| `partition /dev/sdX1 did not appear` | Stick or hub dropped off the bus. Plug directly into the machine and retry. |
| `disk too small` | The ISO plus headroom does not fit. Use a 16 GB or larger stick. |
| Build takes 30+ minutes | Slow stick. Cheap USB 2 sticks write at 5 MB/s. Nothing to fix except a better stick. |
| `install.esd` conversion fails with no space | `/var/tmp` needs free space equal to the ESD size. Set `TMPDIR=/some/big/dir` before running. |

## Doing it by hand

The script is a wrapper around a dozen commands. If you prefer to see every step:

```bash
ISO=~/Downloads/Win11.iso
DEV=/dev/sdX            # whole disk, double-check with lsblk

sudo umount ${DEV}?* 2>/dev/null
sudo wipefs -a $DEV
printf 'label: gpt\n,,EBD0A0A2-B9E5-4433-87C0-68B6B72699C7,\n' | sudo sfdisk $DEV
sudo partprobe $DEV
sudo mkfs.fat -F32 -n WINUSB ${DEV}1

sudo mkdir -p /mnt/iso /mnt/usb
sudo mount -o loop,ro $ISO /mnt/iso
sudo mount ${DEV}1 /mnt/usb

sudo rsync -rt --no-perms --info=progress2 --exclude=sources/install.wim /mnt/iso/ /mnt/usb/
sudo wimlib-imagex split /mnt/iso/sources/install.wim /mnt/usb/sources/install.swm 3800

sync
sudo umount /mnt/usb /mnt/iso
```

The GUID `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` is the GPT type for "Microsoft basic
data". For MBR, replace the `sfdisk` line with `printf 'label: dos\n,,0c,*\n'`
(type `0c` is FAT32 LBA, `*` sets the boot flag).

## Script walkthrough

For anyone modifying `make-win-usb.sh`, the file is organised top to bottom as:

| Section | What it does |
|---------|--------------|
| Argument parsing | A single `while/case` loop. `/dev/*` is the disk, `*.iso` or any other bare word is the ISO. |
| `--list` | Parses `lsblk -P` key/value output and prints only `TRAN=usb` disks. |
| Sanity checks | Tool presence, root, block device, whole-disk, USB transport, ISO exists, label length, disk size versus ISO size. Computes the partition name (`sdX1` versus `nvme0n1p1` style). |
| Plan and dry-run gate | Prints the target and exits unless `--yes`. |
| Mounts and cleanup | Creates temp mount points under `/mnt`, installs an `EXIT` trap that unmounts and deletes them and any temporary WIM. |
| Partition and format | `wipefs`, `sfdisk` from a heredoc, `partprobe`, `udevadm settle`, `mkfs.fat`. |
| Copy | `rsync` excluding the install image, then either `cp`, or `export` + `split`, or `split` alone depending on image type and size. |
| Finish | `sync`, unmount, read-only remount to verify, `eject`. |

Exit codes: `0` success or dry run, `1` any failed check or failed step (message on stderr).

## License

MIT. Use it, ship it, change it.
