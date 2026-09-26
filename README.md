# Windows installation USB on Linux with wimlib

`make-win-usb.sh` turns any Windows 10/11 ISO into a UEFI-bootable installer stick
using only standard Linux tools. It is the reliable alternative to `dd` (which does
not work for Windows ISOs) and to `woeusb`/NTFS tricks that many firmwares refuse to boot.

## How it works

Windows ISOs contain one file, `sources/install.wim`, that is usually larger than 4 GB.
FAT32 cannot hold a file that big, but FAT32 is the only filesystem every UEFI
firmware can boot from. The script therefore:

1. Wipes the stick and writes a GPT table with one FAT32 partition.
2. Copies everything from the ISO except `install.wim`.
3. Splits `install.wim` into 3800 MB `install.swm`, `install2.swm`, ... parts using
   `wimlib-imagex split`. Windows Setup reads split images natively.
4. Syncs, re-mounts read-only to verify, and ejects the stick.

If the ISO ships `install.esd` (some Media Creation Tool ISOs), it is first exported
to a temporary `install.wim`, because solid ESD images cannot be split directly.
An `install.wim` or `install.esd` that is already under 4 GB is copied as-is.

## Requirements

| Tool | Package (Fedora) | Package (Debian/Ubuntu) | Package (Arch) |
|------|------------------|-------------------------|----------------|
| `wimlib-imagex` | `wimlib-utils` | `wimtools` | `wimlib` |
| `mkfs.fat` | `dosfstools` | `dosfstools` | `dosfstools` |
| `sfdisk`, `wipefs`, `lsblk` | `util-linux` | `util-linux` | `util-linux` |
| `rsync` | `rsync` | `rsync` | `rsync` |
| `partprobe` | `parted` | `parted` | `parted` |

The stick must be at least about 10 % larger than the ISO. 16 GB is enough for every
current Windows 11 ISO.

## Usage

```bash
# 1. Find the stick
sudo ./make-win-usb.sh --list

# 2. Dry run: prints the disk that would be erased, changes nothing
sudo ./make-win-usb.sh /dev/sdX ~/Downloads/Win11.iso

# 3. Build (erases /dev/sdX completely)
sudo ./make-win-usb.sh /dev/sdX ~/Downloads/Win11.iso --yes
```

Expect 10 to 20 minutes on a USB 2 stick, a few minutes on USB 3. The "flushing
writes" step at the end looks idle but is the kernel finishing the copy. Do not unplug
before the script says done.

### Options

| Option | Effect |
|--------|--------|
| `--mbr` | MBR partition table instead of GPT. Try this if an old UEFI firmware does not list the stick. |
| `--label NAME` | FAT32 volume label, 11 characters max. Default `WINUSB`. |
| `--split MB` | Size of each `.swm` part. Default 3800. Must stay below 4096. |
| `--keep-tmp` | Keep the temporary `install.wim` produced from an `install.esd`. |

### Safety checks built in

- Refuses to run on a partition, on a non-USB device, or without `--yes`.
- Refuses if the stick is smaller than the ISO plus headroom.
- Refuses ISOs that do not contain `sources/boot.wim`.
- Unmounts every partition of the target before touching it.

## Booting and installing

1. Plug the stick in, enter the firmware boot menu (usually F12, F11, F8 or Esc)
   and pick the entry named `UEFI: <stick name>`. Pick the UEFI entry, not the plain one.
2. If Secure Boot blocks it, the ISO is not an official one. Official Microsoft ISOs
   are signed and boot with Secure Boot enabled.
3. Windows 11 requires TPM 2.0 and Secure Boot capability on the target machine.
   To bypass on unsupported hardware, at the first setup screen press Shift+F10 and
   in the registry under `HKLM\SYSTEM\Setup\LabConfig` create the DWORD values
   `BypassTPMCheck`, `BypassSecureBootCheck` and `BypassRAMCheck` set to 1.

## Limitations

- UEFI only. Legacy BIOS boot would need an NTFS or FAT32 boot sector written by
  `ms-sys`, which is not packaged by most distributions, and Windows 11 does not
  support legacy boot anyway.
- Windows ARM64 ISOs work the same way (the script accepts `bootaa64.efi`), but the
  target machine must be an ARM64 UEFI system.
- Files added by hand later, such as drivers or an `autounattend.xml`, go on the
  same FAT32 partition. Keep each file under 4 GB.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| Stick not offered in the boot menu | Fast Boot or CSM-only mode in firmware. Enable UEFI boot, disable Fast Boot, or rebuild with `--mbr`. |
| "Windows cannot open the required file install.wim" | Copy was interrupted. Rebuild, and wait for the final sync. |
| `mount: ... wrong fs type` on the ISO | File is not a Windows ISO or the download is corrupt. Verify the SHA-256 against Microsoft's page. |
| `partition /dev/sdX1 did not appear` | Flaky stick or hub. Replug directly into the machine and retry. |
| Build very slow | Cheap sticks write at 5 to 10 MB/s. Nothing to fix except a faster stick. |

## Doing it by hand

The script is a thin wrapper. The equivalent manual steps, for reference:

```bash
sudo umount /dev/sdX*
sudo wipefs -a /dev/sdX
printf 'label: gpt\n,,EBD0A0A2-B9E5-4433-87C0-68B6B72699C7,\n' | sudo sfdisk /dev/sdX
sudo mkfs.fat -F32 -n WINUSB /dev/sdX1
sudo mkdir -p /mnt/iso /mnt/usb
sudo mount -o loop,ro Win11.iso /mnt/iso
sudo mount /dev/sdX1 /mnt/usb
sudo rsync -rt --no-perms --exclude=sources/install.wim /mnt/iso/ /mnt/usb/
sudo wimlib-imagex split /mnt/iso/sources/install.wim /mnt/usb/sources/install.swm 3800
sync; sudo umount /mnt/usb /mnt/iso
```
