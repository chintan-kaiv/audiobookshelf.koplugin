## 1.2.0 (2026-10-20)

- Show the book's cover artwork at the top of the audiobook page.
- Show the same artwork in KinAMP's player while the book plays. The cover is saved as `cover.jpg` in the book's folder (fetched on download, or on the next Play for books downloaded earlier).

## 1.1.0 (2026-10-20)

- Start KinAMP's player directly, without KinAMP's own Bluetooth radio cycle and its "Preparing Bluetooth" popup.
- Reconnect the headset once playback is running (waits up to 3 minutes for a slow seek), so sound works after a fresh start.
- Show "Starting KinAMP..." while the player starts.

## 1.0.0 (2026-10-20)

Audiobooks: browse, download and play through KinAMP, with progress synced back to Audiobookshelf. Play resumes 30 seconds before the saved position, the book page shows the position and where playback will resume, and KinAMP's player opens when playback starts. Ebook behaviour is unchanged.

## 0.1.3 (2025-12-01)

Merged a PR with a bunch of error handling (#12)

## 0.1.2 (2025-04-26)

Fix issue #6 where if a book has an unsafe character in the filename.  This sanitizes the name using util.getSafeFilename

## 0.1.1 (2025-04-25)

Add search functionality

Allow user to update settings from plugin

## 0.1.0 (2025-04-14)

First functionality to allow user to download books

## 0.0.1 (2025-04-10)

Initial release
