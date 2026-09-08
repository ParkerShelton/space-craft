#!/usr/bin/env python3
"""Trims and levels the recordings in sounds/world/ so the game can use them.

What a recording needs before it is a game sound is dull and identical every
time: cut the silence off the front so it lands when the event does, cut the
silence off the end so it does not hold an audio player hostage, fade the last
few ms so it does not click, and set the level. This does that, so it does not
have to be done by hand for eight materials times three events times six takes.

    python tools/prep_recordings.py              # report only, changes nothing
    python tools/prep_recordings.py --write      # actually do it

ORIGINALS ARE NEVER LOST. The first --write copies every file to recordings/raw/
and from then on reads from THERE rather than from sounds/world/. That makes the
script idempotent -- run it ten times and you get the same result, instead of
normalising an already-normalised file into mush -- and it means you can change
a setting below and re-run without having re-recorded anything.

To go back to a raw file, copy it out of recordings/raw/ yourself.

Stdlib only.
"""

import argparse
import os
import shutil
import struct
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "sounds", "world")
RAW = os.path.join(ROOT, "recordings", "raw")

# The events the game knows about, and what each one wants doing to it.
#   peak    -- what to normalise to, as a fraction of full scale. Not 1.0: a
#              sample that touches the ceiling has nowhere to go when the game
#              pitches it up, and clips.
#   max_ms  -- hard cap on length. A footstep that runs for six seconds holds an
#              audio player for six seconds, and there are only twenty.
#   tail_ms -- silence kept after the sound stops, before the fade.
EVENTS = {
	"step": {"peak": 0.70, "max_ms": 700, "tail_ms": 40},
	"mine": {"peak": 0.70, "max_ms": 700, "tail_ms": 40},
	"place": {"peak": 0.75, "max_ms": 900, "tail_ms": 60},
	"break": {"peak": 0.80, "max_ms": 1600, "tail_ms": 120},
}

# Where the sound is judged to start and stop, as a fraction of its own peak.
# Low enough to keep the quiet front edge of a hit -- cutting into the attack is
# far more audible than leaving a few ms of hiss.
GATE = 0.03
LEAD_MS = 6      # kept in front of the first sound, so the attack is intact
FADE_MS = 15     # fade at the very end, so stopping does not click


def read_wav(path):
	with wave.open(path, "rb") as w:
		rate = w.getframerate()
		ch = w.getnchannels()
		width = w.getsampwidth()
		n = w.getnframes()
		raw = w.readframes(n)
	if width != 2:
		raise ValueError("only 16-bit WAV is supported, this is %d-bit"
			% (width * 8))
	x = list(struct.unpack("<%dh" % (len(raw) // 2), raw))
	if ch > 1:
		# Mono is not a preference, it is a requirement: a stereo sample cannot
		# be positioned in 3D, so it would play flat wherever it happened.
		x = [sum(x[i:i + ch]) // ch for i in range(0, len(x) - ch + 1, ch)]
	return x, rate, ch


def write_wav(path, x, rate):
	with wave.open(path, "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(rate)
		w.writeframes(b"".join(
			struct.pack("<h", max(-32768, min(32767, int(v)))) for v in x))


def prep(x, rate, spec, normalize=True):
	"""Trim, cap, fade, level. Returns the new samples."""
	peak = max((abs(v) for v in x), default=0)
	if peak == 0:
		return x, "silent"
	gate = GATE * peak
	start = next((i for i, v in enumerate(x) if abs(v) > gate), 0)
	end = len(x) - next((i for i, v in enumerate(reversed(x)) if abs(v) > gate), 0)
	start = max(0, start - int(LEAD_MS * rate / 1000))
	end = min(len(x), end + int(spec["tail_ms"] * rate / 1000))
	end = min(end, start + int(spec["max_ms"] * rate / 1000))
	y = [float(v) for v in x[start:end]]
	if normalize:
		k = spec["peak"] * 32768.0 / peak
		y = [v * k for v in y]
	fade = min(int(FADE_MS * rate / 1000), len(y) // 3)
	for i in range(fade):
		y[len(y) - 1 - i] *= i / float(fade)
	return y, None


def event_of(name):
	"""The event a filename belongs to, or None if it is not one of ours."""
	base = os.path.splitext(name)[0]
	for ev in EVENTS:
		if base.startswith(ev + "_"):
			return ev
	return None


def main():
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--write", action="store_true",
		help="apply the changes (without this, only reports)")
	ap.add_argument("--no-normalize", action="store_true",
		help="trim and cap length but leave levels exactly as recorded")
	args = ap.parse_args()

	if not os.path.isdir(WORLD):
		print("no such directory:", WORLD)
		return 1
	names = sorted(f for f in os.listdir(WORLD) if f.lower().endswith(".wav"))
	if not names:
		print("nothing to do -- no WAVs in", WORLD)
		return 0

	if args.write:
		os.makedirs(RAW, exist_ok=True)

	skipped = []
	print("%-24s %18s   %s" % ("file", "length", "level"))
	print("-" * 66)
	done = 0
	for name in names:
		ev = event_of(name)
		if ev is None:
			skipped.append(name)
			continue
		live = os.path.join(WORLD, name)
		backup = os.path.join(RAW, name)
		# Once a file has been backed up, the backup is the source. Re-running
		# then re-derives from the original rather than chewing the result.
		src = backup if os.path.exists(backup) else live
		try:
			x, rate, ch = read_wav(src)
		except Exception as e:
			print("%-24s  !! %s" % (name, e))
			continue
		y, note = prep(x, rate, EVENTS[ev], not args.no_normalize)
		if note:
			print("%-24s  !! %s" % (name, note))
			continue
		before_ms = len(x) * 1000 // rate
		after_ms = len(y) * 1000 // rate
		lvl_a = max(abs(v) for v in x) / 32768.0
		lvl_b = max(abs(v) for v in y) / 32768.0
		flag = " <-- was stereo" if ch > 1 else ""
		print("%-24s %6d -> %5d ms   %.2f -> %.2f%s"
			% (name, before_ms, after_ms, lvl_a, lvl_b, flag))
		if args.write:
			if not os.path.exists(backup):
				shutil.copy2(live, backup)
			write_wav(live, y, rate)
		done += 1

	print("-" * 66)
	if skipped:
		print("not touched (name does not match <event>_<material>_<n>.wav):")
		for s in skipped:
			print("   ", s)
	if args.write:
		print("%d file(s) written. Originals are in %s"
			% (done, os.path.relpath(RAW, ROOT)))
	else:
		print("%d file(s) would change. Re-run with --write to apply." % done)
	return 0


if __name__ == "__main__":
	sys.exit(main())
