# Repository working agreements

This public repository contains the 3DS Game Installer: a Windows app, its core module, setup
script, launcher, tests, and documentation. It contains no ROMs, keys, or console data.

## Storage boundaries

- Never store raw SD-card contents, ROMs, game files, console-private data, credentials, encryption
  keys, backups, or per-file path/hash listings in Git.
- Never commit personal details: user names or home-folder paths, disk serials or device IDs, real
  backup hashes, or a personal game list. Tests use synthetic values only.
- The git-ignored `private/` folder holds a maintainer's local working notes and one-off tools (for
  example `private/docs/CURRENT_STATE.md`). Keep them current when present, and never commit them
  or copy their contents into tracked files.
- Never assume a drive letter. Resolve the drive through Windows disk, partition, and volume metadata
  each time, and stop if the result is missing, ambiguous, or changed.
- The app never formats, repartitions, or writes outside its own install folders on the SD card.

## Sources

- Use the current https://3ds.hacks.guide/ as the authoritative source for 3DS filesystem and
  modding requirements.

## Library management

- Never treat files inside the console-bound `Nintendo 3DS` tree as portable installed games. PC-side
  tooling may inspect public Title IDs read-only, but installation, removal, ticket registration, and
  save management remain explicit console-side operations.
- Preserve and hash each source, convert only a disposable copy, and never pass
  `--ignore-bad-hashes`. Use `--ignore-encryption` only when inspection proves the payload is already
  decrypted but its header flags are stale.
- Treat a known source/conversion/CIA-validation failure as isolated to that title: clean its disposable
  output, retain successful titles, continue the batch, and persist the failure on that title's row, which
  stays tickable so the normal prepare action retries it; never add a separate retry control. Unknown failures
  and toolchain, storage, space, or SD-safety failures remain fatal and stop the batch fail-closed.
- Persistent state/cache filenames must use fixed names or validated stable keys (for example, a Title ID
  plus source SHA-256, or a hash thereof), never unsanitized display titles, status/error text, or
  human-readable folder labels.
- Before staging any CIA, validate its Title ID, product code, region, save size, readable icon/banner,
  content hashes, and internally consistent crypto state. Prove crypto consistency with the ExHeader/
  ExeFS/RomFS hashes checked under the NCCH's declared crypto; the CIA content layer and the NCCH layer
  are independent, so never reject a decrypted CIA that wraps a Secure-key NCCH. Store artifacts and
  private indexes outside Git.
- FBI success messages are not accepted for this generated-CIA workflow on this console. GodMode9
  `Install game image` is the installation path; the manager confirms each install when the SD returns.
- Treat install, uninstall, staging, cleanup, and export as lifecycle state changes, never literal moves
  of source material. Preserve source ROMs, validated `InstallReady` artifacts, and exports across
  console removal.
- Never equate Title-ID directory presence with a healthy installation. Require an exact match of the
  installed content IDs, lengths, TMD/CMD metadata, and save size to a validated CIA content manifest;
  otherwise label the title uncertain or unhealthy. A Title-ID folder holding no files is not an installation; treat it
  as Missing so the title can be restaged. Never inspect encrypted title content as though it were a
  portable export.
- Persist user-selected external ROM-library and `InstallReady` paths in private manager state so the
  GUI does not repeatedly ask for them. Never persist or assume an SD drive letter/disk identity;
  re-detect removable targets each session.
- Every state-changing handler must complete its post-action refresh successfully when the library,
  installed-title list, or staged-batch list is empty. Test the empty state explicitly; never let a
  completed operation appear to fail merely because an optional collection has zero items.
- Ticking Add and Remove boxes, then one apply action, is the whole workflow. The action applies every
  tick in one run (marks, then preparation, then the SD copy), and its label names what it will do. There
  is no separate copy, remove, or retry control, and no confirmation pop-up. Every refresh (startup, card
  return, Check for changes) copies whatever is waiting whenever no batch is out to be installed and the
  card has room. Never ask the user to copy games they already chose.
- The Remove box shows the saved mark, so unticking a marked game and applying undoes the mark.
- Never reuse an install-batch name, even after its folder is removed: its private record holds the
  manifests that confirm installs.
- Test free-space and byte arithmetic with real card-scale values (tens of GB), not only small fixtures.
- Inventory and redraws run while an operation is busy, so display that describes the card must gate on
  `IsMounted`, not `CanUseSd`. Tests must take card states from `Resolve-ThreeDSSdLifecycle`, including
  `Mounted + busy`, never from hand-built lifecycle flags.
- Keep the primary library-manager UI centered on the human lifecycle: choose games, prepare SD,
  install one GodMode9 batch, and let the manager confirm and clean up when the SD returns. Hide Title IDs, hashes, internal state,
  and specialist tools from the normal view. Every long scan/hash/copy/conversion must show a live
  operation description, elapsed time, and byte progress when available so the app never appears frozen.
- Every multi-item operation must also show the current item's one-based position and batch total, plus
  explicit completed and remaining counts. A percentage or current filename alone is not sufficient.
- Give install sets human-readable GodMode9 folder names that include game count and creation time. Keep
  opaque IDs, legacy timestamp-only names, and internal lifecycle terminology out of normal UI copy.
- Do not run a second full SD/library reconciliation immediately after the app itself has written an
  install set. Update the view from that result and defer the next reconciliation until the SD returns
  from the console or the user explicitly checks for changes.
- Do not expose manual verification or cleanup controls. On return, a batch that has been out to the
  console is finished: record what installed, remove its install folder whole, and put titles that did
  not install back in the queue. Never add review, hold, or quarantine states for titles that did not
  install; a broken install is simply added again.
- Desktop removal controls may coordinate only normal console-side uninstall. They must preserve PC source
  and prepared artifacts, never edit `Nintendo 3DS` directly, persist pending intent outside Git, restrict
  the simple workflow to base games, and confirm absence automatically after the SD returns.
- Hide and reset completed progress bars when an operation ends; persistent full bars must not occupy the
  idle interface or imply that work is still active.
- Keep scrollable settings/sidebar card widths stable when an automatic scrollbar appears or disappears;
  reserve a viewport-safe fixed content width rather than allowing the scrollbar to squeeze the layout.
- Trust the card path with a healthy USB reader: never read back or re-hash staged copies, and never fully
  re-read installed titles. Judge installed health by manifest and length, and remove finished install
  folders without re-hashing; staged copies are disposable because the PC keeps the validated artifacts.
- Treat Windows storage enumeration as transient: retry a partition whose volume object briefly vanishes,
  then fail with a user-facing no-change message. All SD state changes must refuse volume health other than
  Healthy, even when disk hardware health is Healthy.
- Refresh library state automatically on startup and removable-card return. Reuse cached ROM metadata
  only when full path, length, and last-write time match; preparation must still re-hash a selected source
  before any state change. Empty UI collections and selections must be handled without aggregate-property
  access that fails under strict mode.
- Progress callbacks are observational and must have their output discarded at every core invocation;
  callback output must never contaminate artifacts, inventory rows, queue records, or persisted state.
- Launch the WPF library manager through the console-free standard-user launcher. Do not force UAC at
  startup or present a companion PowerShell window. Exact disk checks must still fail closed before writes.
- Freeze every state-affecting selector and input while a scan, validation, conversion, copy,
  reconciliation, or cleanup is active; processing views must be observable but not editable.
- Once an operation starts, Cancel is its only control. Cancellation is cooperative: finished work is kept
  and the step in progress and everything after it are cancelled. Save each step as it completes (marks,
  each prepared game, each fully copied game; a stopped copy becomes a smaller, correctly named batch).
  Cancel must terminate only disposable child tools, close streams, remove only the in-progress partial
  file, preserve sources and installed content, report what was kept, and keep window closure blocked
  until cleanup completes.
- Hide boot9 configuration unless the scanned library actually contains an encrypted `.3ds`/`.cci`
  cartridge dump. Describe it in user terms when shown; decrypted sources and CIA files do not need it.
  Settings content must remain reachable at supported window sizes through vertical scrolling.
