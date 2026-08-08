# site/fonts

Self-hosted, committed, and MIT-compatible. No third-party font requests — see
the `@font-face` block at the top of `site/tokens.css` for why.

| File | Family | Used for | Bytes | Licence | Source |
| --- | --- | --- | --- | --- | --- |
| `Literata-Regular.woff2` | Literata 400 | Display and H1 only — the wordmark and the one hero claim | 97 440 | OFL 1.1 (`Literata-OFL.txt`) | [googlefonts/literata](https://github.com/googlefonts/literata) `fonts/webfonts/` |
| `IBMPlexSans-Regular.woff2` | IBM Plex Sans 400 | Body, UI, captions | 63 020 | OFL 1.1 (`IBMPlexSans-LICENSE.txt`) | [IBM/plex](https://github.com/IBM/plex) `packages/plex-sans/fonts/complete/woff2/` |
| `IBMPlexSans-SemiBold.woff2` | IBM Plex Sans 600 | H2, H3, labels, emphasis | 67 060 | OFL 1.1 | as above |
| `JetBrainsMono-Regular.woff2` | JetBrains Mono 400 | Shell commands, file paths, version numbers | 92 380 | OFL 1.1 (`JetBrainsMono-OFL.txt`) | [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono) `fonts/webfonts/` |

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

## These are full character sets

Between them these four files are about **320 KB**, because each covers Latin
Extended, Greek and Cyrillic. The site is English. Subsetting to Latin cuts it
to roughly a third:

```sh
./Scripts/build-fonts.sh
```

That rewrites the four woff2 in place. It needs `fonttools` with brotli
(`pip install 'fonttools[woff]' brotli`) and it is worth running before the
site ships — but the site is correct either way, so it is not a build step and
nothing in CI depends on it. Re-run it if a font is ever replaced.

Keep the originals: `git` has them, and `build-fonts.sh` refuses to run twice
on an already-subsetted file.
