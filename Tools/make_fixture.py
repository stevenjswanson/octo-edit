#!/usr/bin/env python3
"""Generate a synthetic two-speaker "meeting" for OctoEdit testing.

Produces, in Fixtures/generated/:
  meeting-4k.mp4        source recording (3840x2160 HEVC via libx265 — the Homebrew ffmpeg here is x86_64 under Rosetta, so VideoToolbox is unavailable to it) that
                        starts ZOOM_OFFSET seconds after the Zoom recording
  meeting-1080.mp4      same content at 1080p (faster for iteration)
  meeting.zoom.vtt      Zoom-style transcript on the Zoom clock, with the kinds of
                        text differences a second recognizer produces
  meeting.truth.tsv     ground-truth line timings on the source clock
  tone-4k.mp4           10 s 4K clip with a 1 kHz tone burst every second (render tests)

Speech comes from macOS `say`; media is assembled with ffmpeg.
"""
import os, subprocess, sys, tempfile

OUT = os.path.join(os.path.dirname(__file__), "..", "Fixtures", "generated")
ZOOM_OFFSET = 3.42          # Zoom clock = source clock + ZOOM_OFFSET
GAP = 0.7                   # silence between lines (s)
LEAD = 0.8                  # silence before first line on the Zoom clock
RATE = 48000

VOICES = {"Dean Chen": "Eddy (English (US))", "Steve Swanson": "Flo (English (US))"}

# (speaker, what is spoken, what Zoom's captioner wrote)
LINES = [
    ("Dean Chen", "Are we recording? Okay.", "Are we recording? Okay."),
    ("Steve Swanson", "Welcome everyone. Thanks for making time on a Wednesday.",
     "Welcome everyone. Thanks for making time on a Wednesday."),
    ("Steve Swanson", "Today we have three items: the budget, the hiring plan, and the new building.",
     "Today we have three items, the budget, the hiring plan and the new building."),
    ("Steve Swanson", "So that brings us to the budget.", "So that brings us to the budget."),
    ("Steve Swanson", "For fiscal twenty seven the campus allocation is, um, let me find the, uh, flat in nominal terms.",
     "For FY27 the campus allocation is let me find the flat in nominal terms."),
    ("Steve Swanson", "Which means a real cut of about three percent. We have three options.",
     "Which means a real cut of about 3%. We have three options."),
    ("Dean Chen", "Can you say more about the second one?", "Can you say more about the second one?"),
    ("Steve Swanson", "Sure. The second option defers two faculty searches to next year.",
     "Sure. The second option defers 2 faculty searches to next year."),
    ("Steve Swanson", "So the committee should decide by November.", "So the committee should decide by November."),
    ("Steve Swanson", "Turning to hiring. We have authorization for two searches, and I think, let me check, yes, both in systems.",
     "Turning to hiring. We have authorization for two searches and I think let me check yes, both in systems."),
    ("Dean Chen", "Great. Let's stop there for today.", "Great, let's stop there for today."),
]


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", path], check=True, capture_output=True, text=True)
    return float(out.stdout.strip())


def ts(t):
    h, rem = divmod(max(t, 0.0), 3600)
    m, s = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{s:06.3f}"


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="octofixture-")
    pieces, t = [], LEAD
    concat = os.path.join(tmp, "concat.txt")
    silence = os.path.join(tmp, "gap.wav")
    lead = os.path.join(tmp, "lead.wav")
    run("ffmpeg", "-y", "-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl=mono", "-t", str(GAP), silence)
    run("ffmpeg", "-y", "-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl=mono", "-t", str(LEAD), lead)
    entries = [lead]
    for i, (speaker, spoken, _zoom) in enumerate(LINES):
        aiff = os.path.join(tmp, f"l{i}.aiff")
        wav = os.path.join(tmp, f"l{i}.wav")
        run("say", "-v", VOICES[speaker], "-o", aiff, spoken)
        run("ffmpeg", "-y", "-i", aiff, "-ar", str(RATE), "-ac", "1", wav)
        d = duration(wav)
        pieces.append((t, t + d))
        entries += [wav, silence]
        t += d + GAP
    with open(concat, "w") as f:
        f.writelines(f"file '{p}'\n" for p in entries)
    zoom_audio = os.path.join(tmp, "zoom.wav")
    run("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat, "-c", "pcm_s16le", zoom_audio)
    total = duration(zoom_audio)
    src_len = total - ZOOM_OFFSET
    src_audio = os.path.join(tmp, "source.wav")
    run("ffmpeg", "-y", "-ss", str(ZOOM_OFFSET), "-i", zoom_audio, "-c", "pcm_s16le", src_audio)

    # Zoom VTT (Zoom clock) and ground truth (source clock).
    with open(os.path.join(OUT, "meeting.zoom.vtt"), "w") as f:
        f.write("WEBVTT\n\n")
        for i, ((a, b), (spk, _s, zoom)) in enumerate(zip(pieces, LINES), 1):
            f.write(f"{i}\n{ts(a)} --> {ts(b)}\n{spk}: {zoom}\n\n")
    with open(os.path.join(OUT, "meeting.truth.tsv"), "w") as f:
        f.write("start\tend\tspeaker\ttext\n")
        for (a, b), (spk, spoken, _z) in zip(pieces, LINES):
            f.write(f"{a - ZOOM_OFFSET:.3f}\t{b - ZOOM_OFFSET:.3f}\t{spk}\t{spoken}\n")

    for name, size in (("meeting-4k.mp4", "3840x2160"), ("meeting-1080.mp4", "1920x1080")):
        run("ffmpeg", "-y", "-f", "lavfi", "-i", f"testsrc2=size={size}:rate=30000/1001",
            "-i", src_audio, "-t", f"{src_len:.3f}", "-map", "0:v", "-map", "1:a",
            "-c:v", "libx265", "-preset", "ultrafast", "-crf", "28", "-x265-params", "log-level=error",
            "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
            "-ar", str(RATE), "-shortest", os.path.join(OUT, name))

    # Render-test clip: 10 s, a 50 ms 1 kHz burst at the start of every second.
    run("ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=30000/1001",
        "-f", "lavfi", "-i", f"sine=f=1000:r={RATE},volume='if(lt(mod(t,1),0.05),1,0)':eval=frame",
        "-t", "10", "-c:v", "libx265", "-preset", "ultrafast", "-crf", "28", "-x265-params", "log-level=error", "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "160k", "-ar", str(RATE), os.path.join(OUT, "tone-4k.mp4"))
    print(f"fixtures in {os.path.abspath(OUT)} (source {src_len:.2f}s, zoom offset {ZOOM_OFFSET}s)")


if __name__ == "__main__":
    sys.exit(main())
