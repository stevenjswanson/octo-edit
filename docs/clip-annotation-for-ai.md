# Annotating an OctoEdit transcript into clips — instructions for an AI

You will be given an OctoEdit `transcript.md`: the full transcript of a recorded talk or
meeting. Clips are marked by inserting markers into the text, and OctoEdit then cuts the
video from those markers. It knows when every word was spoken, so you never deal with
times. This document covers only how to write the markers correctly. Which clips to
make is decided by separate instructions.

**Your output is the same file, word for word, with markers added.** Nothing else
changes.

---

## 1. What the file looks like

```markdown
---
octoedit: 1
source: ../2026_09_28_CSE_Seminar_Taitano.mp4
zoom: { file: GMT20260928-180631_Recording.transcript.vtt, offset: 257.812 }
defaults: { pre: 120ms, post: 180ms, crossfade: 20ms }
---

> (00:00:02.0) **Moderator:**
> Are we recording? Okay.

[00:20:31.9] **Kylie:**
Um, but with Agentic AI, like, our value is no longer in writing the code.

[00:20:58.3] **Kylie:**
I tried to think of another analogy that this was like, and the only thing …
```

| Part | What it is | What you do with it |
|---|---|---|
| Lines between the two `---` (front matter) | Settings | Copy unchanged |
| `[hh:mm:ss.d] **Speaker:**` | Paragraph header: start time and speaker | Copy unchanged; use the time and speaker for context |
| The line(s) after a header, until a blank line | That paragraph's words | Insert markers between words |
| `> (hh:mm:ss.d) **Speaker:**` and lines starting `> ` | **Zoom-only** text: in the meeting transcript but **not in the video** | Copy unchanged; never put a marker in it |
| `[^name]: …` lines at the end | Notes attached to clips | Copy unchanged (you may add your own; see §3) |
| Existing `{clip …}`, `{/clip}`, `~~`, `{+40ms}` markers | Clips someone already marked | Copy unchanged unless you were asked to redo them |

A paragraph is normally one line. The words carry recognition errors ("Claude Code" may
appear as "Cloud Code"). **Do not fix them.** Corrections are made separately, and OctoEdit
matches the text to the recording word by word.

---

## 2. The markers

| Marker | Meaning |
|---|---|
| `{clip "Title"}` | A clip starts at the **next** word |
| `{/clip}` | The clip ends after the **previous** word |
| `~~` … `~~` | The enclosed words are **cut out** of the clip they're in (outside a clip they stay marked, so a clip later drawn over them leaves them out) |
| `[^slug]` | Directly after `{clip "Title"}`: points to this clip's note (§3) |

Write each marker as its own space-separated token:

```
… back when it was started. {clip "Why AI makes old code worth fixing"} And so… it wasn't a matter of …
… make sure that what it's doing is right, {/clip} because it's working with …
… We have three options. ~~Um, let me find the, uh,~~ The first is …
```

**Titles** are written inside double quotes. A `"` inside a title is written `\"`, and a
`\` is written `\\`. The output file name is made from the title: `{clip "What makes a
good SWE today?"}` becomes `what-makes-a-good-swe-today-4k.mp4`. A bare `{clip}` (no
title) is allowed; such clips are named `clip-01`, `clip-02`, … in document order.

**Padding is automatic.** The video starts 120 ms before the first word and ends 180 ms
after the last word, so breaths and word edges aren't clipped. Cuts at `~~` are joined
with a short audio crossfade.

**Do not write timing offsets** such as `{clip "Title" -200ms}`, `{/clip +300ms}`, or
`{+40ms}` inside a fence. They fine-tune a cut by milliseconds and need someone to listen
to the audio. Leave any existing ones exactly as they are.

---

## 3. Optional: a note for a clip

To attach a note to a clip, put `[^slug]` right after the clip's start marker. Then add a definition at the very end of the
file, after a blank line:

```
{clip "A CS degree is a Swiss Army knife"}[^a-cs-degree-is-a-swiss-army-knife] And so, yeah, …

[^a-cs-degree-is-a-swiss-army-knife]: The note's text.
    A second line of the note is indented four spaces.
```

The **slug** is the title in lower case, with every run of characters other than letters
and digits replaced by a single `-`, and no leading or trailing `-`. For example, `What's
the new role of software engineers?` becomes `what-s-the-new-role-of-software-engineers`.

---

## 4. Rules OctoEdit enforces

OctoEdit rejects a file that breaks rules 1–9. Rules 10–11 only produce warnings, but
follow them too.

1. **Keep every word exactly as it is.** Don't add, remove, reorder, re-punctuate or
   correct words. Don't re-wrap lines, merge or split paragraphs, or touch headers.
2. **Every `{clip}` has a matching `{/clip}`,** later in the text. A clip may start in one
   paragraph and end in a later one.
3. **Clips never overlap or nest.** Close one clip before opening the next.
4. **`~~` fences come in pairs.** A fence can't contain a clip marker, and a clip marker
   can't sit inside a fence. Fences are normally inside a clip; one outside every clip is
   allowed and does nothing until a clip includes those words.
5. **A fence opens and closes within one paragraph.** To cut text that continues into the
   next paragraph, close the fence at the end of the first paragraph and open a new one at
   the start of the next. OctoEdit joins the two into one cut.
6. **No markers in Zoom-only (`>`) paragraphs.** Their words aren't in the video. A clip
   may run past a `>` paragraph, but none of the clip's markers or fences may sit inside it.
7. **A clip must keep at least one word** outside its fences.
8. **Markers are spelled exactly as shown:** `{clip "…"}`, `{/clip}`, `~~`.
9. **Titles are double-quoted,** with `\"` and `\\` escapes.
10. **Don't start or end a clip with a fence.** Move the `{clip}` or `{/clip}` marker
    instead.
11. **Give every clip a different title.** Duplicates get `-2`, `-3` appended to their
    file names.

---

## 5. Worked example

**Before:**

```markdown
[00:41:24.1] **CSE Seminar #1:**
Yeah, Um, so Intuit is a 40-plus-year-old company now. As you can imagine, we have tech that was built back when it was started.

[00:41:34.6] **CSE Seminar #1:**
And so… it wasn't a matter of we couldn't do it technically, it was a business decision, right? Because engineers cost money, it costs money to analyze the code, analyze all of this code that people who retired many, many years ago wrote. Um, And so, what… these models have allowed us to do is push these… this tech debt, quite frankly, um, to… be a priority, because it can analyze the codebase faster. Now, it can't do the work on its own.

[00:42:07.3] **CSE Seminar #1:**
still needs the human experts, tax tax experts that we have, our brightest engineers and architects that we work with, to make sure that what it's doing is right, because it's working with really old code.
```

**After:**

```markdown
[00:41:24.1] **CSE Seminar #1:**
Yeah, Um, so {clip "Why AI makes decades-old code worth fixing"} Intuit is a 40-plus-year-old company now. As you can imagine, we have tech that was built back when it was started.

[00:41:34.6] **CSE Seminar #1:**
And so… it wasn't a matter of we couldn't do it technically, it was a business decision, right? Because engineers cost money, it costs money to analyze the code, ~~analyze all of this code that people who retired many, many years ago wrote. Um, And so, what…~~ these models have allowed us to do is push ~~these…~~ this tech debt, ~~quite frankly, um,~~ to… be a priority, because it can analyze the codebase faster. Now, it can't do the work on its own.

[00:42:07.3] **CSE Seminar #1:**
still needs the human experts, tax tax experts that we have, our brightest engineers and architects that we work with, to make sure that what it's doing is right, {/clip} because it's working with really old code.
```

Note in the example:
- **The clip spans three paragraphs.** It opens before the first word of one paragraph and
  closes mid-paragraph two paragraphs later.
- **"Yeah, Um, so" is left out of the clip** by placing `{clip}` after it, not by
  fencing it (rule 10).
- **Each fence opens and closes within its paragraph** and sits inside the clip.
- **Text after `{/clip}`** ("because it's working with really old code.") is outside the
  clip and stays in the file unchanged.
- **"tax tax"** stays: words are never corrected.

---

## 6. What to return

Return **the complete `transcript.md`**:

- the front matter exactly as given;
- every header and paragraph in the original order, with markers inserted;
- the original notes block, plus any notes you added.


### Checklist before returning

- [ ] With markers, fences and note references removed, the text is identical to the input.
- [ ] Every `{clip "…"}` has a `{/clip}` after it, before the next `{clip`.
- [ ] Every `~~` is paired within one paragraph.
- [ ] Nothing was added inside `>` paragraphs.
- [ ] No timing offsets were added.
- [ ] Titles are unique and double-quoted, with `\"` and `\\` escapes.

### Checking your work

Run `octoedit render --check --json <project>.octoedit` after saving the file. It prints a
JSON report: `"valid": true` and the clips found (title, slug, duration, number of cuts,
and the first and last words kept), or `"valid": false` with each problem's line number
and message. Fix every `"severity": "error"` issue and check again until the report says
`"valid": true`. Exit code 0 means valid; 1 means `transcript.md` has errors.

These instructions are also printed by `octoedit guide`.
