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
| `libexec/exec.sh` | Orchestrator, cron entry point. Takes the global `lockf` lock, snapshots every target via `scan.sh`, then per target runs the analysis batch and builds the registry. |
| `libexec/scan.sh` | Lists and hashes the files of one target (PH lines on stdout). Runs as the target's `RUN_AS` user via `su -m`, so NFS targets with root squash are read with the right identity. |
| `libexec/exec_check.sh` | Reads PH lines (`HASH/absolute/path`) from stdin and runs the cached check on each — the batch that fills the cache, run once per target. |
| `libexec/exec_dir.sh` | Builds the registry of one target from its PH lines on stdin (all cache hits at that point). Sorted `LC_ALL=C`, rewritten only if the content changed, always atomically. |
| `libexec/check_media_state_c.sh` | Cached state of one file: cache hit → read; cache miss → full analysis + immutable, atomically-created cache entry (state, integrity, reason) + syslog "New fingerprint" line. |
| `libexec/check_media_state.sh` | The real analysis of one file: ffprobe pre-check, full software decode (`-f null -`), duration-coverage check, classification. Prints `STATE<TAB>INTEGRITY<TAB>REASON`. No cache knowledge. |
| `libexec/helpers.sh` | Shared runtime helpers (sourced): file hashing, PH line building/parsing, hash → sharded cache path, configuration loading, atomic file publication, syslog logging. |
| `setup/*.sh` | Interactive installation/management scripts (`install`, `config`, `unconfig`, `reconfig`, `run`, `uninstall`); the shared prompts, validations and paths live in `setup/common.sh`. |
| `Makefile` | Thin dispatcher: each target runs the matching `setup/` script, forwarding `PREFIX`. |
| `nel-media-watch.conf.default` | Default global configuration installed to `/usr/local/etc/nel-media-watch/nel-media-watch.conf`. |

## How a run works

1. `lockf -t 0` on `/var/run/nel-media-watch.lock` — a second concurrent run
   logs `Execution aborted: another run is in progress` and exits at once.
   The kernel releases the lock when the process dies, even after a hard
   power loss: no stale-lock cleanup exists because none is needed.
2. The global configuration provides `CACHE_DIRECTORY`; every `*.conf` in
   `conf.d/` describes one target (`TARGET_DIRECTORY`, `FILTER`, `CASE`,
   `REGISTRY`, `RUN_AS`).
3. **Snapshot**: per target, `scan.sh` runs `find -type f | grep -E[i]
   FILTER` and hashes every file with `xxh128sum`, producing one PH file
   per target. The scan runs as the target's `RUN_AS` user (`su -m`, no
   sudo involved): on NFS targets root is squashed to nobody and could
   not read the files. Lists and hashes are frozen here for the whole run.
4. **Per target**: its PH lines, de-duplicated by hash, go through
   `exec_check.sh` — content never seen before is analysed (as `RUN_AS`)
   and cached — then `exec_dir.sh` builds the registry from the cache:
   `relative_path<TAB>STATE<TAB>xxh128`, sorted, one line per file,
   replaced only when its content actually changed. Cache entries and
   registries are always written as root. Content shared across targets
   is analysed only once.
5. `Execution finished in <H>h<MM>'<SS>''` is logged.

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
the snapshot hashing and the analysis batches; each ffmpeg decode is
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

## Per-target identity (deliberate deviation)

Specification §7.4 prescribed one single cross-target "general" batch.
Each target can now name a `RUN_AS` user, and everything that READS the
media — the scan and the ffprobe/ffmpeg analysis — runs as that user via
`su -m` (sudo is not installed; root needs no password to su, and `-m`
makes users without a login shell work too). A single cross-target batch
is incompatible with per-target identities, so the analysis batch runs
once per target, right before that target's registry. The guarantees are
unchanged: the snapshot is still taken up front for all targets, content
shared across targets is analysed only once (the first batch caches it,
the later ones hit the cache), and **cache entries and registries are
always written as root**, whatever `RUN_AS` says. `make config` and
`make reconfig` validate `TARGET_DIRECTORY` with the `RUN_AS` identity
for the same reason.

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
make run        # detached daemon(8) run of one target; survives shell exit
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
