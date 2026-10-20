# KinAMP spikes - results

Device: Kindle reporting as `KindleBasic4`, firmware 5.19.2.0.1, KinAMP 2.9 (beta), AirPods Pro. Recorded 2026-10-20 from the on-device runs and logs while building the plugin.

| # | Question | Result | Notes |
|---|---|---|---|
| S1 | Does KinAMP produce sound? | Pass, with a caveat | Sound only after the headset is disconnected and reconnected while audio is playing. KinAMP's own startup cycles the Bluetooth radio, which leaves the headset "connected" with a stale audio link. |
| S2 | Can another plugin use `kinamp_backend`? | Pass | `kinamp_backend` and `kinamp_bt` load from the Audiobookshelf plugin; `kinamp_backend` was already in `package.loaded`. |
| S3 | Seek latency on a long MP3 | About 19 s | Seeking about 33 minutes into a 77 minute, 32 kHz MP3 took about 19 s (audio manager log: new stream 19 s after the seek command). KinAMP seeks by restarting the file and decoding up to the position. |
| S4 | Status file while playing | Pass | `state`, `index` (1-based after `kinamp_backend`), `path`, `pos`, `dur` as expected; `pos` includes the seek offset. |
| S5 | ABS progress write | Accepted | `PATCH /api/me/progress/<id>` was accepted by the server (the plugin recorded the writes as synced). |
| S6 | Sleep/wake mid-playback | Not tested | |

## Acceptance (final build, 1.1.0)

Tested end to end on the device with a multi-file MP3 audiobook: browsing the library, download, Play (player started directly, headset reconnected once playback is running), resume at the Audiobookshelf position less 30 s, sound, and progress sync. A single M4B book was not tested.
