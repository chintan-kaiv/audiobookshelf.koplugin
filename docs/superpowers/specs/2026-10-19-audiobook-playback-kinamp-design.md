# Audiobook playback via KinAMP — design

Status: draft for review · Date: 2026-10-19 · Repo: `chintan-kaiv/audiobookshelf.koplugin` (fork of `naleo/audiobookshelf.koplugin`)

## 1. Intent

**What was asked.** Listen to Audiobookshelf (ABS) audiobooks directly on a jailbroken Kindle, and have listening progress sync back to ABS. No existing KOReader plugin, KPM package or Kindle app does this (checked: KPM repo index, naleo plugin source, KinAMP and LARKPlayer repos).

**Environment (from the user).**
- Kindle reporting as `KindleBasic4`, firmware 5.19.2.0.1, jailbroken, KOReader installed.
- KinAMP is installed and opens. LARKPlayer is ruled out: its open issue #10 reports it does not launch on firmware 5.19.
- ABS is self-hosted; BookBridge (`booksync.example.com`) already syncs ABS audio position with ebook position in KOReader.

**Success looks like.**
1. In KOReader, browse the ABS audiobook libraries and download a book to the Kindle.
2. Press Play, and the book plays through KinAMP from the ABS position.
3. While playing, and when stopping, the ABS position is updated, so the ABS app (and BookBridge, which reads ABS positions) sees it.

**Assumptions (correct me).** Audio output works on this Kindle (Bluetooth or headphones), unconfirmed. ABS is the source of truth for position. One ABS user per Kindle.

## 2. Non-goals

- No ebook-to-audio alignment. BookBridge does that and is untouched.
- No streaming. Books are downloaded first (an e-ink Kindle is a poor streaming client, and KinAMP plays local files).
- No changes to KinAMP itself. We drive it through its public control interface.
- Existing ebook browse/download behaviour stays as is.

## 3. Facts that shape the design

**This plugin today** (`naleo/audiobookshelf.koplugin`, ~1,100 lines of Lua): lists libraries, lists and searches items, shows a details page, downloads files. It is ebook-only: item listing and search use the ABS `ebooks` filter, the details page only lists `fileType == "ebook"` files, and it contains no progress or audio code. Config is `audiobookshelf_config.lua` (`server`, `token`). Downloads go to a user-chosen `download_dir` (saved in that same settings file via the folder chooser, falling back to KOReader's last-used folder), as flat files named `<download_dir>/<filename>` with no per-book subfolder.

**KinAMP** (`kbarni/KinAMP`, Beta) runs a separate player daemon. From `kinamp_backend.lua` and `cli_player.cpp`:
- Control: a FIFO `.kinamp_cmd` accepting newline-terminated commands: `load <m3u path>`, `index <n>`, `seek <seconds>`, `play`, `pause`, `next`, `prev`, `stop`, `vol <0-100>`, `quit`. Several commands can be written in one write.
- State: a key=value file `.kinamp_status`, rewritten about once a second while playing: `state` (playing/paused/stopped), `index` (0-based, -1 = nothing), `count`, `path`, `title`, `pos` and `dur` (seconds, current file).
- `seek` restarts the file at an offset (the code comment says MusicBackend has no seek).
- Decodes `.mp3 .flac .wav .ogg .m4a .m4b .mp4`. The README omits M4B, the code and the plugin's extension list include it.
- Runtime files live in `KINAMP_RUNTIME_DIR` (default `/tmp/`) and the install folder (`/mnt/us/KinAMP`, or `<koreader>/kinamp`). KinAMP's own `kinamp_config.lua` resolves them.

**ABS API** (to verify against the user's server version before relying on it): `GET /api/libraries/{id}/items`; `GET /api/items/{id}?expanded=1` (audio files with `ino` and `duration`, tracks with `startOffset`); `GET`/`PATCH /api/me/progress/{libraryItemId}` with `currentTime`, `duration`, `progress`, `isFinished`; file download `GET /api/items/{id}/file/{ino}/download` (already used by this plugin).

## 4. Approach

A KOReader plugin (the fork) that talks to ABS directly and drives KinAMP's daemon. Chosen over forking BookBridge because the sync engine there skips audio-only mappings by design, and BookBridge changes fast. Chosen over a KinAMP patch because KinAMP's control interface is already enough.

**Dependency:** KinAMP (its KOReader plugin and daemon) must be installed. The plugin refuses to start playback with a clear message if the daemon cannot be launched.

## 5. Components

All new code lives next to the existing modules in `audiobookshelf/`; `main.lua` gains a menu entry. Each module has one job and can be tested without a device.

| Module | Purpose | Depends on |
|---|---|---|
| `audiobookshelfapi.lua` (extend) | Add audio item listing (no `ebooks` filter), expanded item fetch, `getProgress`, `setProgress`. | existing config |
| `audiostore.lua` (new) | Where a book lives on the Kindle: folder per item, file order, per-file `startOffset`/`duration`, local paths, written `.m3u`, last synced position. Persisted with `LuaSettings`. | KOReader `datastorage`, `luasettings` |
| `audiodownloader.lua` (new) | Sequential download of a book's audio files with resume (skip files already complete by size), progress message, cancel. | api, store |
| `kinampclient.lua` (new) | Thin client for KinAMP: non-blocking FIFO write via `ffi` (open with `O_NONBLOCK`, ENXIO means no daemon), status-file parse, `is_running`, `launch`. Prefers `require("kinamp_backend")` if loadable, else its own small implementation. | `ffi`, `lfs` |
| `positionmap.lua` (new, pure) | Converts between ABS position (seconds into the whole book) and KinAMP (`index`, `pos`) using the track table; single-M4B is the one-track case. | none |
| `progresssync.lua` (new) | While a book is active: poll the status file on a timer, throttle and send progress to ABS, final sync on stop, suspend, and exit. | positionmap, kinampclient, api |
| `audiobookshelfbrowser.lua` (extend) | Audiobook vs ebook entry in the browser. | existing |
| `audiodetailswidget.lua` (new) | Book page: Download, Delete local files, Play/Resume, Stop, Sync now. | store, downloader, kinampclient |

## 6. Data flow

**Download.** Select item, fetch expanded item, build the track table (order, `startOffset`, `duration`, `ino`), download each file to `<download_dir>/<safe title>/NN-<name>`, where `download_dir` is the plugin's existing setting (same chooser and persistence as ebooks), write `book.m3u` in that folder, save the store entry. Ebooks keep saving flat as they do today. If `download_dir` has never been chosen, ask once and save it, instead of silently using the last-visited folder.

**Play / resume.**
1. Fetch ABS progress (`currentTime`). If offline, use the stored last-synced position and say so.
2. `positionmap` turns it into `(index, offset)`.
3. Ensure the daemon is running (launch if not), then send `load <book.m3u>`, `index <n>`, then `seek <offset>`.
4. Start `progresssync` for this book.

**While playing.** Every ~30 s: read the status file; require `state` playing or paused, a valid `index`, and `path` that matches the active book's track; compute the global position; if it moved by at least 10 s since the last send, `PATCH` progress. On Stop, suspend and KOReader exit, send a final update. On resume from suspend, re-read status and sync once.

**Conflict policy.** ABS is read at Play time and wins at that moment. After that the Kindle writes. A rewind the user makes is sent as is. Never write a position from a stopped or unknown daemon state, and never send 0 unless the user actually seeked to 0.

## 7. Error handling

- No network: download and ABS reads fail with a message. Playback of already-downloaded books still works; progress is queued locally and retried on the next sync.
- No KinAMP daemon or FIFO: message naming what is missing. No retries in a loop.
- Download interrupted: next attempt resumes, skipping completed files.
- Low disk space on the Kindle volume: check before downloading and refuse with a message. Note `/mnt/us` is FAT-style storage per KinAMP's own comments: 4 GB max file size, so a book larger than that must be refused up front. Sanitise filenames (the upstream plugin already uses `util.getSafeFilename`).
- Status file unreadable: treat as "no data this tick". Wrap every file read in `pcall`, as KinAMP does, because an uncaught error in a timer task takes KOReader down.

## 8. Risks and the spikes that retire them

Each is checked on the real device before the module that depends on it is written.

| # | Risk | Spike |
|---|---|---|
| S1 | The Kindle produces no sound (no Bluetooth or audio path). | Play one MP3 and one M4B in KinAMP by hand. If no audio, stop: nothing else matters. |
| S2 | A second KOReader plugin cannot write KinAMP's FIFO, or `require("kinamp_backend")` is not visible to us. | From a throwaway plugin, send `status` and `play` over the FIFO. |
| S3 | `seek` on a large M4B is slow because it restarts decoding. | Time `seek` into the middle of a multi-hour M4B. |
| S4 | The status `path` or `index` do not map cleanly to our tracks (relative paths, sanitised names). | Dump a few status files while playing a multi-file MP3 book. |
| S5 | ABS progress `PATCH` semantics differ on the user's ABS version (session sync may be required). | `curl` the endpoint with a test position; verify in the ABS app. |
| S6 | Playback or the poll timer misbehaves across Kindle sleep/wake. | Sleep the device mid-playback; check position after wake. |

## 9. Testing

- **Pure logic** (`positionmap`, playlist writer, status parser, progress throttle) is unit-tested with plain Lua outside KOReader.
- **Integration on a desktop** using KOReader's emulator with two fakes: a small HTTP server that mimics the ABS endpoints above, and a script that simulates KinAMP's FIFO and status file.
- **On device**: the spikes, then a full run: download a short multi-file book and a single-M4B book, play, quit KOReader, confirm the position in the ABS app.

## 10. Milestones

0. Spikes S1 to S6.
1. API additions and audiobook browsing.
2. Download, store and playlist.
3. KinAMP client and play/resume.
4. Progress sync (poll, throttle, final sync, suspend handling).
5. Polish: README, delete-local-files, error messages, release zip via the existing `.github/workflows/release.yml`.

## 11. Open questions

- Download folder: reuse the existing `download_dir`, with one subfolder per audiobook. KOReader's file browser may list audio files in that folder; unverified, and it's cosmetic only. A separate audiobook folder setting can be added if it gets in the way.
- Package the fork under a new name so it can sit beside the original plugin? The folder must stay `audiobookshelf.koplugin` for KOReader to load it, so this would mean replacing, not installing alongside.
- Upstream: send the generic parts (audio browsing, API additions) back to `naleo`, or keep the fork standalone? Check the upstream `LICENSE` before publishing.
- Multiple users or devices writing the same ABS item: out of scope for v1.
