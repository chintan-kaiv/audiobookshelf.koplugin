# Audiobook playback via KinAMP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From KOReader on a jailbroken Kindle, browse and download Audiobookshelf (ABS) audiobooks, play them through KinAMP, and sync listening progress back to ABS.

**Architecture:** The fork adds an "Audiobooks" path next to the existing ebook path. Pure-Lua modules (position mapping, progress policy, store, downloader, session) take their collaborators by injection and are unit-tested off-device with a tiny harness. Thin device-only adapters (ABS HTTP calls, KinAMP via its `kinamp_backend` module, KOReader UI) are verified by Lua syntax checks, the device spikes, and a manual on-device run.

**Tech Stack:** Lua (LuaJIT inside KOReader; Lua 5.4 for off-device tests), KOReader plugin API, ABS REST API, KinAMP's `kinamp_backend.lua`.

**Spec:** `docs/superpowers/specs/2026-10-19-audiobook-playback-kinamp-design.md`

## Global Constraints

- Plugin folder name stays `audiobookshelf.koplugin`; existing ebook browse/download behaviour must not change.
- Downloads reuse the plugin's existing `download_dir` setting, one subfolder per audiobook (`<download_dir>/<Title>/NNN-<name>` plus `book.m3u`).
- Pure modules (`positionmap`, `progresspolicy`, `absprogress`, `audiostore`, `audiodownloader`, `audiosession`) must run on both LuaJIT (Lua 5.1 semantics) and Lua 5.4: no `goto`, no `//`, no bitwise operators, no `table.unpack` without a fallback, no `utf8` library, use `math.floor`. They must not `require` any KOReader module at load time; collaborators are injected.
- `require` paths use slashes, matching the existing code: `require("audiobookshelf/positionmap")`.
- ABS is the source of truth for position at Play time; afterwards the Kindle writes. Progress is sent at most every 30 s and only if it moved by at least 10 s (1 s for a final sync).
- Never write a position of 0 to ABS while a previously sent position is greater than 0 (a seek restart can report `pos=0` for a tick).
- KinAMP is used only through its `kinamp_backend` module (`play_from_index`, `seek`, `stop`, `get_status`, `wait_until_running`). Status `index` is **1-based**. `play_from_index` overwrites KinAMP's internal queue; this is documented in the README.
- FAT limits on the Kindle volume: refuse any single file over 4294967295 bytes.
- Commit messages are conventional (`feat:`, `fix:`, `docs:`, `test:`, `chore:`), explain why, and end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Do not push, and do not merge into `master`, without the user saying so: pushes to `master` trigger the fork's release workflow.
- Deviation from the spec (decided while planning, from reading `kinamp_backend.lua`): v1 has no own FIFO implementation or status parser. `kinampclient.lua` wraps `kinamp_backend`; if spike S2 shows that module is not loadable from another plugin, stop and revise the plan.

## Review Focus

Inputs and conditions the spec implies that no single task's happy path exercises; each has a pinning test in the task named:

1. **Item with no usable audio** (ebook-only item, every file excluded/invalid/zero-length) must give "no audio" and never crash. — Task 2.
2. **ABS position out of range or finished** (negative, beyond total duration, `isFinished = true`, missing) must clamp or restart from 0, never seek into nothing. — Tasks 2 and 7.
3. **KinAMP daemon killed, stopped, or status stale mid-session** must produce no progress writes, and the session must end itself after 3 empty polls. — Tasks 3 and 7.
4. **Titles and filenames with slashes, colons, quotes, unicode, more than 120 bytes, or the same name twice** must give safe, unique, valid-UTF-8 paths. — Task 5.
5. **Position reads 0 right after a seek or restart** must not reset ABS progress. ABS unreachable during a sync must be retried next tick and fall back to the locally saved position on resume. — Tasks 3 and 7.

---

### Task 0: Branch, test harness, Lua

**Files:**
- Create: `tests/harness.lua`
- Create: `tests/run.lua`

**Interfaces:**
- Produces: `tests/harness.lua` exports `test(name, fn)`, `eq(actual, expected, msg)`, `truthy(v, msg)`, `run() -> boolean`. `lua tests/run.lua` (from repo root) runs every `tests/test_*.lua` and exits non-zero on failure.

- [ ] **Step 1: Work on a feature branch so `master` stays releasable**

The spec and plan commits currently sit on local `master` (ahead of `origin/master`). Move them to a branch and put `master` back:

```bash
cd audiobookshelf.koplugin
git branch feature/audio-playback-kinamp
git switch feature/audio-playback-kinamp
git branch -f master origin/master
git log --oneline -4
```

Expected: the spec commits are on `feature/audio-playback-kinamp`; `git branch -vv` shows `master` equal to `origin/master`.

- [ ] **Step 2: Install Lua for off-device tests**

```bash
brew install lua
lua -v
```

Expected: `Lua 5.4.x`.

- [ ] **Step 3: Write the harness**

`tests/harness.lua`:

```lua
local H = { tests = {}, passed = 0, failures = 0 }

local function show(v)
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(x) end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(v)
end

function H.test(name, fn)
    H.tests[#H.tests + 1] = { name = name, fn = fn }
end

function H.eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "values differ") .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
    end
end

function H.truthy(v, msg)
    if not v then error(msg or "expected a truthy value", 2) end
end

function H.run()
    for _, t in ipairs(H.tests) do
        local ok, err = pcall(t.fn)
        if ok then
            H.passed = H.passed + 1
            print("PASS " .. t.name)
        else
            H.failures = H.failures + 1
            print("FAIL " .. t.name .. "\n     " .. tostring(err))
        end
    end
    print(string.format("%d passed, %d failed", H.passed, H.failures))
    return H.failures == 0
end

return H
```

`tests/run.lua`:

```lua
package.path = "./?.lua;./tests/?.lua;" .. package.path
local H = require("harness")
for file in io.popen("ls tests/test_*.lua"):lines() do
    dofile(file)
end
os.exit(H.run() and 0 or 1)
```

- [ ] **Step 4: Prove the harness catches failures**

Create a throwaway `tests/test_zz_sanity.lua`:

```lua
local H = require("harness")
H.test("sanity passes", function() H.eq(1 + 1, 2) end)
H.test("sanity fails", function() H.eq(1 + 1, 3) end)
```

Run: `lua tests/run.lua; echo "exit=$?"`
Expected: one PASS, one FAIL, `1 passed, 1 failed`, `exit=1`.

Then delete it: `rm tests/test_zz_sanity.lua` and run `lua tests/run.lua; echo "exit=$?"` — Expected: `0 passed, 0 failed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/harness.lua tests/run.lua
git commit -m "test: add a dependency-free Lua test harness

Why: pure logic (position mapping, sync policy) must be verifiable off-device
without busted/luarocks.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 1: Device spikes (manual gate)

This task is run by the user on the Kindle; the agent prepares the material and records results. **S1 gates everything.**

**Files:**
- Create: `docs/superpowers/spikes/2026-10-19-kinamp-spikes.md`
- Create (on device only, throwaway): `koreader/plugins/kinampspike.koplugin/_meta.lua`, `koreader/plugins/kinampspike.koplugin/main.lua`

**Interfaces:**
- Produces: a results file that later tasks read. Decisions it must record: S1 pass/fail, S2 pass/fail, S3 seek latency, S4 status sample, S5 ABS endpoint behaviour, S6 sleep behaviour.

- [ ] **Step 1: Write the spike results template**

`docs/superpowers/spikes/2026-10-19-kinamp-spikes.md`:

```markdown
# KinAMP spikes — results

Device: KindleBasic4, firmware 5.19.2.0.1, KinAMP version: ____ , date: ____

| # | Question | Result | Notes |
|---|---|---|---|
| S1 | Does KinAMP produce sound for an MP3 and an M4B? | | |
| S2 | Can another plugin `require("kinamp_backend")` and read status? | | |
| S3 | Seconds from `seek 7200` on a multi-hour M4B until audio resumes | | |
| S4 | Status sample while playing a multi-file playlist (paste the file) | | |
| S5 | ABS `PATCH /api/me/progress/<id>` accepted? Visible in ABS app? | | |
| S6 | Position correct after sleep/wake mid-playback? Poll timer alive? | | |

Gate: S1 must pass. S2 must pass or the plan is revised (see Global Constraints).
```

- [ ] **Step 2: S1 — sound.** Copy one MP3 and one M4B to the Kindle (for example `/mnt/us/music/`). Open KinAMP, connect Bluetooth or headphones, play each. Record pass/fail. **Stop here and tell the user if S1 fails.**

- [ ] **Step 3: S2 — second-plugin access.** On the Kindle create `koreader/plugins/kinampspike.koplugin/_meta.lua`:

```lua
local _ = require("gettext")
return {
    name = "kinampspike",
    fullname = _("KinAMP spike"),
    description = _("Throwaway spike."),
}
```

and `main.lua`:

```lua
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Spike = WidgetContainer:extend{ name = "kinampspike", is_doc_only = false }

function Spike:init()
    self.ui.menu:registerToMainMenu(self)
end

function Spike:addToMainMenu(menu_items)
    menu_items.kinampspike = {
        text = "KinAMP spike",
        sorting_hint = "tools",
        callback = function()
            local ok, B = pcall(require, "kinamp_backend")
            local lines = { "require kinamp_backend: " .. tostring(ok) }
            if ok then
                lines[#lines + 1] = "running: " .. tostring(B.is_running())
                local s = B.get_status()
                if s then
                    for k, v in pairs(s) do lines[#lines + 1] = k .. "=" .. tostring(v) end
                end
            else
                lines[#lines + 1] = tostring(B)
            end
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        end,
    }
end

return Spike
```

Restart KOReader, start KinAMP playing, open Tools → KinAMP spike. Record the output. Pass means `require kinamp_backend: true` and `running: true` with `pos=` changing between presses.

- [ ] **Step 4: S3/S4 — seek latency and status sample.** In KOReader use Tools → Terminal emulator (or SSH). Make a small playlist of 3 MP3s: `ls /mnt/us/music/*.mp3 > /tmp/spike.m3u`. Then:

```sh
echo "load /tmp/spike.m3u" > /tmp/kinamp_cmd
echo "index 1" > /tmp/kinamp_cmd
cat /tmp/kinamp_status        # S4: paste this into the results file
echo "seek 7200" > /tmp/kinamp_cmd   # use a long M4B loaded the same way; time until audio resumes (S3)
```

(`/tmp/` is KinAMP's default runtime directory; if `KINAMP_RUNTIME_DIR` is set, use that.)

- [ ] **Step 5: S5 — ABS progress endpoint.** From the Mac, with a real library item id and your ABS token in the environment:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X PATCH \
  -H "Authorization: Bearer $ABS_TOKEN" -H "Content-Type: application/json" \
  -d '{"currentTime":120,"duration":3600,"progress":0.0333,"isFinished":false}' \
  "$ABS_URL/api/me/progress/$ITEM_ID"
curl -s -H "Authorization: Bearer $ABS_TOKEN" "$ABS_URL/api/me/progress/$ITEM_ID"
```

Expected: `200`, then JSON containing `"currentTime":120`; the ABS app shows the book at 2:00. Also `GET` an item with no progress and note the status code (the plan assumes `404`).

- [ ] **Step 6: S6 — sleep.** Play a book, put the Kindle to sleep for a minute, wake it, open the spike menu again; record whether `pos` is sane and the daemon still runs.

- [ ] **Step 7: Record results and commit**

```bash
git add docs/superpowers/spikes/2026-10-19-kinamp-spikes.md
git commit -m "docs: record KinAMP and ABS spike results

Why: S1 gates the whole feature and S2 decides whether we can depend on
kinamp_backend.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Position mapping

**Files:**
- Create: `audiobookshelf/positionmap.lua`
- Test: `tests/test_positionmap.lua`

**Interfaces:**
- Produces:
  - `PositionMap.buildTracks(item) -> tracks, total` — `item` is an ABS expanded item (`item.media.audioFiles`); `tracks` is an array of `{ino, name, size, duration, startOffset}` in play order; `total` is the summed duration in seconds. Skips files with `exclude`, `invalid`, or a missing/zero duration. Returns `{}, 0` for anything without audio.
  - `PositionMap.toTrackPos(tracks, seconds) -> index, offset` — `index` is **1-based**, `offset` is whole seconds into that track; clamps `seconds` into `[0, total]`; returns `nil` for an empty `tracks`.
  - `PositionMap.toGlobal(tracks, index, pos) -> seconds|nil` — inverse; `nil` if `index` is not a track; clamps `pos` into `[0, duration]`.

- [ ] **Step 1: Write the failing tests**

`tests/test_positionmap.lua`:

```lua
local H = require("harness")
local PM = require("audiobookshelf/positionmap")

local function item(files) return { media = { audioFiles = files } } end
local function f(index, duration, extra)
    local t = {
        index = index, ino = "ino" .. index, duration = duration,
        metadata = { filename = "f" .. index .. ".mp3", size = 1000 * index },
    }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

H.test("buildTracks orders by index and accumulates offsets", function()
    local tracks, total = PM.buildTracks(item({ f(2, 50), f(1, 100), f(3, 25) }))
    H.eq(#tracks, 3)
    H.eq(tracks[1].ino, "ino1")
    H.eq(tracks[1].startOffset, 0)
    H.eq(tracks[2].startOffset, 100)
    H.eq(tracks[3].startOffset, 150)
    H.eq(total, 175)
    H.eq(tracks[2].name, "f2.mp3")
    H.eq(tracks[2].size, 2000)
end)

H.test("buildTracks skips excluded, invalid, zero and missing duration", function()
    local tracks, total = PM.buildTracks(item({
        f(1, 100), f(2, 50, { exclude = true }), f(3, 50, { invalid = true }),
        f(4, 0), f(5, nil), f(6, 10),
    }))
    H.eq(#tracks, 2)
    H.eq(total, 110)
    H.eq(tracks[2].ino, "ino6")
end)

H.test("buildTracks gives empty result for items with no audio", function()
    local t1, n1 = PM.buildTracks(item({}))
    H.eq(#t1, 0); H.eq(n1, 0)
    local t2, n2 = PM.buildTracks({ media = {} })
    H.eq(#t2, 0); H.eq(n2, 0)
    local t3, n3 = PM.buildTracks(nil)
    H.eq(#t3, 0); H.eq(n3, 0)
end)

local tracks = PM.buildTracks(item({ f(1, 100), f(2, 100) }))

H.test("toTrackPos maps inside a track", function()
    local i, o = PM.toTrackPos(tracks, 130)
    H.eq(i, 2); H.eq(o, 30)
end)

H.test("toTrackPos puts an exact boundary at the start of the next track", function()
    local i, o = PM.toTrackPos(tracks, 100)
    H.eq(i, 2); H.eq(o, 0)
end)

H.test("toTrackPos clamps negative, beyond-total and garbage input", function()
    local i, o = PM.toTrackPos(tracks, -5)
    H.eq(i, 1); H.eq(o, 0)
    i, o = PM.toTrackPos(tracks, 9999)
    H.eq(i, 2); H.eq(o, 100)
    i, o = PM.toTrackPos(tracks, "abc")
    H.eq(i, 1); H.eq(o, 0)
    i, o = PM.toTrackPos(tracks, nil)
    H.eq(i, 1); H.eq(o, 0)
end)

H.test("toTrackPos returns nil for no tracks", function()
    H.eq(PM.toTrackPos({}, 10), nil)
end)

H.test("toGlobal adds the start offset", function()
    H.eq(PM.toGlobal(tracks, 2, 30), 130)
    H.eq(PM.toGlobal(tracks, 1, 0), 0)
end)

H.test("toGlobal clamps pos and rejects unknown tracks", function()
    H.eq(PM.toGlobal(tracks, 1, 500), 100)
    H.eq(PM.toGlobal(tracks, 1, -3), 0)
    H.eq(PM.toGlobal(tracks, 3, 10), nil)
    H.eq(PM.toGlobal(tracks, nil, 10), nil)
end)

H.test("round trip", function()
    local i, o = PM.toTrackPos(tracks, 175)
    H.eq(PM.toGlobal(tracks, i, o), 175)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/run.lua`
Expected: FAIL with `module 'audiobookshelf/positionmap' not found`.

- [ ] **Step 3: Implement**

`audiobookshelf/positionmap.lua`:

```lua
-- Pure position arithmetic for multi-file audiobooks. No KOReader modules here.
local M = {}

function M.buildTracks(item)
    local files = (type(item) == "table" and item.media and item.media.audioFiles) or {}
    local usable = {}
    for _, f in ipairs(files) do
        if type(f) == "table" and not f.exclude and not f.invalid
            and type(f.duration) == "number" and f.duration > 0 then
            usable[#usable + 1] = f
        end
    end
    table.sort(usable, function(a, b)
        local ai, bi = a.index or 0, b.index or 0
        if ai ~= bi then return ai < bi end
        local an = (a.metadata and a.metadata.filename) or ""
        local bn = (b.metadata and b.metadata.filename) or ""
        return an < bn
    end)
    local tracks, offset = {}, 0
    for i, f in ipairs(usable) do
        local meta = f.metadata or {}
        tracks[i] = {
            ino = f.ino,
            name = meta.filename or ("track" .. i),
            size = meta.size,
            duration = f.duration,
            startOffset = offset,
        }
        offset = offset + f.duration
    end
    return tracks, offset
end

-- seconds into the whole book -> (1-based track index, whole seconds into it)
function M.toTrackPos(tracks, seconds)
    local n = #tracks
    if n == 0 then return nil end
    local total = tracks[n].startOffset + tracks[n].duration
    seconds = tonumber(seconds) or 0
    if seconds < 0 then seconds = 0 end
    if seconds > total then seconds = total end
    for i = n, 1, -1 do
        local t = tracks[i]
        if seconds >= t.startOffset then
            local offset = seconds - t.startOffset
            if offset > t.duration then offset = t.duration end
            return i, math.floor(offset)
        end
    end
    return 1, 0
end

-- (1-based track index, seconds into that track) -> seconds into the whole book
function M.toGlobal(tracks, index, pos)
    local t = index and tracks[index]
    if not t then return nil end
    pos = tonumber(pos) or 0
    if pos < 0 then pos = 0 end
    if pos > t.duration then pos = t.duration end
    return t.startOffset + pos
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `lua tests/run.lua`
Expected: all PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/positionmap.lua tests/test_positionmap.lua
git commit -m "feat: add pure position mapping for multi-file audiobooks

Why: ABS stores one position per book while KinAMP reports file index plus
seconds, so every sync needs a tested conversion in both directions.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Progress policy

**Files:**
- Create: `audiobookshelf/progresspolicy.lua`
- Test: `tests/test_progresspolicy.lua`

**Interfaces:**
- Consumes: `PositionMap.toGlobal(tracks, index, pos)` from Task 2.
- Produces: `Policy.decide(o) -> position|nil, reason` where `o = {status, tracks, paths, last_sent, min_delta}`. `status` is what `kinamp_backend.get_status()` returns (or `nil`): `is_playing`, `is_paused`, `index` (1-based), `path`, `pos`. `paths` is the array of absolute track paths (same order as `tracks`). `min_delta` defaults to `Policy.DEFAULT_MIN_DELTA` (10). Reasons: `"no_daemon"`, `"not_active"`, `"no_track"`, `"path_mismatch"`, `"zero_after_progress"`, `"below_threshold"`.

- [ ] **Step 1: Write the failing tests**

`tests/test_progresspolicy.lua`:

```lua
local H = require("harness")
local Policy = require("audiobookshelf/progresspolicy")

local tracks = { { startOffset = 0, duration = 100 }, { startOffset = 100, duration = 100 } }
local paths = { "/b/1.mp3", "/b/2.mp3" }

local function status(index, pos, state)
    return {
        is_playing = state == nil or state == "playing",
        is_paused = state == "paused",
        index = index, path = paths[index], pos = pos,
    }
end

local function decide(st, last, min_delta)
    return Policy.decide({ status = st, tracks = tracks, paths = paths, last_sent = last, min_delta = min_delta })
end

H.test("no status means no daemon", function()
    local pos, why = decide(nil, nil)
    H.eq(pos, nil); H.eq(why, "no_daemon")
end)

H.test("stopped daemon is not active", function()
    local st = status(1, 5); st.is_playing = false; st.is_paused = false
    local pos, why = decide(st, nil)
    H.eq(pos, nil); H.eq(why, "not_active")
end)

H.test("paused counts as active", function()
    H.eq(decide(status(2, 30, "paused"), nil), 130)
end)

H.test("no track index", function()
    local st = status(1, 5); st.index = nil
    local pos, why = decide(st, nil)
    H.eq(pos, nil); H.eq(why, "no_track")
end)

H.test("path that is not ours is ignored", function()
    local st = status(1, 5); st.path = "/music/other.mp3"
    local pos, why = decide(st, nil)
    H.eq(pos, nil); H.eq(why, "path_mismatch")
end)

H.test("first reading is sent", function()
    H.eq(decide(status(1, 42), nil), 42)
end)

H.test("movement below the threshold is not sent", function()
    local pos, why = decide(status(1, 45), 40)
    H.eq(pos, nil); H.eq(why, "below_threshold")
end)

H.test("movement at the threshold is sent, forward or back", function()
    H.eq(decide(status(1, 50), 40), 50)
    H.eq(decide(status(1, 30), 40), 30)
end)

H.test("a forced sync uses a smaller threshold", function()
    H.eq(decide(status(1, 45), 40, 1), 45)
end)

H.test("zero right after progress is ignored", function()
    local pos, why = decide(status(1, 0), 120)
    H.eq(pos, nil); H.eq(why, "zero_after_progress")
end)

H.test("zero is fine when nothing was sent yet or last was zero", function()
    H.eq(decide(status(1, 0), nil), 0)
    H.eq(decide(status(1, 0), 0, 0), 0)
end)

H.test("missing pos is treated as zero and guarded the same way", function()
    local st = status(1, nil)
    local pos, why = decide(st, 120)
    H.eq(pos, nil); H.eq(why, "zero_after_progress")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/run.lua`
Expected: FAIL `module 'audiobookshelf/progresspolicy' not found`.

- [ ] **Step 3: Implement**

`audiobookshelf/progresspolicy.lua`:

```lua
-- Decides whether the player's current position should be sent to ABS.
local PositionMap = require("audiobookshelf/positionmap")

local M = { DEFAULT_MIN_DELTA = 10 }

function M.decide(o)
    local s = o.status
    if not s then return nil, "no_daemon" end
    if not (s.is_playing or s.is_paused) then return nil, "not_active" end
    if not s.index then return nil, "no_track" end
    local expected = o.paths[s.index]
    if not expected or s.path ~= expected then return nil, "path_mismatch" end
    local global = PositionMap.toGlobal(o.tracks, s.index, s.pos)
    if not global then return nil, "no_track" end
    local last = o.last_sent
    -- A restart after a seek can report pos=0 for a tick; never let that reset ABS.
    if global == 0 and last and last > 0 then return nil, "zero_after_progress" end
    if last and math.abs(global - last) < (o.min_delta or M.DEFAULT_MIN_DELTA) then
        return nil, "below_threshold"
    end
    return global
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `lua tests/run.lua`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/progresspolicy.lua tests/test_progresspolicy.lua
git commit -m "feat: add progress policy deciding when to send position to ABS

Why: stopped daemons, foreign tracks and the pos=0 blip after a seek must
never overwrite real listening progress.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: ABS progress body

**Files:**
- Create: `audiobookshelf/absprogress.lua`
- Test: `tests/test_absprogress.lua`

**Interfaces:**
- Produces: `AbsProgress.body(current, duration) -> {currentTime, duration, progress, isFinished}`. Clamps `current` into `[0, duration]` when duration is known; `isFinished` is true when at most `AbsProgress.FINISHED_WITHIN` (10) seconds remain; `progress` is `current/duration` (0 if unknown).

- [ ] **Step 1: Write the failing tests**

`tests/test_absprogress.lua`:

```lua
local H = require("harness")
local AP = require("audiobookshelf/absprogress")

H.test("midway body", function()
    local b = AP.body(50, 200)
    H.eq(b.currentTime, 50); H.eq(b.duration, 200)
    H.eq(b.progress, 0.25); H.eq(b.isFinished, false)
end)

H.test("near the end is finished", function()
    H.eq(AP.body(195, 200).isFinished, true)
    H.eq(AP.body(189, 200).isFinished, false)
end)

H.test("clamps beyond duration and below zero", function()
    local b = AP.body(250, 200)
    H.eq(b.currentTime, 200); H.eq(b.progress, 1)
    H.eq(AP.body(-4, 200).currentTime, 0)
end)

H.test("unknown duration gives zero progress and not finished", function()
    local b = AP.body(30, 0)
    H.eq(b.progress, 0); H.eq(b.isFinished, false); H.eq(b.currentTime, 30)
    H.eq(AP.body(nil, nil).currentTime, 0)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/run.lua`
Expected: FAIL `module 'audiobookshelf/absprogress' not found`.

- [ ] **Step 3: Implement**

`audiobookshelf/absprogress.lua`:

```lua
local M = { FINISHED_WITHIN = 10 }

function M.body(current, duration)
    duration = tonumber(duration) or 0
    current = tonumber(current) or 0
    if duration < 0 then duration = 0 end
    if current < 0 then current = 0 end
    if duration > 0 and current > duration then current = duration end
    local progress = 0
    if duration > 0 then progress = current / duration end
    return {
        currentTime = current,
        duration = duration,
        progress = progress,
        isFinished = duration > 0 and (duration - current) <= M.FINISHED_WITHIN,
    }
end

return M
```

- [ ] **Step 4: Run to verify pass**

Run: `lua tests/run.lua`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/absprogress.lua tests/test_absprogress.lua
git commit -m "feat: add ABS progress body builder

Why: one place decides clamping and the finished threshold so every write to
ABS is well-formed.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Audio store

**Files:**
- Create: `audiobookshelf/audiostore.lua`
- Test: `tests/test_audiostore.lua`

**Interfaces:**
- Produces (all pure; persistence goes through an injected `settings` object with `readSetting(key)`, `saveSetting(key, value)`, `flush()`):
  - `Store.sanitize(name) -> string` — replaces control characters and `/ \ : * ? " < > |` with `_`, trims, strips leading dots, caps at 120 bytes on a UTF-8 character boundary, falls back to `"audiobook"`.
  - `Store.trackFilename(index, name) -> string` — `string.format("%03d-%s", index, <sanitized stem>) .. <extension>`; keeps the extension, stem capped at 100 bytes.
  - `Store.buildM3u(paths) -> string` — `#EXTM3U` header plus one path per line, newlines stripped from paths.
  - `Store.makeEntry(item_id, title, author, dir, tracks, total) -> entry` — `tracks` as returned by `PositionMap.buildTracks`; entry is `{item_id, title, author, dir, tracks = {{ino, name, size, duration, startOffset, filename, path}}, total, m3u = dir .. "/book.m3u", complete = false}`.
  - `Store.paths(entry) -> {path, ...}` in track order.
  - `Store.new(settings) -> store` with methods `:get(item_id)`, `:put(entry)`, `:remove(item_id)`, `:setLastSent(item_id, seconds)`, `:dirFor(download_dir, title, item_id) -> dir` (appends ` (<first 8 chars of item_id>)` if a different item already uses the same dir).

- [ ] **Step 1: Write the failing tests**

`tests/test_audiostore.lua`:

```lua
local H = require("harness")
local Store = require("audiobookshelf/audiostore")

local function fakeSettings()
    local data = {}
    return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function() end,
    }
end

H.test("sanitize replaces unsafe characters", function()
    H.eq(Store.sanitize('A/B:C*D?E"F<G>H|I\\J'), "A_B_C_D_E_F_G_H_I_J")
    H.eq(Store.sanitize("tab\there"), "tab_here")
end)

H.test("sanitize trims, strips leading dots and falls back", function()
    H.eq(Store.sanitize("  hello  "), "hello")
    H.eq(Store.sanitize("..hidden"), "hidden")
    H.eq(Store.sanitize(""), "audiobook")
    H.eq(Store.sanitize(nil), "audiobook")
    H.eq(Store.sanitize("..."), "audiobook")
end)

H.test("sanitize caps long unicode names on a character boundary", function()
    local name = Store.sanitize(string.rep("\195\169", 200)) -- 200 x "e acute", 2 bytes each
    H.truthy(#name <= 120, "too long")
    H.eq(#name % 2, 0, "cut a character in half")
end)

H.test("trackFilename pads the index and keeps the extension", function()
    H.eq(Store.trackFilename(1, "Chapter 1.mp3"), "001-Chapter 1.mp3")
    H.eq(Store.trackFilename(12, "dir/sub/x:y.m4b"), "012-x_y.m4b")
    H.eq(Store.trackFilename(3, nil), "003-track")
end)

H.test("trackFilename gives the same name different files for different indexes", function()
    H.truthy(Store.trackFilename(1, "same.mp3") ~= Store.trackFilename(2, "same.mp3"))
end)

H.test("buildM3u writes a header and one path per line", function()
    H.eq(Store.buildM3u({ "/a/1.mp3", "/a/2.mp3" }), "#EXTM3U\n/a/1.mp3\n/a/2.mp3\n")
    H.eq(Store.buildM3u({ "/a/bad\nname.mp3" }), "#EXTM3U\n/a/badname.mp3\n")
end)

local tracks = {
    { ino = "a", name = "a.mp3", size = 10, duration = 100, startOffset = 0 },
    { ino = "b", name = "b.mp3", size = 20, duration = 50, startOffset = 100 },
}

H.test("makeEntry assigns filenames and absolute paths", function()
    local e = Store.makeEntry("item1", "Book", "Author", "/d/Book", tracks, 150)
    H.eq(e.item_id, "item1"); H.eq(e.total, 150); H.eq(e.complete, false)
    H.eq(e.m3u, "/d/Book/book.m3u")
    H.eq(e.tracks[2].path, "/d/Book/002-b.mp3")
    H.eq(e.tracks[2].startOffset, 100)
    local p = Store.paths(e)
    H.eq(#p, 2); H.eq(p[1], "/d/Book/001-a.mp3")
end)

H.test("store persists, updates last_sent and removes", function()
    local s = Store.new(fakeSettings())
    local e = Store.makeEntry("item1", "Book", "A", "/d/Book", tracks, 150)
    s:put(e)
    H.eq(s:get("item1").title, "Book")
    s:setLastSent("item1", 77)
    H.eq(s:get("item1").last_sent, 77)
    s:setLastSent("missing", 5) -- no entry: must not create one
    H.eq(s:get("missing"), nil)
    s:remove("item1")
    H.eq(s:get("item1"), nil)
end)

H.test("dirFor trims slashes and disambiguates clashing titles", function()
    local s = Store.new(fakeSettings())
    H.eq(s:dirFor("/d//", "Book", "id-one"), "/d/Book")
    s:put(Store.makeEntry("id-one", "Book", "A", "/d/Book", tracks, 150))
    H.eq(s:dirFor("/d", "Book", "id-one"), "/d/Book")
    H.eq(s:dirFor("/d", "Book", "id-two-xyz"), "/d/Book (id-two-x)")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/run.lua`
Expected: FAIL `module 'audiobookshelf/audiostore' not found`.

- [ ] **Step 3: Implement**

`audiobookshelf/audiostore.lua`:

```lua
-- Where downloaded audiobooks live and what we know about them. Pure: the
-- settings object (LuaSettings on device) is injected.
local Store = {}
Store.__index = Store

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Cut `s` to at most `max` bytes without splitting a UTF-8 character.
local function cut(s, max)
    if #s <= max then return s end
    local n = max
    while n > 0 do
        local b = s:byte(n + 1)
        if b and b >= 128 and b < 192 then n = n - 1 else break end
    end
    return s:sub(1, n)
end

function Store.sanitize(name)
    name = tostring(name or "")
    name = name:gsub("[%c/\\:%*%?\"<>|]", "_")
    name = trim(name)
    name = name:gsub("^%.+", "")
    name = trim(cut(name, 120))
    if name == "" then return "audiobook" end
    return name
end

function Store.trackFilename(index, name)
    local base = tostring(name or ""):match("([^/\\]+)$") or "track"
    local stem, ext = base:match("^(.*)(%.[%w]+)$")
    if not stem then stem, ext = base, "" end
    stem = trim(cut((stem:gsub("[%c/\\:%*%?\"<>|]", "_")), 100))
    if stem == "" then stem = "track" end
    return string.format("%03d-%s%s", index, stem, ext)
end

function Store.buildM3u(paths)
    local lines = { "#EXTM3U" }
    for _, p in ipairs(paths) do
        lines[#lines + 1] = (tostring(p):gsub("[\r\n]", ""))
    end
    return table.concat(lines, "\n") .. "\n"
end

function Store.makeEntry(item_id, title, author, dir, tracks, total)
    local out = {}
    for i, t in ipairs(tracks) do
        local filename = Store.trackFilename(i, t.name)
        out[i] = {
            ino = t.ino, name = t.name, size = t.size,
            duration = t.duration, startOffset = t.startOffset,
            filename = filename, path = dir .. "/" .. filename,
        }
    end
    return {
        item_id = item_id, title = title, author = author, dir = dir,
        tracks = out, total = total, m3u = dir .. "/book.m3u", complete = false,
    }
end

function Store.paths(entry)
    local p = {}
    for i, t in ipairs(entry.tracks) do p[i] = t.path end
    return p
end

function Store.new(settings)
    return setmetatable({ settings = settings }, Store)
end

function Store:_all()
    return self.settings:readSetting("audiobooks") or {}
end

function Store:get(item_id)
    return self:_all()[item_id]
end

function Store:put(entry)
    local all = self:_all()
    all[entry.item_id] = entry
    self.settings:saveSetting("audiobooks", all)
    self.settings:flush()
end

function Store:remove(item_id)
    local all = self:_all()
    all[item_id] = nil
    self.settings:saveSetting("audiobooks", all)
    self.settings:flush()
end

function Store:setLastSent(item_id, seconds)
    local e = self:get(item_id)
    if e then
        e.last_sent = seconds
        self:put(e)
    end
end

function Store:dirFor(download_dir, title, item_id)
    local base = (download_dir:gsub("/+$", "")) .. "/" .. Store.sanitize(title)
    for id, e in pairs(self:_all()) do
        if id ~= item_id and e.dir == base then
            return base .. " (" .. tostring(item_id):sub(1, 8) .. ")"
        end
    end
    return base
end

return Store
```

- [ ] **Step 4: Run to verify pass**

Run: `lua tests/run.lua`
Expected: all PASS. If a sanitize test fails, fix the code, not the test.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/audiostore.lua tests/test_audiostore.lua
git commit -m "feat: add audiobook store with safe, unique file and folder names

Why: ABS titles and filenames are arbitrary text; the Kindle volume is
FAT-style and KinAMP reads absolute paths from an m3u.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Downloader

**Files:**
- Create: `audiobookshelf/audiodownloader.lua`
- Test: `tests/test_audiodownloader.lua`

**Interfaces:**
- Consumes: `Store.buildM3u`, `Store.paths` (Task 5); `api:downloadFile(item_id, ino, filename, dir) -> http_code` (existing `AudiobookshelfApi`).
- Produces:
  - `Downloader.preflight(entry, free_bytes) -> true | nil, "file_too_large" | "no_space"` — `free_bytes` may be `nil` (unknown, skip the space check).
  - `Downloader.run(opts) -> true | nil, err` where `opts = {api, fs, entry, on_progress(i, n, track), cancelled() -> bool}` and `fs = {mkdir_p(dir), size(path), rename(a, b), remove(path), write(path, text)}`. Downloads each missing or wrong-size file to `<filename>.part`, verifies size when ABS gave one, renames into place, writes the m3u, and sets `entry.complete = true`. Errors: `"mkdir_failed"`, `"cancelled"`, `"download_failed:<code>"`, `"size_mismatch"`, `"rename_failed"`, `"m3u_failed"`.

- [ ] **Step 1: Write the failing tests**

`tests/test_audiodownloader.lua`:

```lua
local H = require("harness")
local Store = require("audiobookshelf/audiostore")
local Downloader = require("audiobookshelf/audiodownloader")

local tracks = {
    { ino = "a", name = "a.mp3", size = 10, duration = 100, startOffset = 0 },
    { ino = "b", name = "b.mp3", size = 20, duration = 50, startOffset = 100 },
}
local function newEntry() return Store.makeEntry("item1", "Book", "A", "/d/Book", tracks, 150) end

local function fakeFs(files)
    local fs = { files = files or {}, removed = {}, written = {} }
    function fs.mkdir_p(dir) fs.dir = dir; return true end
    function fs.size(path) return fs.files[path] end
    function fs.rename(a, b)
        if fs.files[a] == nil then return nil end
        fs.files[b] = fs.files[a]; fs.files[a] = nil
        return true
    end
    function fs.remove(path) fs.removed[#fs.removed + 1] = path; fs.files[path] = nil; return true end
    function fs.write(path, text) fs.written[path] = text; return true end
    return fs
end

local function fakeApi(fs, code, sizes)
    local api = { calls = {} }
    function api:downloadFile(id, ino, filename, dir)
        api.calls[#api.calls + 1] = ino .. ":" .. filename
        if code ~= 200 then return code end
        fs.files[dir .. "/" .. filename] = sizes[ino]
        return 200
    end
    return api
end

local SIZES = { a = 10, b = 20 }

H.test("downloads every missing file, writes the m3u and marks complete", function()
    local fs = fakeFs()
    local api = fakeApi(fs, 200, SIZES)
    local e = newEntry()
    local progress = {}
    local ok = Downloader.run({ api = api, fs = fs, entry = e,
        on_progress = function(i, n) progress[#progress + 1] = i .. "/" .. n end })
    H.eq(ok, true)
    H.eq(#api.calls, 2)
    H.eq(api.calls[1], "a:001-a.mp3.part")
    H.eq(fs.files["/d/Book/001-a.mp3"], 10)
    H.eq(fs.files["/d/Book/002-b.mp3"], 20)
    H.eq(fs.written["/d/Book/book.m3u"], "#EXTM3U\n/d/Book/001-a.mp3\n/d/Book/002-b.mp3\n")
    H.eq(e.complete, true)
    H.eq(progress[1], "1/2"); H.eq(progress[2], "2/2")
end)

H.test("skips files that are already complete", function()
    local fs = fakeFs({ ["/d/Book/001-a.mp3"] = 10 })
    local api = fakeApi(fs, 200, SIZES)
    H.eq(Downloader.run({ api = api, fs = fs, entry = newEntry() }), true)
    H.eq(#api.calls, 1)
    H.eq(api.calls[1], "b:002-b.mp3.part")
end)

H.test("replaces a file whose size is wrong", function()
    local fs = fakeFs({ ["/d/Book/001-a.mp3"] = 3 })
    local api = fakeApi(fs, 200, SIZES)
    H.eq(Downloader.run({ api = api, fs = fs, entry = newEntry() }), true)
    H.eq(fs.removed[1], "/d/Book/001-a.mp3")
    H.eq(fs.files["/d/Book/001-a.mp3"], 10)
end)

H.test("an http failure removes the partial file and reports the code", function()
    local fs = fakeFs()
    local api = fakeApi(fs, 500, SIZES)
    local e = newEntry()
    local ok, err = Downloader.run({ api = api, fs = fs, entry = e })
    H.eq(ok, nil); H.eq(err, "download_failed:500")
    H.eq(fs.removed[1], "/d/Book/001-a.mp3.part")
    H.eq(e.complete, false)
end)

H.test("a wrong downloaded size is rejected", function()
    local fs = fakeFs()
    local api = fakeApi(fs, 200, { a = 9, b = 20 })
    local ok, err = Downloader.run({ api = api, fs = fs, entry = newEntry() })
    H.eq(ok, nil); H.eq(err, "size_mismatch")
end)

H.test("cancelling stops before the next file", function()
    local fs = fakeFs()
    local api = fakeApi(fs, 200, SIZES)
    local ok, err = Downloader.run({ api = api, fs = fs, entry = newEntry(), cancelled = function() return true end })
    H.eq(ok, nil); H.eq(err, "cancelled")
    H.eq(#api.calls, 0)
end)

H.test("preflight refuses files over the FAT limit", function()
    local e = newEntry(); e.tracks[1].size = 4294967296
    local ok, err = Downloader.preflight(e, nil)
    H.eq(ok, nil); H.eq(err, "file_too_large")
end)

H.test("preflight refuses when there is not enough space, allows unknown space", function()
    local e = newEntry()
    local ok, err = Downloader.preflight(e, 29)
    H.eq(ok, nil); H.eq(err, "no_space")
    H.eq(Downloader.preflight(e, 30), true)
    H.eq(Downloader.preflight(e, nil), true)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/run.lua`
Expected: FAIL `module 'audiobookshelf/audiodownloader' not found`.

- [ ] **Step 3: Implement**

`audiobookshelf/audiodownloader.lua`:

```lua
-- Sequential, resumable (per file) download of one audiobook. Pure: the ABS
-- api and a small filesystem table are injected.
local Store = require("audiobookshelf/audiostore")

local Downloader = {}
local FAT_MAX = 4294967295

function Downloader.preflight(entry, free_bytes)
    local need = 0
    for _, t in ipairs(entry.tracks) do
        if t.size and t.size > FAT_MAX then return nil, "file_too_large" end
        if t.size then need = need + t.size end
    end
    if free_bytes and need > free_bytes then return nil, "no_space" end
    return true
end

function Downloader.run(opts)
    local entry, fs, api = opts.entry, opts.fs, opts.api
    if not fs.mkdir_p(entry.dir) then return nil, "mkdir_failed" end
    local n = #entry.tracks
    for i, t in ipairs(entry.tracks) do
        if opts.cancelled and opts.cancelled() then return nil, "cancelled" end
        if opts.on_progress then opts.on_progress(i, n, t) end
        local size = fs.size(t.path)
        local complete = size ~= nil and (t.size == nil or size == t.size)
        if not complete then
            if size ~= nil then fs.remove(t.path) end
            local part = t.filename .. ".part"
            local part_path = entry.dir .. "/" .. part
            local code = api:downloadFile(entry.item_id, t.ino, part, entry.dir)
            if code ~= 200 then
                fs.remove(part_path)
                return nil, "download_failed:" .. tostring(code)
            end
            if t.size and fs.size(part_path) ~= t.size then
                fs.remove(part_path)
                return nil, "size_mismatch"
            end
            if not fs.rename(part_path, t.path) then return nil, "rename_failed" end
        end
    end
    if not fs.write(entry.m3u, Store.buildM3u(Store.paths(entry))) then return nil, "m3u_failed" end
    entry.complete = true
    return true
end

return Downloader
```

- [ ] **Step 4: Run to verify pass**

Run: `lua tests/run.lua`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/audiodownloader.lua tests/test_audiodownloader.lua
git commit -m "feat: add resumable per-file audiobook downloader

Why: audiobooks are many large files; an interrupted download must resume at
the next incomplete file, and FAT limits must be checked up front.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Audio session (play, resume, sync)

**Files:**
- Create: `audiobookshelf/audiosession.lua`
- Test: `tests/test_audiosession.lua`

**Interfaces:**
- Consumes: `PositionMap.toTrackPos`, `Policy.decide`, `AbsProgress.body`, `Store.paths`, a store with `:setLastSent`.
- Produces: `Session.new(deps) -> session` where `deps = {api, store, kinamp, sched, notify}`:
  - `api:getProgress(item_id) -> table|nil, code` (404 = no progress yet; any other `nil` = unreachable); `api:setProgress(item_id, body) -> boolean`.
  - `kinamp = {available() -> bool, playFromIndex(index1, paths) -> bool (true = commands were sent to a running daemon), seek(seconds), stop(), getStatus() -> status|nil, waitUntilRunning(cb(bool))}`.
  - `sched = {scheduleIn(seconds, fn), unschedule(fn)}`; `notify(message)`.
  - Methods: `:start(entry) -> true[, "offline"] | nil, "kinamp_missing"|"no_tracks"`, `:stop()`, `:detach()`, `:suspend()`, `:resume()`, `:syncNow() -> position|nil, reason`, `:isActive(item_id?) -> bool`. Constants: `Session.TICK_SECONDS = 30`, `Session.MAX_MISSES = 3`.

- [ ] **Step 1: Write the failing tests**

`tests/test_audiosession.lua`:

```lua
local H = require("harness")
local Store = require("audiobookshelf/audiostore")
local Session = require("audiobookshelf/audiosession")

local tracks = {
    { ino = "a", name = "a.mp3", size = 10, duration = 100, startOffset = 0 },
    { ino = "b", name = "b.mp3", size = 20, duration = 100, startOffset = 100 },
}
local function newEntry() return Store.makeEntry("item1", "Book", "A", "/d/Book", tracks, 200) end
local paths = Store.paths(newEntry())

local function fakeSettings()
    local data = {}
    return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function() end,
    }
end

local function st(index, pos, paused)
    return { is_playing = not paused, is_paused = paused or false, index = index, path = paths[index], pos = pos }
end

local function setup(o)
    o = o or {}
    local w = { played = {}, seeks = {}, stops = 0, progress = {}, notes = {}, scheduled = {}, status = o.status,
                remote = o.remote, remote_code = o.remote_code, fail = o.fail, running = o.running ~= false,
                starts = o.starts ~= false }
    local store = Store.new(fakeSettings())
    w.entry = newEntry() -- a fresh copy per test: the store mutates it (last_sent)
    store:put(w.entry)
    if o.last_sent then store:setLastSent("item1", o.last_sent) end
    w.store = store
    local kinamp = {
        available = function() return o.available ~= false end,
        playFromIndex = function(index, p) w.played[#w.played + 1] = { index = index, paths = p }; return w.running end,
        seek = function(s) w.seeks[#w.seeks + 1] = s end,
        stop = function() w.stops = w.stops + 1 end,
        getStatus = function() return w.status end,
        waitUntilRunning = function(cb) cb(w.starts) end,
    }
    local api = {
        getProgress = function() return w.remote, w.remote_code end,
        setProgress = function(_, id, body) w.progress[#w.progress + 1] = body; return not w.fail end,
    }
    local sched = {
        scheduleIn = function(s, fn) w.scheduled[#w.scheduled + 1] = { s = s, fn = fn } end,
        unschedule = function(fn)
            for i = #w.scheduled, 1, -1 do
                if w.scheduled[i].fn == fn then table.remove(w.scheduled, i) end
            end
        end,
    }
    w.session = Session.new({ api = api, store = store, kinamp = kinamp, sched = sched,
                              notify = function(m) w.notes[#w.notes + 1] = m end })
    function w.runNext()
        local item = table.remove(w.scheduled, 1)
        item.fn()
    end
    return w
end

H.test("start resumes from the ABS position", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    H.eq(w.session:start(w.entry), true)
    H.eq(w.played[1].index, 2)
    H.eq(w.played[1].paths[2], "/d/Book/002-b.mp3")
    w.runNext() -- seek step
    H.eq(w.seeks[1], 30)
    H.eq(w.session:isActive("item1"), true)
    H.eq(w.session:isActive("other"), false)
end)

H.test("a finished book restarts from the beginning", function()
    local w = setup({ remote = { currentTime = 199, isFinished = true }, remote_code = 200 })
    w.session:start(w.entry)
    H.eq(w.played[1].index, 1)
    w.runNext()
    H.eq(#w.seeks, 0) -- offset 0: no seek needed
end)

H.test("an out-of-range ABS position is clamped", function()
    local w = setup({ remote = { currentTime = 99999 }, remote_code = 200 })
    w.session:start(w.entry)
    H.eq(w.played[1].index, 2)
    w.runNext()
    H.eq(w.seeks[1], 100)
end)

H.test("no progress yet (404) starts at zero without an offline note", function()
    local w = setup({ remote = nil, remote_code = 404 })
    local ok, note = w.session:start(w.entry)
    H.eq(ok, true); H.eq(note, nil)
    H.eq(w.played[1].index, 1)
end)

H.test("unreachable ABS falls back to the saved position and says so", function()
    local w = setup({ remote = nil, remote_code = nil, last_sent = 150 })
    local _, note = w.session:start(w.entry)
    H.eq(note, "offline")
    H.eq(w.played[1].index, 2)
    w.runNext()
    H.eq(w.seeks[1], 50)
end)

H.test("cold start waits for the daemon before seeking", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200, running = false })
    w.session:start(w.entry)
    w.runNext() -- scheduled by waitUntilRunning callback
    H.eq(w.seeks[1], 30)
end)

H.test("a daemon that never starts ends the session", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200, running = false, starts = false })
    w.session:start(w.entry)
    H.eq(w.session:isActive(), false)
    H.eq(#w.notes, 1)
end)

H.test("missing KinAMP is reported", function()
    local w = setup({ available = false })
    local ok, err = w.session:start(w.entry)
    H.eq(ok, nil); H.eq(err, "kinamp_missing")
end)

H.test("a tick sends progress once it moved far enough, then stays quiet", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext() -- seek step schedules the first tick
    w.status = st(2, 45) -- global 145, moved 15
    w.runNext()
    H.eq(#w.progress, 1)
    H.eq(w.progress[1].currentTime, 145)
    H.eq(w.store:get("item1").last_sent, 145)
    w.status = st(2, 48) -- moved 3: below threshold
    w.runNext()
    H.eq(#w.progress, 1)
end)

H.test("a failed ABS write is retried on the next tick and kept locally", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = st(2, 45)
    w.fail = true
    w.runNext()
    H.eq(#w.progress, 1)
    H.eq(w.store:get("item1").last_sent, 145) -- saved locally for offline resume
    w.fail = false
    w.runNext()
    H.eq(#w.progress, 2) -- retried
    H.eq(w.progress[2].currentTime, 145)
end)

H.test("pos 0 after a seek does not reset ABS", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = st(1, 0) -- global 0 right after progress was recorded at 130
    w.runNext()
    H.eq(#w.progress, 0)
end)

H.test("three ticks with no daemon end the session without writing", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = nil
    w.runNext(); w.runNext(); w.runNext()
    H.eq(w.session:isActive(), false)
    H.eq(#w.progress, 0)
    H.eq(#w.scheduled, 0)
end)

H.test("stop does a final sync with a small threshold then stops playback", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = st(2, 33) -- moved 3 s: below normal threshold, enough for a final sync
    w.session:stop()
    H.eq(#w.progress, 1)
    H.eq(w.progress[1].currentTime, 133)
    H.eq(w.stops, 1)
    H.eq(w.session:isActive(), false)
    H.eq(#w.scheduled, 0)
end)

H.test("detach syncs but leaves playback running", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = st(2, 60)
    w.session:detach()
    H.eq(#w.progress, 1)
    H.eq(w.stops, 0)
    H.eq(w.session:isActive(), false)
end)

H.test("suspend syncs and stops the timer, resume syncs and restarts it", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = st(2, 60)
    w.session:suspend()
    H.eq(#w.progress, 1)
    H.eq(#w.scheduled, 0)
    w.status = st(2, 90)
    w.session:resume()
    H.eq(#w.progress, 2)
    H.eq(#w.scheduled, 1)
end)

H.test("starting another book first syncs the previous one", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = st(2, 60)
    w.session:start(w.entry)
    H.eq(#w.progress, 1)
    H.eq(w.progress[1].currentTime, 160)
end)

H.test("syncNow reports the reason when there is nothing to send", function()
    local w = setup({ remote = { currentTime = 130 }, remote_code = 200 })
    w.session:start(w.entry)
    w.runNext()
    w.status = nil
    local pos, why = w.session:syncNow()
    H.eq(pos, nil); H.eq(why, "no_daemon")
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/run.lua`
Expected: FAIL `module 'audiobookshelf/audiosession' not found`.

- [ ] **Step 3: Implement**

`audiobookshelf/audiosession.lua`:

```lua
-- One active audiobook: starts playback at the right place and keeps ABS in
-- step with the player. All collaborators are injected (see Interfaces).
local PositionMap = require("audiobookshelf/positionmap")
local Policy = require("audiobookshelf/progresspolicy")
local AbsProgress = require("audiobookshelf/absprogress")
local Store = require("audiobookshelf/audiostore")

local Session = { TICK_SECONDS = 30, MAX_MISSES = 3 }
Session.__index = Session

function Session.new(deps)
    local self = setmetatable({ deps = deps, active = nil }, Session)
    self.tick_fn = function() self:_tick() end
    return self
end

function Session:isActive(item_id)
    return self.active ~= nil and (item_id == nil or self.active.entry.item_id == item_id)
end

function Session:_schedule()
    if not self.active then return end
    self.deps.sched.unschedule(self.tick_fn)
    self.deps.sched.scheduleIn(Session.TICK_SECONDS, self.tick_fn)
end

function Session:_end()
    self.deps.sched.unschedule(self.tick_fn)
    self.active = nil
end

function Session:_tick()
    if not self.active then return end
    self:_sync(false)
    self:_schedule()
end

function Session:_sync(force)
    local a = self.active
    if not a then return nil, "inactive" end
    local d = self.deps
    local pos, reason = Policy.decide({
        status = d.kinamp.getStatus(),
        tracks = a.entry.tracks,
        paths = a.paths,
        last_sent = a.last_sent,
        min_delta = force and 1 or nil,
    })
    if not pos then
        if reason == "no_daemon" then
            a.misses = a.misses + 1
            if a.misses >= Session.MAX_MISSES then self:_end() end
        else
            a.misses = 0
        end
        return nil, reason
    end
    a.misses = 0
    d.store:setLastSent(a.entry.item_id, pos) -- always keep it locally for offline resume
    if d.api:setProgress(a.entry.item_id, AbsProgress.body(pos, a.entry.total)) then
        a.last_sent = pos
        return pos
    end
    return nil, "offline"
end

function Session:start(entry)
    local d = self.deps
    if not d.kinamp.available() then return nil, "kinamp_missing" end
    if not entry or not entry.tracks or #entry.tracks == 0 then return nil, "no_tracks" end
    if self.active then
        self:_sync(true)
        self:_end()
    end

    local remote, code = d.api:getProgress(entry.item_id)
    local offline = (remote == nil and code ~= 404)
    local seconds, last_sent
    if remote and remote.isFinished then
        seconds, last_sent = 0, nil
    elseif remote and remote.currentTime then
        seconds, last_sent = remote.currentTime, remote.currentTime
    else
        seconds, last_sent = entry.last_sent or 0, entry.last_sent
    end

    local index, offset = PositionMap.toTrackPos(entry.tracks, seconds)
    local paths = Store.paths(entry)
    self.active = { entry = entry, paths = paths, last_sent = last_sent, misses = 0 }

    local function afterStart()
        if not self.active or self.active.entry ~= entry then return end
        if offset > 0 then d.kinamp.seek(offset) end
        self:_schedule()
    end

    if d.kinamp.playFromIndex(index, paths) then
        d.sched.scheduleIn(0.5, afterStart)
    else
        d.kinamp.waitUntilRunning(function(up)
            if up then
                d.sched.scheduleIn(1.0, afterStart)
            else
                self:_end()
                d.notify("KinAMP did not start.")
            end
        end)
    end
    return true, offline and "offline" or nil
end

function Session:stop()
    if not self.active then return end
    self:_sync(true)
    self:_end()
    self.deps.kinamp.stop()
end

function Session:detach()
    if not self.active then return end
    self:_sync(true)
    self:_end()
end

function Session:suspend()
    if not self.active then return end
    self:_sync(true)
    self.deps.sched.unschedule(self.tick_fn)
end

function Session:resume()
    if self.active then self:_tick() end
end

function Session:syncNow()
    return self:_sync(true)
end

return Session
```

- [ ] **Step 4: Run to verify pass**

Run: `lua tests/run.lua`
Expected: all PASS across every test file. If "starting another book first syncs the previous one" fails, check that `start` runs `_sync(true)` before `_end()`.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/audiosession.lua tests/test_audiosession.lua
git commit -m "feat: add audio session driving KinAMP and syncing progress to ABS

Why: playback start, periodic progress, final sync on stop/suspend/exit and
the offline and dead-daemon cases are the core of the feature and are fully
testable with injected fakes.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: ABS API additions (device-only)

**Files:**
- Modify: `audiobookshelf/audiobookshelfapi.lua` (`getLibraryItems`, `getSearchResults`, plus new functions before `return AudiobookshelfApi`)

**Interfaces:**
- Produces:
  - `AudiobookshelfApi:getLibraryItems(id, opts)` — `opts.audio = true` omits the `ebooks` filter.
  - `AudiobookshelfApi:getSearchResults(id, search_query, opts)` — same.
  - `AudiobookshelfApi:_json(method, path, body) -> table|nil, code` — `{}` for a 200/204 whose body is not JSON (ABS answers progress writes with plain `OK`).
  - `AudiobookshelfApi:getProgress(item_id) -> table|nil, code`.
  - `AudiobookshelfApi:setProgress(item_id, body) -> boolean`.

- [ ] **Step 1: Make the ebook filter optional in `getLibraryItems`**

Replace the signature and URL lines. Before:

```lua
function AudiobookshelfApi:getLibraryItems(id)
    local sink = {}
    -- this is "ebooks" base64 encoded, and the URL encoded, to only return library items with ebooks
    local filters = "ebooks." .. "ZWJvb2s%3D"
    local request = {
        url = self.abs_settings:readSetting("server") .. "/api/libraries/" .. id .. "/items?filter=" .. filters .. "&sort=media.metadata.title&limit=0",
```

After:

```lua
function AudiobookshelfApi:getLibraryItems(id, opts)
    local sink = {}
    -- "ebooks" base64 encoded, then URL encoded, to only return items with ebooks.
    -- Audio mode lists every item and lets the details page decide.
    local filter = (opts and opts.audio) and "" or "filter=ebooks.ZWJvb2s%3D&"
    local request = {
        url = self.abs_settings:readSetting("server") .. "/api/libraries/" .. id .. "/items?" .. filter .. "sort=media.metadata.title&limit=0",
```

The non-audio URL is byte-for-byte what it was (`?filter=ebooks.ZWJvb2s%3D&sort=media.metadata.title&limit=0`).

- [ ] **Step 2: Same for `getSearchResults`**

Before:

```lua
function AudiobookshelfApi:getSearchResults(id, search_query)
    local sink = {}
    local url_encoded_search_string = util.urlEncode(search_query)
    -- this is "ebooks" base64 encoded, and the URL encoded, to only return library items with ebooks
    local filters = "ebooks." .. "ZWJvb2s%3D"
    local request = {
        url = self.abs_settings:readSetting("server") .. "/api/libraries/" .. id .. "/search?q=" .. url_encoded_search_string .. "&filter=" .. filters,
```

After:

```lua
function AudiobookshelfApi:getSearchResults(id, search_query, opts)
    local sink = {}
    local url_encoded_search_string = util.urlEncode(search_query)
    -- "ebooks" base64 encoded, then URL encoded, to only return items with ebooks.
    local filter = (opts and opts.audio) and "" or "&filter=ebooks.ZWJvb2s%3D"
    local request = {
        url = self.abs_settings:readSetting("server") .. "/api/libraries/" .. id .. "/search?q=" .. url_encoded_search_string .. filter,
```

- [ ] **Step 3: Add the JSON helper and progress calls**

Insert before the final `return AudiobookshelfApi`:

```lua
-- Generic JSON request. Returns (table, code) on 200/204, (nil, code) on any
-- other status and (nil, nil) when the request itself failed (unreachable).
-- ABS answers progress writes with plain "OK", which is not JSON, so a 200 with
-- an unparsable body yields an empty table.
function AudiobookshelfApi:_json(method, path, body)
    local sink = {}
    local headers = {
        ["Authorization"] = "Bearer " .. self.abs_settings:readSetting("token"),
        ["User-Agent"] = T("audiobookshelf.koplugin/%1", table.concat(VERSION, ".")),
    }
    local request = {
        url = self.abs_settings:readSetting("server") .. path,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if body then
        local payload = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        request.source = ltn12.source.string(payload)
    end
    socketutil:set_timeout()
    local ok, code, _, status = pcall(function() return socket.skip(1, http.request(request)) end)
    local response = table.concat(sink)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("AudiobookshelfApi: http request failed in _json:", method, path, code)
        return nil, nil
    end
    if code == 200 or code == 204 then
        if response ~= "" then
            local decoded_ok, result = pcall(JSON.decode, response, JSON.decode.simple)
            if decoded_ok and type(result) == "table" then return result, code end
        end
        return {}, code
    end
    logger.warn("AudiobookshelfApi: unexpected status in _json:", method, path, status or code)
    return nil, code
end

function AudiobookshelfApi:getProgress(item_id)
    return self:_json("GET", "/api/me/progress/" .. item_id)
end

function AudiobookshelfApi:setProgress(item_id, body)
    local result = self:_json("PATCH", "/api/me/progress/" .. item_id, body)
    return result ~= nil
end
```

- [ ] **Step 4: Syntax-check**

Run: `lua -e 'assert(loadfile("audiobookshelf/audiobookshelfapi.lua"))' && echo syntax-ok`
Expected: `syntax-ok`. (This checks syntax only; behaviour is verified by spike S5 and the on-device run in Task 11.)

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/audiobookshelfapi.lua
git commit -m "feat: add audio listing and progress calls to the ABS api

Why: audiobooks need an unfiltered item/search listing and the
/api/me/progress read and write; ebook URLs are unchanged.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 9: KinAMP adapter and wiring context (device-only)

**Files:**
- Create: `audiobookshelf/kinampclient.lua`
- Create: `audiobookshelf/audiocontext.lua`

**Interfaces:**
- Produces:
  - `Kinamp.available() -> bool`, `Kinamp.playFromIndex(index1, paths) -> bool`, `Kinamp.seek(seconds)`, `Kinamp.stop()`, `Kinamp.getStatus() -> status|nil`, `Kinamp.waitUntilRunning(cb)` — each delegates to `kinamp_backend` when it loads and is a safe no-op otherwise.
  - `AudioContext.get() -> {api, settings, store, session, kinamp}` (built once); `AudioContext.peek() -> same|nil` (does not build).

- [ ] **Step 1: Write the KinAMP adapter**

`audiobookshelf/kinampclient.lua`:

```lua
-- Thin adapter over KinAMP's own KOReader module. KinAMP must be installed.
local Client = {}

local function backend()
    local ok, B = pcall(require, "kinamp_backend")
    if ok and type(B) == "table" then return B end
    return nil
end

function Client.available()
    return backend() ~= nil
end

-- true when the commands reached a running daemon; false when KinAMP had to be
-- launched (the caller then waits for it). Overwrites KinAMP's internal queue.
function Client.playFromIndex(index, paths)
    local B = backend()
    if not B then return false end
    return B.play_from_index(index, paths) and true or false
end

function Client.seek(seconds)
    local B = backend()
    if B then B.seek(seconds) end
end

function Client.stop()
    local B = backend()
    if B then B.stop() end
end

function Client.getStatus()
    local B = backend()
    if not B then return nil end
    return B.get_status()
end

function Client.waitUntilRunning(callback)
    local B = backend()
    if not B then
        callback(false)
        return
    end
    B.wait_until_running(callback)
end

return Client
```

- [ ] **Step 2: Write the context**

`audiobookshelf/audiocontext.lua`:

```lua
-- Builds the real collaborators once and shares them between the UI and the
-- plugin's suspend/resume/exit handlers.
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")

local Api = require("audiobookshelf/audiobookshelfapi")
local Kinamp = require("audiobookshelf/kinampclient")
local Session = require("audiobookshelf/audiosession")
local Store = require("audiobookshelf/audiostore")

local Context = {}
local instance

function Context.get()
    if instance then return instance end
    local config_file = string.gsub(debug.getinfo(1).source, "^@(.+/)[^/]+$", "%1") .. "/../audiobookshelf_config.lua"
    local settings = LuaSettings:open(config_file)
    local store = Store.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/audiobookshelf_audio.lua"))
    local session = Session.new({
        api = Api,
        store = store,
        kinamp = Kinamp,
        sched = {
            scheduleIn = function(seconds, fn) UIManager:scheduleIn(seconds, fn) end,
            unschedule = function(fn) UIManager:unschedule(fn) end,
        },
        notify = function(message)
            UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
        end,
    })
    instance = { api = Api, settings = settings, store = store, session = session, kinamp = Kinamp }
    return instance
end

function Context.peek()
    return instance
end

return Context
```

- [ ] **Step 3: Syntax-check both**

Run:

```bash
for f in kinampclient audiocontext; do lua -e "assert(loadfile('audiobookshelf/$f.lua'))" && echo "$f ok"; done
```

Expected: `kinampclient ok`, `audiocontext ok`.

- [ ] **Step 4: Commit**

```bash
git add audiobookshelf/kinampclient.lua audiobookshelf/audiocontext.lua
git commit -m "feat: add KinAMP adapter and shared audio context

Why: the session is fully injected; these two files are the only place that
touches kinamp_backend, LuaSettings and UIManager scheduling.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 10: UI — details dialog, browser entry, plugin events (device-only)

**Files:**
- Create: `audiobookshelf/audiodetails.lua`
- Modify: `audiobookshelf/audiobookshelfbrowser.lua` (`genItemTableFromLibraries`, `onMenuSelect`, `loadLibrarySearch`, `openLibrary`)
- Modify: `main.lua`

**Interfaces:**
- Consumes: everything above. `AudioDetails.show(item_id)` loads the item, builds tracks, and shows a `ButtonDialog` with Download / Delete, Play / Stop, Sync now, Close.
- Produces: an "(Audiobooks)" entry next to every library in the browser; plugin event handlers `onSuspend`, `onResume`, `onExit` forwarding to the session.

- [ ] **Step 1: Write the details dialog**

`audiobookshelf/audiodetails.lua`:

```lua
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local AudioContext = require("audiobookshelf/audiocontext")
local Downloader = require("audiobookshelf/audiodownloader")
local PositionMap = require("audiobookshelf/positionmap")
local Store = require("audiobookshelf/audiostore")

local AudioDetails = {}

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

local function hms(seconds)
    seconds = math.floor(seconds or 0)
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

local function realFs()
    return {
        mkdir_p = function(dir)
            local path = ""
            for part in dir:gmatch("[^/]+") do
                path = path .. "/" .. part
                if lfs.attributes(path, "mode") ~= "directory" then
                    lfs.mkdir(path)
                    if lfs.attributes(path, "mode") ~= "directory" then return nil end
                end
            end
            return true
        end,
        size = function(path) return lfs.attributes(path, "size") end,
        rename = function(a, b) return os.rename(a, b) end,
        remove = function(path) return os.remove(path) end,
        write = function(path, text)
            local f = io.open(path, "w")
            if not f then return nil end
            f:write(text)
            f:close()
            return true
        end,
    }
end

local function ensureDownloadDir(ctx, callback)
    local dir = ctx.settings:readSetting("download_dir")
    if dir then
        callback(dir)
        return
    end
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            ctx.settings:saveSetting("download_dir", path)
            ctx.settings:flush()
            callback(path)
        end,
    }:chooseDir(G_reader_settings:readSetting("lastdir"))
end

local function preflightMessage(err)
    if err == "file_too_large" then
        return _("A file in this book is larger than 4 GB, which the Kindle storage cannot hold.")
    elseif err == "no_space" then
        return _("Not enough free space on the Kindle for this book.")
    end
    return T(_("Cannot download: %1"), tostring(err))
end

function AudioDetails.show(item_id)
    local ctx = AudioContext.get()
    local item = ctx.api:getLibraryItem(item_id)
    if not item then
        toast(_("Could not load book details. Check network and settings."))
        return
    end
    local tracks, total = PositionMap.buildTracks(item)
    if #tracks == 0 then
        toast(_("This item has no playable audio files."))
        return
    end
    local meta = (item.media and item.media.metadata) or {}
    local title = meta.title or _("Untitled")
    local author = meta.authorName or ""

    local dialog
    local render

    local function reopen()
        if dialog then UIManager:close(dialog) end
        render()
    end

    local function doDownload()
        ensureDownloadDir(ctx, function(download_dir)
            local dir = ctx.store:dirFor(download_dir, title, item_id)
            local entry = Store.makeEntry(item_id, title, author, dir, tracks, total)
            local free
            local ok, usage = pcall(util.diskUsage, download_dir)
            if ok and type(usage) == "table" then free = usage.available end
            local pre, perr = Downloader.preflight(entry, free)
            if not pre then
                toast(preflightMessage(perr), 5)
                return
            end
            local msg
            local done, err = Downloader.run({
                api = ctx.api, fs = realFs(), entry = entry,
                on_progress = function(i, n)
                    if msg then UIManager:close(msg) end
                    msg = InfoMessage:new{ text = T(_("Downloading %1 of %2…"), i, n) }
                    UIManager:show(msg)
                    UIManager:forceRePaint()
                end,
            })
            if msg then UIManager:close(msg) end
            if done then
                ctx.store:put(entry)
                toast(T(_("Saved to:\n%1"), entry.dir), 4)
                reopen()
            else
                toast(T(_("Download failed: %1"), tostring(err)), 5)
            end
        end)
    end

    local function doDelete()
        local entry = ctx.store:get(item_id)
        if not entry then return end
        if ctx.session:isActive(item_id) then ctx.session:stop() end
        for i = 1, #entry.tracks do os.remove(entry.tracks[i].path) end
        os.remove(entry.m3u)
        lfs.rmdir(entry.dir)
        ctx.store:remove(item_id)
        reopen()
    end

    local function doPlay()
        local entry = ctx.store:get(item_id)
        local ok, note = ctx.session:start(entry)
        if not ok then
            if note == "kinamp_missing" then
                toast(_("KinAMP's KOReader plugin was not found. Install KinAMP first."), 5)
            else
                toast(T(_("Cannot start playback: %1"), tostring(note)), 5)
            end
            return
        end
        if note == "offline" then
            toast(_("Audiobookshelf is unreachable. Resuming from the last position saved on this Kindle."), 5)
        end
        reopen()
    end

    local function doSyncNow()
        local pos, why = ctx.session:syncNow()
        if pos then
            toast(T(_("Synced at %1"), hms(pos)))
        else
            toast(T(_("Nothing synced (%1)"), tostring(why)))
        end
    end

    render = function()
        local entry = ctx.store:get(item_id)
        local downloaded = entry and entry.complete
        local playing = ctx.session:isActive(item_id)
        local info = T(_("%1\n%2\nLength: %3\nTracks: %4\n%5"),
            title, author, hms(total), #tracks,
            downloaded and _("Downloaded") or _("Not downloaded"))
        local buttons = {
            {
                downloaded
                    and { text = _("Delete download"), callback = doDelete }
                    or { text = _("Download"), callback = doDownload },
            },
            {
                downloaded and (playing
                    and { text = _("Stop"), callback = function() ctx.session:stop(); reopen() end }
                    or { text = _("Play / Resume"), callback = doPlay })
                    or { text = _("Play / Resume"), enabled = false, callback = function() end },
                { text = _("Sync now"), enabled = playing and true or false, callback = doSyncNow },
            },
            {
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        }
        dialog = ButtonDialog:new{ title = info, buttons = buttons }
        UIManager:show(dialog)
    end

    render()
end

return AudioDetails
```

- [ ] **Step 2: Add the audiobook entries to the browser**

In `audiobookshelf/audiobookshelfbrowser.lua`:

`genItemTableFromLibraries` — replace the loop body. Before:

```lua
    for _, library in ipairs(libraries) do
        table.insert(item_table, {
            text = library.name,
            type = "library",
            id = library.id,
        })
    end
```

After:

```lua
    for _, library in ipairs(libraries) do
        table.insert(item_table, {
            text = library.name,
            type = "library",
            id = library.id,
        })
        table.insert(item_table, {
            text = library.name .. " (" .. _("Audiobooks") .. ")",
            type = "library",
            id = library.id,
            audio = true,
        })
    end
```

`onMenuSelect` — pass the flag and add the audiobook branch. Before:

```lua
        self:openLibrary(item.id, item.text)
    elseif item.type == "book" then
```

After:

```lua
        self:openLibrary(item.id, item.text, item.audio)
    elseif item.type == "audiobook" then
        require("audiobookshelf/audiodetails").show(item.id)
    elseif item.type == "book" then
```

`loadLibrarySearch` — before:

```lua
    local libraryItems = AudiobookshelfApi:getSearchResults(self.library_id, search)
```

After:

```lua
    local libraryItems = AudiobookshelfApi:getSearchResults(self.library_id, search, { audio = self.audio_mode })
```

and in the same function change `type = "book"` (inside the `table.insert(tbl, {...})` for search results) to `type = self.audio_mode and "audiobook" or "book"`.

`openLibrary` — before:

```lua
function AudiobookshelfBrowser:openLibrary(id, name)
    local tbl = {}
    local libraryItems = AudiobookshelfApi:getLibraryItems(id)
```

After:

```lua
function AudiobookshelfBrowser:openLibrary(id, name, audio)
    local tbl = {}
    local libraryItems = AudiobookshelfApi:getLibraryItems(id, { audio = audio })
```

and in the same function change `type = "book"` to `type = audio and "audiobook" or "book"`, and before `self.library_id = id` add `self.audio_mode = audio and true or false`.

- [ ] **Step 3: Forward suspend/resume/exit in `main.lua`**

Add at the top of `main.lua` with the other requires:

```lua
local AudioContext = require("audiobookshelf/audiocontext")
```

and add these methods before `return Audiobookshelf`:

```lua
-- Keep ABS in step with the player across device events. peek() avoids building
-- the audio context for people who only use the ebook side.
function Audiobookshelf:onSuspend()
    local ctx = AudioContext.peek()
    if ctx then ctx.session:suspend() end
end

function Audiobookshelf:onResume()
    local ctx = AudioContext.peek()
    if ctx then ctx.session:resume() end
end

function Audiobookshelf:onExit()
    local ctx = AudioContext.peek()
    if ctx then ctx.session:detach() end
end
```

- [ ] **Step 4: Syntax-check all touched files**

Run:

```bash
for f in main.lua audiobookshelf/audiodetails.lua audiobookshelf/audiobookshelfbrowser.lua; do lua -e "assert(loadfile('$f'))" && echo "$f ok"; done
lua tests/run.lua
```

Expected: three `ok` lines, tests all PASS.

- [ ] **Step 5: Commit**

```bash
git add audiobookshelf/audiodetails.lua audiobookshelf/audiobookshelfbrowser.lua main.lua
git commit -m "feat: add audiobook browsing, download and playback UI

Why: exposes the tested core in KOReader: an Audiobooks entry per library, a
details dialog for download/play/sync/delete, and device-event forwarding so
progress is flushed on suspend and exit.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Docs, release hygiene, on-device acceptance

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `audiobookshelf_version.lua`
- Modify: `.github/workflows/release.yml`
- Modify: `docs/superpowers/specs/2026-10-19-audiobook-playback-kinamp-design.md` (spec amendment)

- [ ] **Step 1: README section**

Append to `README.md`:

```markdown
## Audiobooks (requires KinAMP)

Each library is listed twice: once for ebooks, and once as "(Audiobooks)".

1. Install [KinAMP](https://github.com/kbarni/KinAMP) (its KOReader plugin and player) on your Kindle. This plugin drives KinAMP's player; it does not play audio itself.
2. Open "<Library> (Audiobooks)" and pick a book. **Download** saves it into `<download folder>/<Title>/` as numbered files (`001-…`, `002-…`) plus a `book.m3u`. The download folder is the same one used for ebooks; you are asked once if none is set.
3. **Play / Resume** starts KinAMP at your Audiobookshelf position. While you listen, progress is sent to Audiobookshelf about every 30 seconds, and again when you stop, suspend or exit KOReader.

Notes:
- Starting a book replaces KinAMP's queue with the book's files.
- Progress only syncs while KOReader is running. If you exit KOReader and keep listening, the last position is saved when you exit.
- If Audiobookshelf is unreachable when you press Play, the last position saved on the Kindle is used.
- A single file larger than 4 GB cannot be stored on the Kindle volume and is refused.
```

- [ ] **Step 2: Changelog and version**

Add to the top of `CHANGELOG.md`:

```markdown
## 0.2.0 (unreleased)

Audiobooks: browse, download and play through KinAMP, with progress synced back to Audiobookshelf. Ebook behaviour is unchanged.
```

Set `audiobookshelf_version.lua` to:

```lua
return { 0, 2, 0 }
```

- [ ] **Step 3: Keep tests and docs out of the release zip**

In `.github/workflows/release.yml`, in the `zip` command's exclude list, add `'audiobookshelf.koplugin/tests/*' 'audiobookshelf.koplugin/docs/*'` next to the existing `'audiobookshelf.koplugin/spec/*'` entry.

- [ ] **Step 4: Amend the spec to match what was built**

In the spec's section 5 table, replace the `kinampclient.lua` row with: `| `kinampclient.lua` (new) | Adapter over KinAMP's own `kinamp_backend` module: play from an index, seek, stop, status, wait until running. No FIFO or status parsing of our own in v1. | `kinamp_backend` |`; rename `progresssync.lua` to `audiosession.lua` plus `progresspolicy.lua`, and `audiodetailswidget.lua` to `audiodetails.lua`. Add under section 4: "`play_from_index` overwrites KinAMP's internal queue; documented in the README."

- [ ] **Step 5: Final automated checks**

Run:

```bash
lua tests/run.lua
for f in main.lua audiobookshelf/*.lua; do lua -e "assert(loadfile('$f'))" || echo "SYNTAX FAIL $f"; done
```

Expected: `0 failed`, no `SYNTAX FAIL` lines.

- [ ] **Step 6: On-device acceptance (user runs; record in the spikes file)**

Copy the plugin folder to `koreader/plugins/audiobookshelf.koplugin/`, restart KOReader, then:

1. Tools → Audiobookshelf shows each library twice; the ebook entry behaves exactly as before (download an ebook to confirm).
2. Open a multi-file MP3 book: Download completes; the folder contains numbered files and `book.m3u`.
3. Play / Resume starts KinAMP and lands at the ABS position. Listen 2 minutes; the ABS app shows the new position within a minute.
4. Stop: ABS shows the final position. Play again: resumes there.
5. Repeat with a single M4B.
6. Put the Kindle to sleep mid-play and wake it: no crash, progress continues.
7. With Wi-Fi off, press Play: the offline message appears and playback starts at the saved position.

Record each result in `docs/superpowers/spikes/2026-10-19-kinamp-spikes.md` under a new "Acceptance" heading.

- [ ] **Step 7: Commit**

```bash
git add README.md CHANGELOG.md audiobookshelf_version.lua .github/workflows/release.yml docs
git commit -m "docs: document audiobook playback and keep dev files out of releases

Why: users need the KinAMP prerequisite and the queue-overwrite caveat; the
release zip should not ship tests or design docs.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Hand back to the user**

Report test results and the acceptance table. Do not push or merge; ask whether to push `feature/audio-playback-kinamp` to the fork and whether to open a PR to `naleo/audiobookshelf.koplugin` for the generic parts.
