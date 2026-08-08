# site/fonts

Self-hosted, committed, and MIT-compatible. No third-party font requests — see
the `@font-face` block at the top of `site/tokens.css` for why.

| File | Family | Used for | Bytes | Licence | Source |
| --- | --- | --- | --- | --- | --- |
| `Literata-Regular.woff2` | Literata 400 | Display and H1 only — the wordmark and the one hero claim | 15 804 (Latin subset) | OFL 1.1 (`Literata-OFL.txt`) | [googlefonts/literata](https://github.com/googlefonts/literata) `fonts/webfonts/` |
| `IBMPlexSans-Regular.woff2` | IBM Plex Sans 400 | Body, UI, captions | 63 020 (unmodified) | OFL 1.1 (`IBMPlexSans-LICENSE.txt`) | [IBM/plex](https://github.com/IBM/plex) `packages/plex-sans/fonts/complete/woff2/` |
| `IBMPlexSans-SemiBold.woff2` | IBM Plex Sans 600 | H2, H3, labels, emphasis | 67 060 (unmodified) | OFL 1.1 | as above |
| `JetBrainsMono-Regular.woff2` | JetBrains Mono 400 | Shell commands, file paths, version numbers | 19 328 (Latin subset) | OFL 1.1 (`JetBrainsMono-OFL.txt`) | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) `fonts/webfonts/` |
| `Literata-Regular.ttf` | Literata 400 | Not loaded by the site — full-charset face `Scripts/render-wordmark.swift` sets the wordmark from | 317 852 (full) | OFL 1.1 | decompressed from the upstream woff2 |

All four are SIL Open Font License 1.1. OFL permits redistribution inside a
larger work, including a commercial one, provided the licence travels with the
files and the fonts are not sold on their own. The licence files above satisfy
that. **The OFL does not attach to the site or to Cheerio** — the repository
stays MIT, exactly the way the NVIDIA model licence is kept off the source tree.

The wordmark's outlines are a separate matter and are already clean: outlines
emitted by `Scripts/render-wordmark.swift` are geometry, not font data, so the
SVGs inherit nothing from the OFL.

## Weights

Only 400 and 600 are committed for the sans, and only 400 for the serif and the
mono. Do not ask CSS for a weight that isn't here — browsers will synthesise it
by smearing the outlines, which looks acceptable in a heading and bad in a
paragraph. If a design genuinely needs a third weight, commit it.

## Subsetting — who is, who isn't

Literata and JetBrains Mono are committed as **Latin subsets** (the upstream
files also carry Latin Extended, Greek and Cyrillic; the site is English).
The subsetting lives in:

```sh
./Scripts/build-fonts.sh
```

It rewrites those two woff2 in place, needs `fonttools` with brotli
(`pip install 'fonttools[woff]' brotli`), and refuses to run twice on an
already-subsetted file. Re-run it only when one of those fonts is replaced
with a fresh upstream file — the originals aren't in git, so fetch them from
the sources in the table above if you ever need the full coverage back.

**IBM Plex is committed unmodified and must stay that way** unless it's
renamed: its OFL declares *Plex* a Reserved Font Name, and a subset is a
Modified Version that may not use the name (see `IBMPlexSans-LICENSE.txt`).
Literata and JetBrains Mono reserve no names, which is why they can be
subsetted and keep theirs. All four together are about **165 KB**.
