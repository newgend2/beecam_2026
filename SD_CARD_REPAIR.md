# BeeCam SD Card DATA Repair

Use this when `transfer_beecam.sh` reports a cleanup error like:

```text
rm: cannot remove '/media/wlab/DATA/...': Directory not empty
```

Also use it when `df -h` still shows the DATA partition as partly full after
transfer, but normal `ls` does not show image data. Check `ls -a`; old deleted
files may be in `.Trash-1000`.

These commands repair the SD card's `DATA` partition. Do not repair the whole
SD device.

## 1. Confirm the transfer archive exists

Before repairing, make sure the camera zip file was created on the backup SSD.
The transfer script verifies the zip before it starts deleting from the SD card.

## 2. Find the DATA partition

Insert the SD card into the Linux laptop and run:

```bash
lsblk -f
```

The SD card should show up as `/dev/mmcblk0` with this layout:

```text
/dev/mmcblk0p1  bootfs
/dev/mmcblk0p2  rootfs
/dev/mmcblk0p3  DATA   exfat
```

Only repair the `DATA` partition:

```text
/dev/mmcblk0p3
```

Do not repair `/dev/mmcblk0`, `/dev/mmcblk0p1`, or `/dev/mmcblk0p2`.

## 3. Unmount DATA

If it mounted at `/media/wlab/DATA`, run:

```bash
sudo umount /media/wlab/DATA
```

If that path does not exist, use the mount path shown by `lsblk -f`.

## 4. Check without changing anything

```bash
sudo fsck.exfat -n /dev/mmcblk0p3
```

If `fsck.exfat` is missing:

```bash
sudo apt install exfatprogs
```

## 5. Repair

Automatic repair:

```bash
sudo fsck.exfat -a /dev/mmcblk0p3
```

If it asks for decisions or automatic repair does not fix it, use interactive
repair:

```bash
sudo fsck.exfat -r /dev/mmcblk0p3
```

## 6. Reinsert and clean leftovers

Unplug and reinsert the SD card, then remove any leftover transferred data:

```bash
rm -rf /media/wlab/DATA/images_and_labels
rm -rf /media/wlab/DATA/logs
rm -rf /media/wlab/DATA/update_backups
rm -rf /media/wlab/DATA/.Trash-*
mkdir -p /media/wlab/DATA/images_and_labels /media/wlab/DATA/logs
sync
```

## 7. Eject before removing

```bash
sudo umount /media/wlab/DATA
```

Then remove the SD card.
