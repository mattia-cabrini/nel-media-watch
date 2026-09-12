# nel-media-watch

Periodic (daily, cron-driven) integrity surveillance of video files on a
FreeBSD host. Every file selected by a configurable filter is classified as
**OK / Degraded / Corrupted** and recorded in a per-target **registry**. A
content-addressed **cache** (xxh128) guarantees that the expensive full
decode is paid **at most once per distinct content** — even if a file is
renamed or moved.

The runtime is one Go program with no dependencies beyond the standard
library; the external tools are `ffmpeg`/`ffprobe`, `xxh128sum` (package
`xxhash`) and the base system. The installation and management scripts are
plain POSIX `/bin/sh` (FreeBSD ash).

## Components

| Path | Role |
|------|------|
| `cmd/nel-media-watch/main.go` | Entry point. `run [target]` is the cron entry point (all targets, or one); `walk <dir>` is the internal helper the program re-executes under the target's `RUN_AS` identity to list files. |
| `internal/watch/` | Orchestration: the global `flock` lock and the sequential processing of targets (`run.go`); the three stages of one target (`target.go`); the **coordinator + runners** of the snapshot (`coordinator.go`); the registry file (`registry.go`). |
| `internal/media/` | Everything that touches the media, all of it as `RUN_AS`: listing (`walk.go`), hashing with `xxh128sum` (`hash.go`), the ffprobe pre-check and full ffmpeg decode (`analyze.go`). |
| `internal/cache/` | The content cache: entry location (sharding), tolerant reads, atomic writes. Knows the global configuration, so callers only say *what* to remember or recall. |
| `internal/duty/` | The duty cycle: when to pause, for how long, and the log line. |
| `internal/identity/` | `RUN_AS` resolved into kernel credentials applied to every child process that reads media. |
| `internal/config/` | The sh-syntax configuration files (global and per target). |
| `internal/atomicfile/` | Write-then-fsync-then-rename, used by the cache and the registry. |
| `internal/verdict/`, `internal/journal/` | The verdict vocabulary; syslog output under the `nel-media-watch` tag. |
| `setup/*.sh` | Installation/management scripts (`install` — also the update path — `config`, `unconfig`, `reconfig`, `run`, `uninstall`); the shared prompts, validations and paths live in `setup/common.sh`. |
| `Makefile` | `build` compiles the program; the other targets run the matching `setup/` script, forwarding `PREFIX`. |
| `nel-media-watch.conf.default` | Default global configuration installed to `/usr/local/etc/nel-media-watch/nel-media-watch.conf`. |

## How a run works

1. `flock` on `/var/run/nel-media-watch.lock`, without waiting — a second
   concurrent run logs `Execution aborted: another run is in progress` and
   exits at once. The kernel releases the lock when the process dies, even
   after a hard power loss: no stale-lock cleanup exists because none is
   needed.
2. The global configuration provides `CACHE_DIRECTORY` and the duty cycle
   (`TIME_UP`, `TIME_PAUSE`, see below); every `*.conf` in `conf.d/`
   describes one target (`TARGET_DIRECTORY`, `FILTER`, `CASE`, `REGISTRY`,
   `RUN_AS`).
3. Targets are processed **strictly one after the other**, in name order.
   Each one goes through three stages:
   * **Snapshot.** The program re-executes itself as the target's `RUN_AS`
     user to walk `TARGET_DIRECTORY`; the paths accepted by `FILTER` go to a
     **coordinator**, which hands them out over a channel to *N* **runners**
     that hash them with `xxh128sum` (as `RUN_AS`). When the last path is
     out, the coordinator sends each runner the stop token `///` in place of
     a path. Lists and digests are frozen here for the rest of the target.
   * **Analysis.** For every distinct digest not in the cache, the
     coordinator itself launches the analysis — `ffprobe`, then a full
     `ffmpeg` decode, as `RUN_AS` — **one file at a time**, caches the verdict
     at once and logs the new fingerprint. Content shared across paths or
     targets is analysed only once.
   * **Registry.** `relative_path<TAB>STATE<TAB>xxh128`, sorted bytewise, one
     line per file, written atomically and only when its content actually
     changed. Cache entries and registries are always written as root.
4. `Execution finished in <H>h<MM>'<SS>''` is logged.

A target whose configuration is invalid, whose `RUN_AS` user is unknown,
whose directory cannot be walked, whose tools cannot run or whose cache
cannot be read or written is logged and skipped, **its registry untouched**:
a registry emptied or thinned by a breakdown would read as "all those files
are gone", the one lie the tool must never tell. For the same reason a scan
that finds no file while the registry is not empty is treated as a breakdown
(a mount that is not there, a filter that no longer matches) and skipped: a
tree emptied on purpose is acknowledged by deleting its registry by hand.
Only a file the tools ran on and turned down — vanished, unreadable as
`RUN_AS`, decode killed from outside — leaves the registry, and it does so
with a log line of its own. A `TARGET_DIRECTORY` that is a symbolic link is
resolved.

## Concurrency

The snapshot is the parallel stage: *N* runners, one goroutine each, hash at
once — *N* is `hw.ncpu − 1`, minimum 1, overridable with
`NEL_MEDIA_WATCH_JOBS`. The coordinator is the only goroutine that feeds
them, drains their results and looks at the duty cycle; feeding and draining
are one `select`, so a runner blocked on delivering a result can never
deadlock a coordinator blocked on delivering a path.

The analysis is sequential by design: the coordinator launches one `ffmpeg`
at a time. Each decode gets `hw.ncpu − 1` threads (`-threads`, overridable
with `NEL_MEDIA_WATCH_FFMPEG_THREADS`), so the CPU footprint of the program
stays at *cores − 1* and one core is always left free for the other services
on the machine, while the disks see a single sequential read. The trade-off
is deliberate: codecs whose decoder does not scale with threads (the MPEG-2
of dashcam `.ts` files, for instance) run noticeably slower than they did
with *cores − 1* single-threaded decodes in parallel, in exchange for the
gentlest possible disk access.

## Duty cycle (disk temperature)

To keep the disks' temperature under control, the global configuration sets
a duty cycle: once `TIME_UP` seconds of processing have passed, the whole
program pauses for `TIME_PAUSE` seconds. Both are plain integers in seconds;
`0` in either one disables it. `make install` asks for them (on an update,
empty answers keep the current values).

* The check happens **between files**, never inside one: a file being hashed
  or decoded is never interrupted.
* **The pause only starts with every worker stopped.** During the snapshot
  the coordinator, once the work window is over, stops feeding the runners,
  waits until nothing is in flight — the walker upstream stalls on its full
  pipe meanwhile — and only then rests. During the analysis the coordinator
  is the only worker, and checks the cycle before each decode.
* The pause is logged — `Duty cycle: pausing for <n>s after <m>s of
  processing` — and lasts `TIME_PAUSE × processing / TIME_UP`, where the
  processing is the time since the previous pause ended, measured once
  everything has stopped. Normally that is just over `TIME_UP` and the pause
  is about `TIME_PAUSE`; when a single file kept a disk busy for three times
  `TIME_UP`, the pause is **stretched proportionally** to three times
  `TIME_PAUSE`. The rest-to-work ratio is therefore the configured one,
  however uneven the files.
* One cycle covers the whole run: its clock does not restart between
  targets.

## Cache layout

One file per content hash, sharded over ten directory levels built from the
first ten hash characters:

```
$CACHE_DIRECTORY/9/d/e/3/e/5/5/8/2/6/9de3e55826ad412c3a9d9fd22da014fb
```

Each cache file is a sourceable snippet — the format of the original shell
implementation, kept so that an existing cache stays valid: the state, the
integrity (percentage of the declared duration actually decoded) and the
reason why the content was classified Corrupted or Degraded (empty when OK),
plus a comment with the first path that produced the entry:

```sh
STATE="Degraded"
INTEGRITY="99.4"
REASON="3 decoder error line(s)"
# /absolute/path/of/the/first/file/with/this/content
```

An entry is written once and never rewritten — with one exception: an entry
that yields no state (emptied or filled with garbage, e.g. by a power loss on
a filesystem that reordered the writes) is treated as a cache miss, logged,
and replaced. Writes go through a staging file next to the destination,
`fsync`'d before the rename, so a reader never sees a half-written entry.

## Configuration files

Both the global file and the `conf.d/*.conf` files use shell-assignment
syntax — `KEY=value`, with the value bare, single-quoted or double-quoted —
so that the setup scripts can still source them. The program reads exactly
that subset and nothing else: a file edited by hand into something the
scripts would still accept but that is not a plain assignment (`export`,
expansions, `case`) is refused, and the target (or the run) is skipped with
a log line.

## Per-target identity (NFS root squash)

Each target can name a `RUN_AS` user, and everything that READS the media —
the walk, the hashing, the ffprobe/ffmpeg analysis — runs as that user: the
program (which runs as root) starts those child processes with the user's
uid, gid and supplementary groups set by the kernel right after the fork. No
`su`, no `sudo`, nothing quoted into a shell. Everything that WRITES — cache
entries and registries — always runs as root, whatever `RUN_AS` says.
`make config` and `make reconfig` validate `TARGET_DIRECTORY` with the
`RUN_AS` identity for the same reason.

A file that vanishes between the snapshot and its analysis is left out of
the registry and **not** cached: it has no content left to judge, and a
verdict about it would pin "Corrupted" on a digest that intact copies of the
same content share.

## Classification (per file)

* **Corrupted** — ffprobe cannot open it, or duration `< 0.5 s`/absent, or
  size `< 100 KB`, or ffmpeg exits non-zero, or decoded duration covers
  `< 98%` of the declared one (truncation).
* **Degraded** — full coverage but at least one decoder error line.
* **OK** — full coverage, zero error lines.

The telemetry `data`/`bin_data` stream of dashcam `.ts` files is never
mapped, so it cannot influence the verdict. Forbidden by the specification
and deliberately absent: `-xerror`, `-err_detect +explode`, hardware
acceleration, `*_cuvid` / `*_v4l2m2m` decoders, `-c copy`.

## Logging

Everything goes to syslog with the tag `nel-media-watch` (priority
`user.notice`, so it lands in `/var/log/messages`): start, lock abort, one
`New fingerprint in watch's cache for xxh128 <hash>. State is <STATE>` per
cache **miss** (never on hits — this single message also covers the alert
for new DEGRADED/CORRUPTED content), one `Duty cycle: pausing for <n>s after
<m>s of processing` per pause, skipped targets and files, unusable cache
entries, and the final duration. Filter with:

```sh
grep nel-media-watch /var/log/messages
```

## Installation and management

Prerequisites: the Go toolchain (`pkg install go`), `ffmpeg`, `xxhash`.

```sh
make build      # compile bin/nel-media-watch (any user)
make install    # as root: build, then install or update; asks for the duty
                # cycle and the cron schedule; on re-install, empty answers
                # keep the current values (reconfig style)
make config     # add a target (name, directory, filter, case menu, registry)
make unconfig   # delete a target by numeric index
make reconfig   # edit a target by index, "no change on empty"
make run        # build, then detached daemon(8) run of one target
make uninstall  # remove crontab entry + binary (configs/cache/registries kept)
make clean      # remove bin/
```

`make install` only installs: the first analysis happens at the scheduled
time.

**`make install` and `make uninstall` hold the runtime's global lock** for
their whole duration, prompts included — the same `flock` on
`/var/run/nel-media-watch.lock` the program takes, acquired through
`lockf(1)`. They refuse to start while a run is in progress (exit 75,
`a run of nel-media-watch is in progress`), so a binary is never replaced
under a running program, and no run can start while they work: cron finds
the lock busy and logs its usual `Execution aborted`.

**Updating a machine that runs the shell implementation** is the same
`make install`: the existing global configuration and every `conf.d/*.conf`
are kept as they are (the formats are unchanged, and the prompts propose the
current values), the cache and the registries stay valid, the crontab entry
of `exec.sh` is replaced by the binary's, the old `libexec/*.sh` are removed
along with the state files of the shell duty cycle under `/var/run`, and a
run of the old version still in progress — it locked the very same file —
makes the installation refuse to start (exit 75) until it has finished.

## Environment overrides (mainly for testing)

| Variable | Default | Meaning |
|----------|---------|---------|
| `NEL_MEDIA_WATCH_CONF` | `/usr/local/etc/nel-media-watch/nel-media-watch.conf` | Global configuration path |
| `NEL_MEDIA_WATCH_LOCK` | `/var/run/nel-media-watch.lock` | Lock file path |
| `NEL_MEDIA_WATCH_JOBS` | cores − 1 | Hashing runners |
| `NEL_MEDIA_WATCH_FFMPEG_THREADS` | cores − 1 | Decoder threads of the single ffmpeg |

## License

Copyright (c) 2026 Mattia Cabrini

SPDX-License-Identifier: MIT — full text in [LICENSE](LICENSE).
