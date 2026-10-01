# 3DS Game Installer - user guide

This Windows app turns installing games on a modded 3DS into a few visible steps:

1. Tick the games to add or remove.
2. Click the one action button. The app prepares the games and copies them to the SD card.
3. Install them in GodMode9.

When the card comes back, the app confirms what installed and cleans up by itself. It deliberately
does not edit the encrypted `Nintendo 3DS` title tree.

The normal screen hides Title IDs, hashes, conversion details, and internal lifecycle records. Those
details remain in the private activity log and state files for diagnosis. The game list checks itself
when the app opens with the SD attached and whenever the SD is reinserted. A saved index reuses metadata
for files whose full path, length, and last-write time are unchanged; only new or changed files are
re-inspected and hashed. Every scan, hash, conversion,
copy, and cleanup operation keeps a visible progress card active with the current file,
byte progress when available, and elapsed time. Multi-game preparation and SD writing also state the
current game number, batch total, completed count, and number remaining after the current game.

The game-list status is intentionally binary: **Playable now? Yes/No**. `Yes` means an installed title
package is present (including existing eShop titles or games already used on the console). `No` means
the title is absent, only waiting in a GodMode9 install batch, or known to be malformed. Strong health,
staging, and uncertainty remain internal safety states and drive the green next-step card.

The **SD card space** card below Next step shows a pie chart of the card in three parts:

- **Games:** installed base games, updates and DLC, plus CIAs waiting in an install folder.
- **Other:** everything else in use, including filesystem overhead.
- **Free:** unused space.

The game sizes come from the inventory the app already reads; nothing extra is read from the card.
Free and total space are read live each time the list updates (after a check, a copy, or the card's
return), and that live free space also feeds the copy plan. The chart stays visible while a check or
copy is running, and hides once the card is ejected or disconnected.

Preparation failures are isolated when they are provably specific to one source. A bad source,
conversion failure, or CIA-validation failure marks only that row **FAILED**, keeps the concise reason
on the row, removes disposable/incomplete generated output, and continues with the other selected games.
The completion dialog reports separate prepared, cached, and failed counts. A failed row stays tickable
and shows its reason on hover; after the source is fixed or replaced, tick it and choose **Add to SD
card** again. Only the ticked games are prepared, and a success clears the failure.
Failure history is keyed by exact Title ID plus source SHA-256. Replacing a bad source therefore does not
erase its diagnosis or incorrectly transfer the failed status to the replacement.

Failures involving SD identity or health, insufficient destination space, toolchain availability,
cache/storage integrity, access control, cancellation, or an unclassified condition stop the whole
operation. Unknown failures deliberately fail closed. No path uses `--ignore-bad-hashes`.

The card path is trusted, which assumes a healthy USB card reader. Staging copies each validated game
once and never reads it back. When the SD returns, installed games are confirmed by matching their files
and sizes to the validated manifest; nothing on the card is re-read or re-hashed.

The interface models state changes; it does not model game files as objects that are literally moved
between PC and console:

| State | Meaning |
| --- | --- |
| `Missing` | A preserved library source exists, but no installed title or staged batch is detected. An empty Title-ID folder left by a refused install also counts as `Missing`. |
| `Prepared on PC` | A validated InstallReady artifact is waiting in the guided queue; it is not yet on the SD or playable. |
| `Staged on SD` | A validated CIA copy is waiting in one exact timestamped install set; it is not installed. |
| `Installed + healthy` | The title directory has complete TMD/CMD/save structure, and its content IDs and lengths exactly match a validated CIA manifest. |
| `Installed + uncertain` | The Title ID exists and basic structure is readable, but no validated CIA manifest is available for a strong comparison. |
| `Installed + unhealthy` | Required structure, content IDs/lengths, or save size do not match. The game can simply be added again. |
| `Exported` | GodMode9 built a CIA in `SD:/gm9/out`; this is separate from installation state. |

Base games, updates, and DLC retain distinct Title ID namespaces and a visible `Type` throughout the
library, installed-title, batch, sync-plan, export, and removal records.

## Guided installation

**Add to SD card** is one action. It converts and validates the ticked games, adds them to a private
guided queue, and copies the whole queue into one GodMode9 folder in the same run. It then reports the
game count and folder name. There is no batch size. Only the card's free space can hold games back: the
games that fit are copied, and the rest follow once those are installed.

There is no copy button. Games the user chose wait on the PC only while a batch is already on the card
waiting to be installed, or while the card is full. The Next step card says which. Every check copies
whatever is waiting as soon as it can: at startup, when the card comes back from the 3DS, and on
**Check for changes**.

After **Safely Eject SD** and installation in GodMode9, reinserting the card finishes the batch
automatically. The app reports `Batch returned: N of M installed` and removes the whole install folder.
It then copies the next batch straight away: any game that did not install, plus anything else waiting.
A batch that has not yet been taken to the 3DS stays on the card until it has been.

A batch name is never reused, even after its folder is removed. The private record of each batch keeps
the validated manifests that confirm its games are installed. The next batch is often copied in the
same second the returned folder is removed, so a repeated name gets a short unique suffix.

## More than one SD card

Each card keeps its own install batch, waiting games and removal marks. The app tells cards apart by
the two ID folder names inside the card's `Nintendo 3DS` folder. Those names come from the specific
console and card, so the same card is recognised in any reader or drive letter, and a card from
another console never matches. Only a one-way hash of them is stored.

- **Switching cards:** every check, including when a card is inserted, switches the screen to that
  card's own records.
- **Nothing crosses over:** a batch copied to one card is never reported as returned from another.
  Games chosen for one card are never copied to another, and a removal is confirmed only on the card
  whose console did it.
- **Stale screen:** if a different card is put in the reader before it has been checked, the action
  button and the copy step refuse with "not the one shown". Choose **Check for changes** first.
- **Two cards connected at once:** pick one in the SD card list.
- **While a card is out:** the app remembers the last card checked, so its batch and steps stay visible
  while it is in the 3DS. This is for display only; every write checks the card actually in the reader.

## Safety model

- ROMs, generated CIAs, keys, exports, and manager state stay outside Git.
- The source ROM is hashed and never converted in place. Conversion uses a disposable copy.
- A CIA must pass metadata, content-hash, ExHeader/ExeFS/RomFS, icon, banner, region, save-size,
  and encryption-state checks before it can enter `InstallReady` or an SD install queue.
- `--ignore-bad-hashes` is never used.
- The SD identity is re-resolved immediately before each batch is written and before a finished folder is
  removed. It must be USB-attached, non-system, MBR with one FAT32 partition, and contain the expected
  `Nintendo 3DS` folder. Any cluster size is accepted: 3ds.hacks.guide uses 32 KiB for cards of
  64 GB or less and 64 KiB above.
- Only a USB-attached volume containing a `Nintendo 3DS` folder is offered as the SD card. Internal
  drives, other USB storage, and empty reader slots are ignored, so they never block automatic
  identification or the safe-eject confirmation. If two 3DS SD cards are connected, choose one in the
  SD list; the choice is kept while that exact card stays connected.
- Each PC-to-SD handoff uses a uniquely timestamped, human-readable GodMode9 folder under
  `SD:/cias/InstallQueue/`, named by game count and time; for example, `4-games - 2026-09-02 12-00-00`.
- Human-readable install-set folder labels are never used directly as Windows state filenames. Private
  state uses a deterministic SHA-256 key, preventing spaces or other presentation text from leaking into
  the restricted filename contract.
- On every SD return, each staged game counts as installed only when it is `Installed + healthy`;
  directory presence alone is insufficient. Everything else goes back in the queue.
- A returned install folder is removed whole. Staged copies are disposable because the PC keeps the
  validated artifacts. Folders the manager did not create are never touched.
- Windows' volume-health flag (the FAT dirty bit set by ordinary writes) is shown as an advisory; it does
  not block copying or cleanup.
- The PC never uninstalls a title, edits a ticket database, or deletes a save. A removal only marks the
  title outside Git for console-side deletion.

## Launch

Double-click `start.vbs` in the project folder. The launcher uses the interactive user's normal
Windows token, hides the PowerShell host, and leaves only the app window visible. It does not force a
UAC prompt. Exact disk-safety checks remain mandatory and fail closed before any write if the current
Windows session denies a required query.

The app allows only one running instance and refuses to close while a game
preparation/copy/verification operation is active. If Windows or the process terminates unexpectedly,
pattern-validated disposable work folders are cleared on the next exclusive startup; sources,
InstallReady artifacts, and SD batches are never treated as disposable.

### Safely ejecting the SD card

Use the prominent **Safely Eject SD** button instead of physically pulling the card or switching to
Explorer. The button is bound to the selected disk's Windows disk UniqueId, disk PnP device-instance ID,
reader-parent PnP identity, and capacity. Disk number and drive letter must also still match the fresh
enumeration immediately before the request; a stale selection or a different removable drive is rejected.
Windows receives the normal eject request for the removable reader parent, but only after the manager
proves that no other mounted storage device shares that parent.

The manager offers eject only while idle. Scanning, verification, preparation, staging, reconciliation,
and cleanup show **SD in use** and disable eject. A safe request uses Windows Configuration Manager's
normal device-eject operation; it never forces a dismount. If Windows reports an outstanding handle or
another veto, the card remains mounted and the veto type/name is shown when Windows supplies it.

After success the UI shows **Safe to remove SD card**, clears the selected volume, and disables all
SD-dependent actions. The old drive letter cannot be reused. The manager must observe the device absent
and then positively identify the same physical fingerprint after reinsertion before enabling SD actions.

While work is active, every other input is locked and **Cancel** is the only control, in the progress
card. Cancel stops at the next cooperative checkpoint and keeps what had already finished. Each step is
saved as it completes:

- Removal marks are kept.
- Each game already prepared is kept, waiting on the PC.
- Each game already copied is kept on the card as a smaller batch. Its folder is renamed for its real
  game count and gets a matching install list.

The step in progress is cancelled. Its disposable helper processes are ended, and its partial cache file
or partial SD copy is removed. Nothing after it runs. Sources and installed titles are never touched.
The app cannot close until this cleanup finishes. It then reports exactly what was kept, and the progress
card disappears. Games left waiting are copied by the next check, at startup, when the card returns, or
on **Check for changes**.

After a batch is copied, the app updates its view directly from that result. Reconciliation happens
automatically when the SD returns from the console. There is no separate verification or cleanup button:
the manager confirms which games installed, removes the install folder, and queues the rest again.

For command-line diagnosis, run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\library-manager.ps1
```

On first use, open **Settings** and select **Set up helper tools**. The setup installs a pinned CTRTool and 3dsconv toolchain below
`%LOCALAPPDATA%\BackupsNew3DS\LibraryManager`; it does not place tools or keys in this repository.
Once ready, the setup control is hidden.

The boot9 chooser is hidden unless the library contains an encrypted `.3ds`/`.cci` physical-cartridge
dump. boot9 is a small key file dumped from the user's own 3DS and is used only to decrypt that kind of
source during conversion. Decrypted `.3ds` files and CIA inputs do not require it. The settings column
scrolls vertically, and full folder paths remain available as tooltips.

## PC to 3DS

1. Put `.3ds`, `.cci`, or `.cia` files of games you own in your game-library folder. Choose that folder
   once in **Settings**; the app remembers it.
2. Connect the powered-off console's SD card. The app finds it and updates the game list automatically.
   **Check for changes** does the same on demand: it finds the card again, then checks the library and
   the card. Unchanged ROMs are not re-hashed.
3. Tick **Add** for games showing **Playable now? No**, and **Remove** for installed games to delete.
4. Select the one action button. Its label names what it will do, for example **Add to SD card**,
   **Remove from 3DS**, or **Add 2, remove 1**. Removals are marked first. Then the manager validates
   each source to add, reuses or creates a validated CIA on the PC, and copies everything that is ready
   into a fresh GodMode9 folder. If one source alone fails, the app marks that game **FAILED** and
   finishes the others. Fix or replace its file, then tick it and apply again.
5. Safely eject the SD, boot GodMode9, open the folder displayed by the manager, mark every CIA in it
   with `L`, and choose `Install game image`.
6. Reconnect the SD to the PC. This is safe even if GodMode9 was stopped after only one game. The manager
   confirms which games installed, removes the install folder, and copies the next batch: anything that
   did not install, plus anything still waiting. PC sources and InstallReady artifacts are always
   preserved.

The green **Next step** card always tells the user which one of these actions comes next. **Ready to
install** means a CIA is staged on the SD; it does not mean the title is installed on the console.

GodMode9 supports selecting multiple same-type files with `L` and applying an operation in batch. The
console still performs installation because only it can safely register tickets, title metadata, and
console-bound SD content.

## 3DS to PC

Installed titles cannot be recovered by dragging their encrypted folders out of `Nintendo 3DS`.
To keep a PC copy of a game you own, use GodMode9's Title Manager to build a CIA. GodMode9 places it
in `SD:/gm9/out`; copy it into your game-library folder, and the next check picks it up. The app has
no import button for this.

Saves are separate and are not part of this transfer. Use Checkpoint or another purpose-built save
tool to back up and restore saves.

## Removal

Installed base games have a **Remove** checkbox. Tick one or more and apply the changes, together with
any games to add. There is no confirmation pop-up, because marking deletes nothing. The manager records
the exact titles outside Git, and the Next step card gives the console handoff alongside any install
steps:

`System Settings > Data Management > Nintendo 3DS > Software`

A marked game shows **Delete on the 3DS**, and its Remove box stays ticked. To change your mind, untick
it and apply (the button reads **Keep on 3DS**). New marks join earlier ones that are not yet carried
out.

The console performs the actual uninstall because Windows cannot safely update console title and ticket
state. The manager never deletes from `Nintendo 3DS`. When the SD returns, each marked title that is now
absent is confirmed on its own; the rest stay marked. Updates, DLC, and system titles are not eligible
for this simple removal control.

Removing a console title never deletes or changes its source ROM, validated `InstallReady` CIA,
GodMode9 export, or manager history. After the console-side removal and SD rescan, a desired title is
reported as `Missing` and can be staged again.

## External state

Private indexes and queue records are stored under:

```text
%LOCALAPPDATA%\BackupsNew3DS\LibraryManager
```

The `InstallReady` cache is user-selected and must remain outside this repository.

## Upstream references

- GodMode9 README: https://github.com/d0k3/GodMode9
- 3dsconv README: https://github.com/ihaveamac/3dsconv
- 3DS Hacks Guide: https://3ds.hacks.guide/
