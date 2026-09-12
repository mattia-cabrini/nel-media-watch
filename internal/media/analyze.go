// Copyright (c) 2026 Mattia Cabrini
// SPDX-License-Identifier: MIT

package media

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"nel-media-watch/internal/identity"
	"nel-media-watch/internal/verdict"
)

// Analysis thresholds (specification, section 8).
const (
	// minimumSizeBytes: below 100 KB it cannot be a sane clip.
	minimumSizeBytes = 102400
	// minimumDurationSeconds: a shorter or absent duration is
	// Corrupted.
	minimumDurationSeconds = 0.5
	// minimumCoveragePercent: decoded over declared duration; less is
	// a truncated file.
	minimumCoveragePercent = 98.0
)

// errVanished reports a file that no longer exists at analysis time.
var errVanished = errors.New("file vanished before the analysis")

// Refusal tells a failure about one file from a failure of the tools.
// A tool ran and turned the file down -- it vanished, could not be
// read, or the decode was cut short from outside -- and that file alone
// is affected.  Anything else (a tool missing, a fork that fails) would
// affect every file the same way, and a snapshot or a registry built
// on it would only record the breakdown.
func Refusal(err error) bool {
	var exit *exec.ExitError
	return errors.Is(err, errVanished) || errors.As(err, &exit)
}

// Analyzer runs the full integrity analysis of one media file.
type Analyzer struct {
	// Threads is what ffmpeg gets with -threads.  Decodes run one at a
	// time, so this is the whole decoding footprint of the program.
	Threads int
	// As is the identity that reads the file.
	As identity.Identity
}

// Analyze classifies the content of one file (specification, section
// 8):
//
//	8.1 pre-check with ffprobe: openability, duration, size;
//	8.2 full software decode of every frame (ffmpeg -f null -);
//	8.3 duration coverage against the container duration (anti-truncation);
//	8.4 classification.
//
// A Corrupted verdict is a SUCCESSFUL analysis of a broken file.  An
// error is something else entirely: a refusal (see Refusal) or a tool
// that could not run at all.  No verdict exists then, so nothing gets
// cached.
//
// Forbidden by the specification, and deliberately absent: -xerror,
// -err_detect +explode, hardware acceleration, *_cuvid / *_v4l2m2m
// decoders, -c copy.
func (a Analyzer) Analyze(path string) (verdict.Verdict, error) {
	// A file gone since the snapshot has no content left to judge.
	// Caching a verdict about it would pin "Corrupted" on a digest that
	// intact copies of the same content share.  This look runs as the
	// program itself and is only a first line: on a root-squashed tree
	// root may not even be allowed to look, so ffprobe, which runs as
	// RUN_AS, has the last word on it below.
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		return verdict.Verdict{}, errVanished
	}

	/* 8.1  Pre-check. */
	probe, err := a.probe(path)
	if errors.Is(err, errVanished) {
		return verdict.Verdict{}, err
	}
	if Refusal(err) {
		return corrupted(0, "ffprobe cannot open the file"), nil
	}
	if err != nil {
		return verdict.Verdict{}, err
	}
	if probe.duration < minimumDurationSeconds {
		reason := fmt.Sprintf("declared duration '%s' below minimum %gs",
			probe.rawDuration, minimumDurationSeconds)
		return corrupted(0, reason), nil
	}
	if probe.size < minimumSizeBytes {
		reason := fmt.Sprintf("size %d bytes below minimum %d", probe.size, minimumSizeBytes)
		return corrupted(0, reason), nil
	}

	/* 8.2  Full decode, and 8.3 coverage. */
	decode, err := a.decode(path)
	if err != nil {
		return verdict.Verdict{}, err
	}
	// microseconds / 1e6 / duration * 100 == microseconds / 1e4 / duration,
	// rounded to a tenth of a percent, which is also how it is stored.
	coverage := math.Round(float64(decode.decodedMicroseconds)/10000/probe.duration*10) / 10

	/* 8.4  Classification. */
	if decode.exitCode != 0 {
		reason := fmt.Sprintf("decode stopped before EOF (ffmpeg exit %d)", decode.exitCode)
		return corrupted(coverage, reason), nil
	}
	if coverage < minimumCoveragePercent {
		return corrupted(coverage, fmt.Sprintf("stops@%.1f%%", coverage)), nil
	}
	if decode.errorLines > 0 {
		return verdict.Verdict{
			State:     verdict.Degraded,
			Integrity: coverage,
			Reason:    fmt.Sprintf("%d decoder error line(s)", decode.errorLines),
		}, nil
	}
	return verdict.Verdict{State: verdict.OK, Integrity: coverage}, nil
}

func corrupted(coverage float64, reason string) verdict.Verdict {
	return verdict.Verdict{State: verdict.Corrupted, Integrity: coverage, Reason: reason}
}

/* ----------------------------------------------------------------------------
 * 8.1  ffprobe
 * ---------------------------------------------------------------------------- */

type probeResult struct {
	duration    float64
	rawDuration string
	size        int64
}

// probe asks ffprobe for the declared duration and the size of the
// file.  The size comes from ffprobe rather than from stat because
// ffprobe runs as RUN_AS: on a root-squashed target it can see what
// this process cannot.  errVanished means the file is gone; an
// *exec.ExitError means ffprobe could not open it; any other error
// means ffprobe could not run.
func (a Analyzer) probe(path string) (probeResult, error) {
	command := exec.Command("ffprobe", "-v", "error",
		"-show_entries", "format=duration,size",
		"-of", "default=noprint_wrappers=1",
		path)
	a.As.Apply(command)

	output, err := command.Output()
	if err != nil {
		// Running as RUN_AS, ffprobe is the authority on whether the
		// file is still there: its "No such file or directory" is a
		// vanished file, not a corrupted one.
		var refused *exec.ExitError
		if errors.As(err, &refused) && bytes.Contains(refused.Stderr, []byte("No such file or directory")) {
			return probeResult{}, errVanished
		}
		return probeResult{}, fmt.Errorf("ffprobe %s: %w", path, err)
	}

	// The output is one "key=value" line per entry asked for.
	var result probeResult
	for _, line := range strings.Split(string(output), "\n") {
		key, value, _ := strings.Cut(strings.TrimSpace(line), "=")
		switch key {
		case "duration":
			// "N/A" and an empty value parse to 0 and fail the minimum
			// above, which is exactly what they deserve.
			result.rawDuration = value
			result.duration, _ = strconv.ParseFloat(value, 64)
		case "size":
			result.size, _ = strconv.ParseInt(value, 10, 64)
		}
	}
	return result, nil
}

/* ----------------------------------------------------------------------------
 * 8.2  ffmpeg
 * ---------------------------------------------------------------------------- */

type decodeResult struct {
	exitCode            int
	decodedMicroseconds int64
	errorLines          int
}

// decode runs the full software decode and reports how far it got.
//
//	-f null -         decode every frame, discard the output;
//	-map 0:v / 0:a?   video always, audio if present -- the data/bin_data
//	                  telemetry stream of dashcam .ts files is never
//	                  mapped, so it cannot influence the verdict;
//	-progress pipe:1  with -v error ffmpeg prints no stats, so how far the
//	                  decode got is read from its machine-readable progress
//	                  report, sent to stdout.  Nothing else lands there:
//	                  the null muxer opens no output file at all (it is
//	                  AVFMT_NOFILE), the '-' notwithstanding;
//	-v error          stderr then carries decoder error lines only, which
//	                  are counted.
//
// Both outputs are simply buffered in memory: the progress report is a
// few hundred bytes per second of decoding, and even the error lines of
// a hopelessly damaged file amount to megabytes, not more.
func (a Analyzer) decode(path string) (decodeResult, error) {
	command := exec.Command("ffmpeg", "-nostdin", "-hide_banner", "-v", "error",
		"-threads", strconv.Itoa(a.Threads),
		"-err_detect", "+crccheck+bitstream+buffer",
		"-progress", "pipe:1",
		"-i", path, "-map", "0:v", "-map", "0:a?",
		"-f", "null", "-")
	a.As.Apply(command)
	var progress, diagnostics bytes.Buffer
	command.Stdout = &progress
	command.Stderr = &diagnostics

	if err := command.Run(); err != nil {
		// A decode ffmpeg itself gave up on is a verdict, carried by
		// its exit code.  One cut short from outside -- killed, out of
		// memory -- reports -1 and says nothing about the file; ffmpeg
		// not running at all says even less.
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() < 0 {
			return decodeResult{}, fmt.Errorf("ffmpeg %s: %w", path, err)
		}
	}
	return decodeResult{
		exitCode:            command.ProcessState.ExitCode(),
		decodedMicroseconds: lastDecodedMicroseconds(progress.String()),
		errorLines:          countNonBlankLines(diagnostics.String()),
	}, nil
}

// lastDecodedMicroseconds follows ffmpeg's progress report and keeps
// the last out_time_us value: how far the decode actually got.  Before
// the first frame ffmpeg reports N/A, which is simply not a number and
// is ignored.
func lastDecodedMicroseconds(report string) int64 {
	var last int64
	for _, line := range strings.Split(report, "\n") {
		key, value, _ := strings.Cut(line, "=")
		if key != "out_time_us" {
			continue
		}
		if parsed, err := strconv.ParseInt(value, 10, 64); err == nil && parsed >= 0 {
			last = parsed
		}
	}
	return last
}

func countNonBlankLines(text string) int {
	count := 0
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) != "" {
			count++
		}
	}
	return count
}
