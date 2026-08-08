# site/img

Two images the site expects. Neither is committed yet.

## `library.png` / `library-2x.png` — the home page screenshot

This carries most of the weight on the home page, so it's worth taking
deliberately rather than grabbing whatever is on screen.

**What to capture:** a finished meeting in the detail view — enhanced notes at
the top, the speakers panel with three or four resolved names, and enough
transcript visible that the per-line attribution is legible. Not the empty
state, not a live recording.

**How:**

- Window at **1440 × 900**. The `.shot` frame is 16:10 and crops to fill, so
  anything near that ratio works, but 1440 × 900 needs no thinking.
- `⌘⇧4`, then space, then click the window. Hold `⌥` while clicking to drop the
  drop shadow — the page draws its own border and shadow, and two of them look
  like a mistake.
- Save as `library-2x.png` (Retina capture, so it's 2880 × 1800), then export a
  1× copy at 1440 × 900 as `library.png`.
- Light appearance. There's no dark variant wired up; if you want one, say so
  and it's a `<picture>` element rather than a redesign.

**Before you shoot:** use a real meeting with real speech in it. Placeholder
dialogue photographs badly and reads as fake — real transcripts have missing
punctuation and mis-heard names, and the page is honest about the app being
early. Rename the participants afterwards if the content is sensitive; renaming
a speaker updates every line they're on.

**If the alt text no longer matches what's in the shot, fix the alt text.**
It's in `index.html` and it describes the picture, not the feature.

## `social-card.png` — the GitHub repository card

1280 × 640, generated rather than shot:

```sh
swift Scripts/render-wordmark.swift
```

That writes `docs/social-card.png`. Copy it here if the site needs it too, or
leave it in `docs/` and point the `og:image` at the GitHub-hosted copy.

## The files in here now are placeholders

`library.png` and `library-2x.png` are a hatched panel that says "screenshot
pending". They exist so the page has correct dimensions in review and so nothing
404s — **they are not shippable.** Replace both before the site goes live; they
are deliberately obvious rather than a plausible-looking fake, so the failure
mode if they slip through is embarrassing rather than misleading.
