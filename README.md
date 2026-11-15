# OctoEdit

Cut a recorded meeting into clips by editing its transcript. Stage A (this) is the
headless pipeline: a command-line tool, with any text editor standing in for the GUI.

```bash
swift build -c release
.build/release/octoedit init --video meeting-4k.mp4 --zoom meeting.vtt meeting.octoedit
# mark clips in meeting.octoedit/transcript.md, then:
.build/release/octoedit render --check meeting.octoedit
.build/release/octoedit render meeting.octoedit
```

Requires macOS 26 (on-device `SpeechAnalyzer`; Apple Intelligence for name suggestions).

## Commands

| Command | What it does |
|---|---|
| `init --video V [--zoom Z] [--speakers "A, B" \| --no-speakers] [--no-faces] [--pre 120ms --post 180ms --crossfade 20ms] [--codec hevc\|h264] PKG` | Transcribes V on this Mac (English, first audio track), tightens word edges against the audio, takes speakers and text from the Zoom `.vtt`, and writes an un-annotated `transcript.md`. Also finds who speaks when (as `speakers` below; `--speakers` gives the roster to name voices from, `--no-speakers` skips it) and then finds faces (as `faces` below; `--no-faces` skips it and writes `faces: off`). The app's Import window does the same, with checkboxes for both. |
| `faces PKG` | Finds faces through the video into `cache/faces.tsv` (about ⅓ of the video's length for 4K), for speaker portraits and 9:16 framing. `init` and `replace-video` do this unless told `--no-faces`; `speakers` takes `--faces`. The app does it in the background whenever the cache is missing, unless the project says `faces: off`. |
| `speakers PKG [--speakers "A, B"] [--faces]` | Finds who speaks when from the voices: every voice change starts a paragraph, and voices are named from the roster (or Speaker 1, 2, …). Resets every speaker name; markers stay on their words. Lists turns under a second to check. |
| `replace-video --video V PKG [--faces]` | Points the project at another video of the same recording, e.g. the high-resolution original, which may start earlier or later (in the app: File ▸ Replace Video…). Transcribes V and compares the two transcriptions (and waveforms) to find how far apart the two clocks are. If that distance is steady, the old word timings are kept and moved by it, so cuts land where they did; if the two drift, word times come from the new transcription and clips whose length changed are listed to check. Text, clips, speakers and notes are untouched. Removes `cache/faces.tsv` (it was scanned from the old video), rescans the new one and says how the speakers with a face changed (unless `faces: off` or `--no-faces`). |
| `render PKG [--check] [--preview] [--clip SLUG]… [--codec …] [--framing source\|9:16] [--dest DIR]` | Exports each clip into its own folder `exports/C01-SLUG/`: `C01-SLUG-4k.mp4` (input resolution and frame rate, hardware-encoded) plus `.vtt` captions, `.timeline.json` (who speaks when and where the cuts are, on the clip's own clock) and `.md` notes of the same name. `C01` is the clip's place in the video, zero-padded (`C001` from 100 clips), so exports list in video order; `--clip` takes the bare slug. `--check` only validates; `--preview` makes fast 720p `C01-SLUG.preview.mp4` files in `exports/preview/`. |
| `stills PKG [--clip SLUG] [--set SLUG=TIME\|N\|auto]… [--images DIR]` | Each clip's title-card still (see `still=` below): which frame, whether it was picked automatically, and its score. `--clip` lists that clip's candidates (numbered, best first, from its opening, later in the clip and the rest of the talk); `--set` chooses one by time or number, or goes back to `auto`, and saves `transcript.md`; `--images` writes them as JPEGs to look at. Needs `cache/faces.tsv`. |
| `name PKG [--clip SLUG]… [--apply [--all]]` | Suggests titles with Apple's on-device model into the front matter. `--apply` names unnamed clips; `--all` renames every clip. |

## Marking up `transcript.md`

```markdown
[00:23:46.3] **Steve Swanson:**
{clip "Budget update" -120ms} For FY27 the campus allocation is ~~{+40ms} um, let me find the, uh, {-60ms}~~ flat in nominal terms. We have three options. {/clip +250ms}

{clip}[^clip-02] An unnamed clip; `octoedit name --apply` will name it. {/clip}

[^clip-02]: Notes for a clip are footnotes keyed by its slug.
    Continuation lines are indented four spaces.
```

| Syntax | Meaning |
|---|---|
| `{clip "Name"}` … `{/clip}` | A clip. The name is optional; the output file is the name's slug (`budget-update`), or `clip-NN` when unnamed. |
| `{clip "Name" nolevels}` | The clip without auto-levels. Clips have auto-levels by default: brightness, contrast and colour evened out as Photos' auto-enhance does, measured once over the clip and applied to every frame. In the app: the clip's **Auto levels** checkbox. (`levels`, written by older versions, means on.) |
| `{clip "Name" noexport}` | Left out of exports and supercuts (the app's **Export** checkbox under the clip, unchecked); `octoedit render --clip` can still export it by name. Flags go after the offset, in any order. |
| `{clip "Name" still=00:58:01.233}` | The title card's picture: a time in the source recording (`hh:mm:ss.mmm`, to the millisecond, so it names one exact frame), anywhere in the talk. Without it the still is picked automatically: the best frame of the clip's main speaker in its first 10 s of kept video (sharp face, eyes open and on the audience, mouth closed, no motion or nearby cut), else later in the clip, else a good frame from elsewhere in the talk near the clip. In the app: **Title card** in the clip panel, **Choose…** opens the picker; **Automatic** removes the flag. A file with a `still=` is written as `octoedit: 2` (older builds would reject the flag); one without stays `octoedit: 1`, so older files open and save unchanged. |
| `{clip … -120ms}`, `{/clip +250ms}` | Start 120 ms before the first word; end 250 ms after the last. Without an offset, the `pre`/`post` defaults apply. |
| `~~words~~` | Omitted from the clip (a hard cut with a short audio crossfade). Omitted text that continues into the next paragraph is fenced again there; the pieces merge. |
| `~~{+40ms} …` / `… {-60ms}~~` | Adjust the cut at an omission: `{+40ms}` just inside the opening `~~` keeps 40 ms after the word before it; `{-60ms}` just inside the closing `~~` resumes 60 ms before the word after it. Default 0 (word edges are already tightened to the speech). |
| `[^slug]: text` | Notes for the clip with that slug. |
| `> (00:00:02.1) **Speaker:**` | Zoom-only text (said before or after the recording); can't contain markers. |
| `[00:23:46.3] **Speaker:**` | Starts a paragraph. Each paragraph has one speaker; to change who said some words, split the paragraph and give the new part its own header. |
| `speakers: [Mia Minnes, Kathy]` (front matter) | The roster of speaker names. Header names missing from it are added on load; the tool writes it in order of first appearance, with unused names last. |
| `defaults: { …, framing: "9:16" }` (front matter) | Output shape: `source` (default, as the video came in) or `"9:16"` (a full-height column centred on whoever is speaking, moving to the new speaker with a quick dip through black when the speaker changes (a hard cut where the source itself cuts); needs `octoedit faces`). Exports are named `SLUG-4k-9x16.*`. |
| `defaults: { …, faces: off }` (front matter) | Don't find faces on their own: the app won't start a scan when `cache/faces.tsv` is missing, and `replace-video` won't rescan. Asking for one (`octoedit faces`, Find Faces) still works. Default `on`. |

Edit the words freely: timing is re-attached on every load by aligning the text with
`words.tsv`, so fixing a misheard word keeps its timing and deleting one shifts nothing.
Words you type that were never spoken have no timing and are ignored for cutting.
The tool writes each paragraph on a single line (turn on soft wrap in your editor). Saving
from the tool (`name`) rewrites the file in that canonical form; after the first time, diffs
stay minimal.

## Package layout

```
meeting.octoedit/
  transcript.md   text + edit markers (the document)
  words.tsv       timed words from ingest; rewritten only by replace-video
  *.vtt           the original Zoom transcript
  cache/          regenerable (waveform.bin, faces.tsv: face boxes, no fingerprints;
                  stills.tsv: scores of frames considered for title-card stills);
                  after replace-video, also words.before-replace.tsv (the old words.tsv)
  exports/        rendered clips, one folder per clip (C01-SLUG/); previews in preview/
```

The input video is referenced, never copied (relative path when it sits beside the package).

## Timeline sidecar

Each export (clip or supercut) gets `<name>.timeline.json` beside its `.mp4` in the clip's folder, so other tools
can see who speaks when and where the cuts are without parsing `transcript.md`. All times
are seconds on the exported file's own clock, from the frame-snapped ranges the encoder used.

| key | contents |
|---|---|
| `source`, `duration`, `speakers` | input video path, file length, speakers in order of appearance |
| `clips` | `{slug, title, start, end}` per clip in the file (several for a supercut) |
| `segments` | `{clip, start, end, sourceStart, sourceEnd}` per kept run; every boundary between two segments is a cut |
| `turns` | `{speaker, start, end, text}`: consecutive kept words by one speaker (may span a cut; a new turn at each speaker or clip change) |
| `words` | `{start, end, speaker, segment, text}` per kept, timed word |
| `titlecard` | `{time, auto, image}` (single clips, when a face was found): the title card's still. `time` is on the source's clock; `image` is `<name>.still.jpg` beside the timeline, that exact frame framed like the export (a full-height 9:16 column on the speaker's face) with the clip's auto levels, at source resolution. brand-clip draws the title card on it. |

Arrays are written one element per line. `octoedit render --help` documents the same format. Words typed by hand (untimed) are left out, as in the captions.

## Development

```bash
python3 Tools/make_fixture.py   # synthetic 4K meeting + Zoom VTT + ground truth (needs ffmpeg)
swift test                      # unit tests; integration tests run when fixtures exist
```

Components (one SwiftPM target each): `Core` (model, no I/O), `Ingest`, `Load`, `Save`,
`Render`, plus shared `Align`, `MarkupGrammar`, `Naming`, `SpeakerFraming` (whose face is whose, and the 9:16 column), and the framework-bound
`Transcribe`, `Waveform`, `FaceTrack` (Vision) and `Diarize` (FluidAudio, the only third-party audio code;
its 21 MB of models download once on first use). `ArchitectureTests` enforces which may import which.
