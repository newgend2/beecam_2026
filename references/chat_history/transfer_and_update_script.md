# Check transfer/update scripts

> I was talking with a technician who was trying to transfer data from an sd card with [transfer_beecam.sh](transfer_beecam.sh) and they mentioned having a problem with some cameras. Keep in mind this is in the context of having updating all cameras with [offline_update](offline_update). I will paste the exact text the technician sent me below, and I would like you to check for any errors in the transfer script or offline update script which might have caused the behavior they are describing.
>
> "I went back to cam3 and the display was working great and the ssh was fine, until I exited out and tried to ssh a 2nd time, then it didn't work. So I replaced both the pi and the display and then it worked fine. It also booted up faster after replacing, so it seems like the pi was definitely the problem. I also downloaded the sd card in the VS Code terminal and it went smoothly.
>
> Where things got confusing were with cam2 and cam18. For cam2 everything downloaded fine, but when I put the sd card back in the display said it was still 12% full. I assumed it was a glitch because the screen was a little glitchy. But then the same thing happened for cam18. So it's downloading fine but it's not deleting anything off the sd card (even though the script says it ran successfully). So I went to check cam2 again and then it didn't let me ssh in.
>
> For cam18 I tried a couple more things, I tried running the download script from VS Code terminal first and then from the regular terminal but it didn't delete either time. Then I just manually deleted the /images_and_labels and /logs but when the display booted up again it had 0 pictures but the sd card % full still said 14%. I'm also not sure if you think I just shouldn't manually do anything bc it might be confusing later on?
>
> Also for cam18 after I ran the ./transfer_beecam.sh I noticed it had this message in the terminal, "Warning: /media/wlab/DATA/update_backups not found; skipping". And when i booted it up again it initially said "Err: 0SError" on the display before restarting and going back to the typical display.
>
> Overall I downloaded from 5 cameras today and 3 were completely normal, so I feel like the weirdness must be from cam2 and cam18 individually."

<details><summary>9 previous messages</summary>

> I’ll trace the transfer and offline update paths together, especially anything that computes free space, deletes files, or expects `DATA/update_backups`. Then I’ll sanity-check the reported symptoms against the actual script behavior before changing anything.
>
> The first pass already shows one important clue: the transfer script only removes directories after `unzip -t` passes, so if it printed `Deleted: images_and_labels/` then the delete command did run. I’m going deeper now into how the camera display calculates `SD %` and what the offline updater backs up/restores.
>
> I found one “this could absolutely confuse field checks” issue: the display’s `SD %` is real disk usage of `/data`, while the picture count is only today’s JPGs. So `0 pictures` and `14% full` can both be true if other files, filesystem overhead, stale mount state, or unflushed deletion metadata remain. I’m still checking for script-level holes that would let the transfer say success while the card did not actually commit the deletes.
>
> I don’t see offline_update deleting camera data or changing the storage path; it syncs `/home/pi/setup`, then the runtime updater backs up into `/data/update_backups` and overwrites the config. The weak spot is the transfer script’s cleanup: it trusts `rm -rf` and then immediately says “Done” without flushing/remount validation, which is exactly the sort of thing that can look successful in a terminal while an exFAT card later boots with old metadata. I’m going to harden that path now.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./transfer_beecam.sh` (+58 -3)
> - Wrote `./transfer_beecam.sh` (+6 -2)
>
> </details>
>
> A stronger explanation just surfaced: `12-14% full` is also about what a 10 GiB root partition often looks like when `/data` is not actually mounted. In that failure mode the transfer can correctly empty the SD card’s DATA partition, but the camera display reads disk usage from the root filesystem at `/data`, so it still reports 12-14%. I’m adding mountpoint checks so the updater/camera startup won’t silently use a plain `/data` directory.
>
> <details><summary>Edited 4 files</summary>
>
> - Wrote `./scripts/beecam-update-runtime.sh` (+10 -1)
> - Wrote `./scripts/beecam-init-data.sh` (+5 -0)
> - Wrote `./wittypi/afterStartup.sh` (+10 -1)
> - Wrote `./beecam/camera/beecam_capture_final.py` (+28 -0)
>
> </details>
>
> I tightened the camera side too. If a camera ever has `/data/configs` as a plain directory on the root filesystem, the updater will now refuse to run there, and the capture program will show an explicit DATA mount error instead of quietly reporting root-disk usage as “SD %”.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./offline_update` (+6 -0)
>
> </details>
</details>

I found two plausible script-level causes and hardened both.

Most likely diagnosis: `0 pictures` but still `12-14% full` strongly suggests `/data` was not mounted on cam2/cam18. In that case the display reports root filesystem usage at `/data`, which can naturally be around 12-14%, and deleting the SD card’s DATA partition would not change the displayed number. The old updater only checked that `/data/configs` existed, not that `/data` was actually mounted, so it could falsely succeed against a plain root-directory `/data`.

I changed:

- [transfer_beecam.sh](./transfer_beecam.sh:25): checks the source is a mounted filesystem, verifies cleanup, flushes writes with `sync`, prints before/after disk usage, and tells the tech to eject/unmount before removing the card.
- [offline_update](./offline_update:54): preflights that remote `/data` is mounted before updating.
- [scripts/beecam-update-runtime.sh](./scripts/beecam-update-runtime.sh:111): refuses to run if `/data` is not mounted.
- [beecam/camera/beecam_capture_final.py](./beecam/camera/beecam_capture_final.py:400): shows a clear `DATA not mounted` OLED error instead of silently using root storage.
- [scripts/beecam-init-data.sh](./scripts/beecam-init-data.sh:104) and [wittypi/afterStartup.sh](./wittypi/afterStartup.sh:12): add mount/startup guardrails.

The `Warning: /media/wlab/DATA/update_backups not found; skipping` message is not itself a failure. It just means there were no offline-update backups on that DATA partition at transfer time, or a previous successful transfer already removed them.

Validation passed: `bash -n`, Python compile for `beecam_capture_final.py`, and `git diff --check`.

> Should we force the data partition to mount on pi boot? Consult before making changes

<details><summary>1 previous message</summary>

> I’ll treat this as design review only: no edits. I’m going to re-check the current boot/mount wiring so the recommendation is grounded in what’s actually in the repo.
</details>

I would not force `/data` so hard that the Pi fails boot if the DATA partition is missing or dirty.

Better field behavior is: Pi boots, SSH stays available, but BeeCam refuses to run unless `/data` is mounted. That gives the technician a recoverable camera instead of one stuck in emergency boot or unavailable over SSH.

Current direction is the right one:

- `beecam-init-data.sh` creates/fstab-mounts `/data`, then now verifies it is actually mounted.
- `wittypi/afterStartup.sh` now refuses to start `beecam.service` if `/data` is not mounted.
- `beecam.service` has `Requires=beecam-init-data.service`.
- `beecam_capture_final.py` refuses to write to root `/data` if the mount is missing.
- `offline_update` and the runtime updater now check the mount too.

So my recommendation is: keep `nofail` in fstab, but force `/data` at the BeeCam service/application boundary. That prevents bad data writes while preserving SSH/debuggability.

The only extra change I’d consider later is adding a short mount retry/wait loop in `beecam-init-data.sh`, in case `/dev/mmcblk0p3` appears a little late after boot. But I would not remove `nofail` or make the whole Pi boot depend hard on `/data`.

> can you explain [beecam-init-data.service](systemd_services/beecam-init-data.service) and [beecam-update-runtime.sh](scripts/beecam-update-runtime.sh) do?

<details><summary>1 previous message</summary>

> I’ll explain the service wrapper and the updater separately, then how they connect in the field update flow. No changes.
</details>

[beecam-init-data.service](./systemd_services/beecam-init-data.service:1) is a tiny systemd wrapper. Its job is to run `/usr/local/sbin/beecam-init-data.sh` during normal boot.

What it means:

- `After=local-fs.target`: wait until normal local filesystems are handled.
- `Before=beecam.service`: run before the camera capture service.
- `Type=oneshot`: run one script, then exit.
- `ExecStart=/usr/local/sbin/beecam-init-data.sh`: the real logic lives in that installed script.
- `RemainAfterExit=yes`: after the script succeeds, systemd still considers this unit “active,” which helps dependent services treat initialization as complete.
- `WantedBy=multi-user.target`: if enabled, it runs during normal boot.

So conceptually: “before BeeCam starts, make sure the DATA partition exists, is formatted/mounted, and has expected folders.”

[beecam-update-runtime.sh](./scripts/beecam-update-runtime.sh:1) is the camera-side runtime updater. `offline_update` syncs this repo to `/home/pi/setup`, then runs this script over SSH.

It does this:

1. Verifies it is running as `pi`, not root.
2. Verifies required repo files exist.
3. Verifies `/data` is actually mounted, so it does not accidentally update root `/data`.
4. Optionally runs `git pull`.
5. Stops `beecam.service` if it is currently active.
6. Backs up current runtime files to `/data/update_backups/<timestamp>/`.
7. Replaces `/home/pi/beecam` from the repo copy.
8. Removes non-production/relegated Python files from the deployed camera folder.
9. Overwrites `/data/configs/camera_config_final.ini`.
10. Rewrites and installs `/etc/systemd/system/beecam.service`.
11. Reloads systemd.
12. Restarts `beecam.service` depending on `--restart`, `--no-restart`, or auto mode.

Important distinction: `beecam-init-data.service` is boot-time storage preparation. `beecam-update-runtime.sh` is field update deployment for code/config/service files. It does not repartition, install apt packages, or do a full provisioning pass.

> what does [beecam-init-data.sh](scripts/beecam-init-data.sh) do?

[beecam-init-data.sh](./scripts/beecam-init-data.sh:1) prepares the BeeCam’s `/data` partition on the Raspberry Pi.

In order, it:

1. Assumes the SD card is `/dev/mmcblk0` and the DATA partition should be `/dev/mmcblk0p3`.
2. Checks required commands exist: `awk`, `blkid`, `mountpoint`, and later partitioning tools if needed.
3. If partition 3 does not exist, it tries to create it in the unused space after the root partition.
4. If partition 3 exists but has no filesystem, it formats it as exFAT with label `DATA`.
5. If partition 3 exists but is not exFAT, it refuses to touch it.
6. Reads the DATA partition UUID.
7. Ensures `/data` exists.
8. Adds or replaces the `/data` entry in `/etc/fstab` using that UUID.
9. Mounts `/data`.
10. Verifies `/data` really is mounted.
11. Creates `/data/logs` and `/data/images_and_labels`.
12. If `/data/configs` does not exist, it copies default configs from `/home/pi/setup/configs`.
13. Writes `/data/.beecam-data-initialized`.
14. Prints `DATA partition is ready`.

So its main purpose is: make sure the separate DATA partition exists, is mounted at `/data`, and contains the directories/configs the camera app needs before BeeCam starts.

> for the transfer script can you explain the behavior my technician got today. I'll post their message below.
>
> On cam20 I did get a message: " Cleaning up SD card...
> rm: cannot remove '/media/wlab/DATA/images_and_labels/2026-05-13/labels': Directory not empty"
> But it did successfully delete most of the other things. I just put it back but I can look into it more if you think it's important.

<details><summary>1 previous message</summary>

> I’ll answer from the script behavior rather than changing anything. The key bit is that `rm -rf` can partially succeed, then fail on one directory, and with `set -e` the script should stop right there.
</details>

Yes, that behavior is explainable, and it is worth checking, but it is not a “data failed to transfer” signal by itself.

The script only reaches `Cleaning up SD card...` after the zip has been created and `unzip -t` has verified it. So cam20’s archive was likely already safely written before this happened.

The failure happened during this cleanup step in [transfer_beecam.sh](./transfer_beecam.sh:277):

```bash
rm -rf /media/wlab/DATA/images_and_labels
```

`rm -rf` can partially delete a tree, then fail on one subdirectory. In this case it got down to:

```text
/media/wlab/DATA/images_and_labels/2026-05-13/labels
```

and Linux reported that `labels` was still not empty. That usually means the exFAT filesystem still had entries there that `rm` could not remove cleanly. Common causes are an unclean SD removal/eject, exFAT metadata oddness, or filesystem corruption. It is unlikely to be caused by `offline_update`.

Because the script uses `set -e`, that error should stop the script immediately. So it probably did not finish the cleanup verification/sync/final `Done` steps after that point.

What it means practically:

- The archive was probably fine.
- Most image data may have been deleted, which frees most space.
- Some label files or a stale/corrupt directory likely remained.
- The camera can probably keep running, but the next transfer may pick up those leftover labels again.
- If the filesystem is dirty, the same cleanup issue could recur.

When convenient, I’d inspect that card on the laptop and run a filesystem repair/check on the DATA partition. Also make sure the SD is explicitly ejected/unmounted after transfer; that matters a lot with exFAT cards.

> does the transfer script automatically unmount the card?

No. [transfer_beecam.sh](./transfer_beecam.sh:300) now flushes writes with `sync`, but it does **not** unmount or eject the SD card.

So after it finishes, the technician still needs to eject/unmount the DATA partition manually before removing the card.

That is probably worth adding, or at least offering as an optional prompt, because exFAT really does not love being pulled immediately after deletes.

> how could the technician repair the sd card this happened for?

<details><summary>1 previous message</summary>

> I’ll keep this procedural and conservative: first preserve the verified archive, then repair only the DATA partition, not the whole SD device.
</details>

Yes. I’d have them repair the **DATA partition only**, after confirming the archive exists.

Suggested Linux steps:

```bash
lsblk -f
```

Find the SD card’s `DATA` partition. It will usually be something like `/dev/sda3`, `/dev/sdb3`, or `/dev/mmcblk0p3`, with filesystem `exfat` and label `DATA`.

Unmount it first:

```bash
sudo umount /media/wlab/DATA
```

Run a no-write check first:

```bash
sudo fsck.exfat -n /dev/sdX3
```

Replace `/dev/sdX3` with the actual DATA partition, not the whole SD card.

If it reports problems, repair it:

```bash
sudo fsck.exfat -a /dev/sdX3
```

or interactively:

```bash
sudo fsck.exfat -r /dev/sdX3
```

Then unplug/reinsert the card, or mount it again, and check whether the leftover directory is gone or removable:

```bash
rm -rf /media/wlab/DATA/images_and_labels/2026-05-13/labels
sync
```

Then eject/unmount before removing:

```bash
sudo umount /media/wlab/DATA
```

Important: don’t run repair on `/dev/sdX` without the partition number. Use the DATA partition, usually partition `3`.

> can you update the transfer script to automatically unmount the sd card after finishing

<details><summary>3 previous messages</summary>

> I’ll make the transfer script do the safe-removal step itself after the archive is verified, cleanup is checked, and writes are flushed. I’ll keep it focused on the SD/card source side, not the destination SSD.
>
> I’m going to add a dedicated unmount step after cleanup, and I’ll make sure the script changes directory out of the SD card first. Otherwise the script’s own working directory can keep the mount “busy,” which would be a hilariously unhelpful way to fail.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./transfer_beecam.sh` (+63 -1)
>
> </details>
</details>

Updated [transfer_beecam.sh](./transfer_beecam.sh:57) to automatically unmount the SD card’s `DATA` partition at the end.

What changed:
- Adds an explicit plan step: `Unmount SD card DATA partition`.
- Flushes writes, prints after-cleanup disk usage, then unmounts.
- Changes directory out of the SD card before unmounting, so the script itself does not keep the card busy.
- Uses `udisksctl` on Linux when available, then falls back to `umount`/`sudo umount`.
- Uses `diskutil unmount` on macOS.
- Final output now says the `DATA` partition was unmounted.

Validation passed with `bash -n transfer_beecam.sh` and `git diff --check transfer_beecam.sh`.

One nuance: it unmounts the `DATA` partition the script used. If the desktop also mounted another SD-card partition like `boot`, the technician should still eject that from the file manager before physically removing the card.

> can you make a short intruction command document on how to repair the sd cards that the technician can follow.

<details><summary>3 previous messages</summary>

> I’ll add a small field-facing repair note with copy-pasteable commands and the big safety warning: repair the `DATA` partition, not the whole card.
>
> I’m going to put this at the repo root as `SD_CARD_REPAIR.md`, since it’s meant to be easy for a technician to find next to `transfer_beecam.sh`.
>
> <details><summary>Created 1 file</summary>
>
> - Wrote `./SD_CARD_REPAIR.md` (+92 -0)
>
> </details>
</details>

Added a short technician-facing repair guide: [SD_CARD_REPAIR.md](./SD_CARD_REPAIR.md).

It covers finding the `DATA` partition with `lsblk -f`, unmounting it, running `fsck.exfat` safely, cleaning leftover transferred folders, and ejecting before removal. I also ran `git diff --check` on the new doc.

> can you change the transfer script to unmount the card without a prompt. This will reduce the interaction needed to complete a transfer.

<details><summary>3 previous messages</summary>

> I’ll make the final unmount attempt non-interactive: it should use normal removable-drive tools and fail with a clear message instead of asking for a sudo password at the very end.
>
> The only likely interactive path is the `sudo umount` fallback, which could ask for a password. I’m changing that to `sudo -n` and quieting failed fallback attempts, so the script either unmounts automatically or prints a clear manual-unmount error.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./transfer_beecam.sh` (+7 -7)
>
> </details>
</details>

Done. I updated [transfer_beecam.sh](./transfer_beecam.sh:67) so the unmount step does not prompt for a sudo password.

It now tries non-interactive unmount methods only: `udisksctl`, normal `umount`, device `umount`, then `sudo -n umount` only if sudo can run without prompting. If all fail, it prints a clear manual-unmount error instead of hanging at a password prompt.

Validation passed:

```bash
bash -n transfer_beecam.sh
git diff --check transfer_beecam.sh
```

The script still has the initial `Proceed? [y/N]` confirmation before transfer begins; the final unmount is automatic/non-interactive.

> for the directions we can expect the sd card to show up with 3 partitions: each under mmcblk0. bootfs is mmcblkp1, and rootfs is mmcblkp2 and DATA is mmcblk0p3, cna you modify to reflect this

<details><summary>4 previous messages</summary>

> I’ll tune the repair note for the expected built-in SD-reader layout: `bootfs` on `/dev/mmcblk0p1`, `rootfs` on `/dev/mmcblk0p2`, and `DATA` on `/dev/mmcblk0p3`, with the repair command aimed only at partition 3.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./SD_CARD_REPAIR.md` (+19 -9)
>
> </details>
>
> I noticed one sentence became a little clunky after the edit, so I’m smoothing that section before I wrap up.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./SD_CARD_REPAIR.md` (+1 -7)
>
> </details>
</details>

Updated [SD_CARD_REPAIR.md](./SD_CARD_REPAIR.md:23) to use the expected SD layout:

```text
/dev/mmcblk0p1  bootfs
/dev/mmcblk0p2  rootfs
/dev/mmcblk0p3  DATA   exfat
```

The repair commands now directly use `/dev/mmcblk0p3`, with a warning not to repair `/dev/mmcblk0`, `p1`, or `p2`. `git diff --check` passed.

> after running the new transfer script and plugging back into the pi, the technician sees that the data is still on the card. And ls -a shows the images folder is still there despite rm -r saying it doesn't exist.
>
> rm -r images_and_labels
> pi@cam18:/data $ ls
> configs  hostname  logs
> pi@cam18:/data $ df -h
> Filesystem      Size  Used Avail Use% Mounted on
> udev             74M     0   74M   0% /dev
> tmpfs            84M  2.7M   81M   4% /run
> /dev/mmcblk0p2  9.8G  3.9G  5.4G  42% /
> tmpfs           209M  8.0K  209M   1% /dev/shm
> tmpfs           5.0M  8.0K  5.0M   1% /run/lock
> /dev/mmcblk0p3  109G   16G   94G  14% /data
> /dev/mmcblk0p1  510M   58M  453M  12% /boot/firmware
> tmpfs            42M     0   42M   0% /run/user/1000
> pi@cam18:/data $ ls -a
> .  ..  .Trash-1000  .beecam-data-initialized  configs  hostname  images_and_labels  logs

<details><summary>5 previous messages</summary>

> I’ll separate the two issues here: seeing `images_and_labels` again is expected with the new script, but `16G used` means something else is still consuming space. I’m going to inspect the current cleanup behavior so I can map it exactly to their transcript.
>
> That transcript points to a very specific culprit: `.Trash-1000`. The top-level `images_and_labels` folder can reappear empty because the script and boot init recreate it, but `df` showing 16G used while normal `ls` only shows small folders means hidden trash is probably holding the old data. I’m going to update the transfer cleanup to clear SD-card trash directories too.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./transfer_beecam.sh` (+11 -1)
>
> </details>
>
> I’m also adding the same clue to the repair note, because `.Trash-1000` is exactly the sort of hidden folder a field tech will miss with a normal `ls`.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./SD_CARD_REPAIR.md` (+5 -0)
>
> </details>
</details>

That transcript is very suggestive: the old data is probably in hidden trash, not in the visible `images_and_labels` folder.

Two key details:

- `images_and_labels` coming back is expected. The transfer script recreates it as an empty folder, and the Pi boot init also runs `mkdir -p /data/images_and_labels`.
- `.Trash-1000` is the suspicious part. Linux desktops often move deleted files on removable drives into `.Trash-1000`, which still consumes space. That explains `df -h` showing `/data` at `16G` used while normal `ls` looks mostly empty.

For cam18 right now, the tech can check with:

```bash
sudo du -h -d1 /data | sort -h
sudo du -h -d1 /data/.Trash-1000 2>/dev/null
```

If `.Trash-1000` is large, remove it:

```bash
sudo rm -rf /data/.Trash-1000
sync
df -h /data
```

I updated [transfer_beecam.sh](./transfer_beecam.sh:274) so future transfers delete `.Trash-*` from the SD card after zip verification, and verify it is gone before unmounting. I also updated [SD_CARD_REPAIR.md](./SD_CARD_REPAIR.md:8) to mention `.Trash-1000`.

Validation passed with `bash -n transfer_beecam.sh` and `git diff --check`.

> are .Trash folders created by exfat?

No. `.Trash-1000` is not created by exFAT itself.

It is created by Linux desktop/file-manager trash behavior, usually when a user deletes files from a mounted removable drive through the GUI, or sometimes by tools that use the freedesktop trash convention. The `1000` is the Linux user ID, commonly the first normal user.

exFAT just stores the folder like any other directory. It does not know it is “trash.”

So on these BeeCam cards:

- `.Trash-1000` means something on the laptop side likely moved deleted files to trash instead of permanently deleting them.
- Files inside `.Trash-1000` still consume SD card space.
- `rm -rf /media/wlab/DATA/.Trash-*` permanently clears those hidden trash folders.
- `transfer_beecam.sh` using `rm -rf` should not normally create `.Trash-1000`; it only now removes it if present.

> what type of file is offline update?

`offline_update` is a Bash shell script.

It has no `.sh` extension, but the first line tells the system what runs it:

```bash
#!/usr/bin/env bash
```

So you run it like an executable script:

```bash
./offline_update cam18
```

or, if needed:

```bash
chmod +x offline_update
./offline_update cam18
```

> is there a reason there is no.sh?

No strong technical reason. It works fine without `.sh` because the shebang tells Linux to run it with Bash:

```bash
#!/usr/bin/env bash
```

The likely reason is style/convenience: executable command-style scripts often omit extensions, like `offline_update`, `backup`, `deploy`, etc. That lets you treat it more like a command:

```bash
./offline_update cam18
```

instead of:

```bash
./offline_update.sh cam18
```

The downside is discoverability. Since most other scripts here use `.sh`, renaming it to `offline_update.sh` would be reasonable for consistency, but any docs/instructions that call `./offline_update` would need updating.
