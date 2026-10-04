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
| `init --video V [--zoom Z] [--pre 120ms --post 180ms --crossfade 20ms] [--codec hevc\|h264] PKG` | Transcribes V on this Mac (English, first audio track), tightens word edges against the audio, takes speakers and text from the Zoom `.vtt`, and writes an un-annotated `transcript.md`. |
| `render PKG [--check] [--preview] [--clip SLUG]… [--codec …] [--dest DIR]` | Exports each clip as `SLUG.mp4` (input resolution and frame rate, hardware-encoded) plus `SLUG.vtt` captions and a `notes.md`. `--check` only validates; `--preview` makes fast 720p versions in `exports/preview/`. |
| `name PKG [--clip SLUG]… [--apply [--all]]` | Suggests titles with Apple's on-device model into the front matter. `--apply` names unnamed clips; `--all` renames every clip. |

## Marking up `transcript.md`

```markdown
[00:23:46.3] **Steve Swanson:**
{clip "Budget update" -120ms} For FY27 the campus allocation is
~~{+40ms} um, let me find the, uh, {-60ms}~~ flat in nominal terms.
We have three options. {/clip +250ms}

{clip}[^clip-02] An unnamed clip; `octoedit name --apply` will name it. {/clip}

[^clip-02]: Notes for a clip are footnotes keyed by its slug.
    Continuation lines are indented four spaces.
```

| Syntax | Meaning |
|---|---|
| `{clip "Name"}` … `{/clip}` | A clip. The name is optional; the output file is the name's slug (`budget-update`), or `clip-NN` when unnamed. |
| `{clip … -120ms}`, `{/clip +250ms}` | Start 120 ms before the first word; end 250 ms after the last. Without an offset, the `pre`/`post` defaults apply. |
| `~~words~~` | Omitted from the clip (a hard cut with a short audio crossfade). Keep each `~~…~~` on one line; consecutive omitted lines merge. |
| `~~{+40ms} …` / `… {-60ms}~~` | Fine-tune the cut: keep 40 ms after the word before the omission; resume 60 ms before the word after it. Default 0. |
| `[^slug]: text` | Notes for the clip with that slug. |
| `> (00:00:02.1) **Speaker:**` | Zoom-only text (said before or after the recording); can't contain markers. |

Edit the words freely: timing is re-attached on every load by aligning the text with
`words.tsv`, so fixing a misheard word keeps its timing and deleting one shifts nothing.
Words you type that were never spoken have no timing and are ignored for cutting.
Saving from the tool (`name`) rewrites the file in canonical form; after the first time,
diffs stay minimal.

## Package layout

```
meeting.octoedit/
  transcript.md   text + edit markers (the document)
  words.tsv       timed words from ingest; never rewritten
  *.vtt           the original Zoom transcript
  cache/          regenerable (waveform.bin)
  exports/        rendered clips
```

The input video is referenced, never copied (relative path when it sits beside the package).

## Development

```bash
python3 Tools/make_fixture.py   # synthetic 4K meeting + Zoom VTT + ground truth (needs ffmpeg)
swift test                      # unit tests; integration tests run when fixtures exist
```

Components (one SwiftPM target each): `Core` (model, no I/O), `Ingest`, `Load`, `Save`,
`Render`, plus shared `Align`, `MarkupGrammar`, `Naming`, and the framework-bound
`Transcribe` and `Waveform`. `ArchitectureTests` enforces which may import which.
