# nel-media-watch

Periodic (daily, cron-driven) integrity surveillance of video files on a
FreeBSD host. Every file selected by a configurable filter is classified as
**OK / Degraded / Corrupted** and recorded in a per-target **registry**. A
content-addressed **cache** (xxh128) guarantees that the expensive full
decode is paid **at most once per distinct content** — even if a file is
renamed or moved.

Designed for `/bin/sh` POSIX (FreeBSD ash): no bashisms, no external
dependencies beyond `ffmpeg`/`ffprobe`, `xxh128sum` (package `xxhash`),
`lockf(1)` and the base system utilities.

## Components

| File | Role |
|------|------|
| `libexec/exec.sh` | Orchestrator, cron entry point. Takes the global `lockf` lock, snapshots the file lists (find + grep + xxh128), runs the general analysis batch, then builds every registry. |
| `libexec/exec_check.sh` | Reads PH lines (`HASH/absolute/path`) from stdin and runs the cached check on each — the single cross-target batch that fills the cache. |
| `libexec/exec_dir.sh` | Builds the registry of one target from its PH lines on stdin (all cache hits at that point). Sorted `LC_ALL=C`, rewritten only if the content changed, always atomically. |
| `libexec/check_media_state_c.sh` | Cached state of one file: cache hit → read; cache miss → full analysis + immutable, atomically-created cache entry (state, integrity, reason) + syslog "New fingerprint" line. |
| `libexec/check_media_state.sh` | The real analysis of one file: ffprobe pre-check, full software decode (`-f null -`), duration-coverage check, classification. Prints `STATE<TAB>INTEGRITY<TAB>REASON`. No cache knowledge. |
| `libexec/helpers.sh` | Shared runtime helpers (sourced): file hashing, PH line building/parsing, hash → sharded cache path, configuration loading, atomic file publication, syslog logging. |
| `setup/*.sh` | Interactive installation/management scripts (`install`, `config`, `unconfig`, `reconfig`, `uninstall`); the shared prompts, validations and paths live in `setup/common.sh`. |
| `Makefile` | Thin dispatcher: each target runs the matching `setup/` script, forwarding `PREFIX`. |
| `nel-media-watch.conf.default` | Default global configuration installed to `/usr/local/etc/nel-media-watch/nel-media-watch.conf`. |

## How a run works

1. `lockf -t 0` on `/var/run/nel-media-watch.lock` — a second concurrent run
   logs `Execution aborted: another run is in progress` and exits at once.
   The kernel releases the lock when the process dies, even after a hard
   power loss: no stale-lock cleanup exists because none is needed.
2. The global configuration provides `CACHE_DIRECTORY`; every `*.conf` in
   `conf.d/` describes one target (`TARGET_DIRECTORY`, `FILTER`, `CASE`,
   `REGISTRY`).
3. **Snapshot**: per target, `find -type f | grep -E[i] FILTER`, then each
   file is hashed with `xxh128sum`, producing one PH file per target plus a
   general one. Lists and hashes are frozen here for the whole run.
4. **General pass**: the general PH file, de-duplicated by hash, goes
   through `exec_check.sh`. New content is analysed and cached; known
   content is untouched.
5. **Registries**: per target, `exec_dir.sh` reads states (all from cache)
   and writes `relative_path<TAB>STATE<TAB>xxh128`, sorted, one line per
   file, replacing the registry only if it actually changed.
6. `Execution finished in <H>h<MM>'<SS>''` is logged.

## Cache layout

One immutable file per content hash, sharded over ten directory levels
built from the first ten hash characters:

```
$CACHE_DIRECTORY/9/d/e/3/e/5/5/8/2/6/9de3e55826ad412c3a9d9fd22da014fb
```

Each cache file is a sourceable snippet: the state, the integrity
(percentage of the declared duration actually decoded) and the reason why
the content was classified Corrupted or Degraded (empty when OK), plus a
comment with the first path that produced the entry:

```sh
STATE="Degraded"
INTEGRITY="99.4"
REASON="3 decoder error line(s)"
# /absolute/path/of/the/first/file/with/this/content
```

## Concurrency (deliberate deviation from the original specification)

The original specification prescribed a strictly sequential chain. **By
explicit project decision the number of parallel workers is one less than
the available cores** (`hw.ncpu - 1`, minimum 1). The parallel stages are
the snapshot hashing and the general analysis batch; each ffmpeg decode is
single-threaded, so the total CPU footprint stays at *cores − 1* and one
core is always left free for the other services (e.g. Nextcloud) on the
machine. Override with `NEL_MEDIA_WATCH_JOBS` if needed.

## Global configuration (deliberate deviation)

Unlike specification §3.1, the global configuration does not source the
`conf.d/*.conf` files itself: it only defines `CACHE_DIRECTORY`. The local
files are sourced one at a time by `exec.sh` — the include loop in the
global file had no consumer and only leaked the last target's variables
into whoever sourced it. The operational property is unchanged: adding or
removing a target is still just creating or deleting a file in `conf.d/`.

## Classification (per file)

* **Corrupted** — ffprobe cannot open it, or duration `< 0.5 s`/absent, or
  size `< 100 KB`, or ffmpeg exits non-zero, or decoded duration covers
  `< 98%` of the declared one (truncation).
* **Degraded** — full coverage but at least one decoder error line.
* **OK** — full coverage, zero error lines.

The telemetry `data`/`bin_data` stream of dashcam `.ts` files is never
mapped, so it cannot influence the verdict.

## Logging

Everything goes through `logger -t nel-media-watch` (syslog →
`/var/log/messages`): start, lock abort, one
`New fingerprint in watch's cache for xxh128 <hash>. State is <STATE>` per
cache **miss** (never on hits — this single message also covers the alert
for new DEGRADED/CORRUPTED content), and the final duration. Filter with:

```sh
grep nel-media-watch /var/log/messages
```

## Installation and management

```sh
make install    # as root: scripts, global config, cache dir, crontab entry
make config     # add a target (name, directory, filter, case menu, registry)
make unconfig   # delete a target by numeric index
make reconfig   # edit a target by index, "no change on empty"
make uninstall  # remove crontab entry + scripts (configs/cache/registries kept)
```

`make install` only installs: the first analysis happens at the scheduled
time. A vanished `TARGET_DIRECTORY` at run time is logged and skipped
without failing the rest of the run.

## Environment overrides (mainly for testing)

| Variable | Default | Meaning |
|----------|---------|---------|
| `NEL_MEDIA_WATCH_CONF` | `/usr/local/etc/nel-media-watch/nel-media-watch.conf` | Global configuration path |
| `NEL_MEDIA_WATCH_LOCK` | `/var/run/nel-media-watch.lock` | Lock file path |
| `NEL_MEDIA_WATCH_JOBS` | cores − 1 | Parallel workers |
| `NEL_MEDIA_WATCH_FFMPEG_THREADS` | 1 | Decoder threads per ffmpeg process |

## License

Copyright (c) 2026 Mattia Cabrini

SPDX-License-Identifier: MIT — full text in [LICENSE](LICENSE).
