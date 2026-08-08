# Cheerio token map — website CSS → `Assets.xcassets`

The app can't consume CSS, so this table is how the system crosses over. Every row
is one **Color Set** to create in `Assets.xcassets`, with **Any Appearance** and
**Dark** variants set to the hex values given. Code then references semantic names,
never hex.

Asset folders use **Provides Namespace**, so the Swift reference is the full path:

```swift
Color("Speaker/Slot1")
Color("Surface/Page")
```

Contrast figures are WCAG 2.1 against that token's intended background.

---

## Surfaces

| CSS custom property | Color Set | Light | Dark |
| --- | --- | --- | --- |
| `--ch-surface-page` | `Surface/Page` | `#FAFAF9` | `#14181F` |
| `--ch-surface-raised` | `Surface/Raised` | `#FFFFFF` | `#1C222C` |
| `--ch-surface-sunken` | `Surface/Sunken` | `#F2F4F5` | `#090E13` |

Prefer SwiftUI's own materials for sidebars, popovers and the `MenuBarExtra`
panel. These sets are for content surfaces the system doesn't already vend.

## Text

| CSS custom property | Color Set | Light | Dark | On page |
| --- | --- | --- | --- | --- |
| `--ch-text-primary` | `Text/Primary` | `#171B1F` | `#EBEFF2` | 16.6 / 15.4 |
| `--ch-text-secondary` | `Text/Secondary` | `#606468` | `#A6ABB1` | 5.7 / 7.7 |
| `--ch-text-tertiary` | `Text/Tertiary` | `#83868A` | `#7B8187` | 3.5 / 4.5 |
| `--ch-text-on-accent` | `Text/OnAccent` | `#FFFFFF` | `#0E1218` | — |

`Text/Tertiary` is below AA on light and is for **non-essential** text only —
decorative timestamps, disabled affordances. Never a label a user must read.

## Borders

| CSS custom property | Color Set | Light | Dark |
| --- | --- | --- | --- |
| `--ch-border-subtle` | `Border/Subtle` | `#E3E5E7` | `#25292F` |
| `--ch-border-default` | `Border/Default` | `#CED1D4` | `#353B42` |
| `--ch-border-strong` | `Border/Strong` | `#A8ABAE` | `#515961` |

## Brand

Anchored by the shipped app icon (PR #15). Not a replacement accent — everything
else is built outward from these four.

| CSS custom property | Color Set | Light | Dark | Source |
| --- | --- | --- | --- | --- |
| `--ch-navy-900` | `Brand/Navy900` | `#1E2B3F` | `#1E2B3F` | icon gradient, deep end |
| `--ch-navy-700` | `Brand/Navy700` | `#2A3A55` | `#2A3A55` | derived midpoint |
| `--ch-navy-500` | `Brand/Navy500` | `#35496B` | `#35496B` | icon gradient, light end |
| `--ch-copper-700` | `Brand/Copper700` | `#A87040` | `#A87040` | icon ring, deep end |
| `--ch-copper-500` | `Brand/Copper500` | `#C08757` | `#C08757` | derived midpoint |
| `--ch-copper-300` | `Brand/Copper300` | `#D49E6C` | `#D49E6C` | icon ring, light end |

Brand values are **appearance-invariant** — the icon is the same object in both
modes. Where copper has to carry text or a control, use `Accent` below instead;
raw `Copper700` is 3.98:1 on the light page and fails AA.

## Accent

| CSS custom property | Color Set | Light | Dark | On page |
| --- | --- | --- | --- | --- |
| `--ch-accent` | `Accent/Default` | `#8C5D32` | `#E2B487` | 5.4 / 9.4 |
| `--ch-accent-hover` | `Accent/Hover` | `#794C20` | `#F1C9A1` | 7.0 / 11.5 |
| `--ch-accent-quiet` | `Accent/Quiet` | `#F7EEE7` | `#2A1C10` | fill only |

## Semantic states

The CVD-safe set. **Never the only signal** — always an SF Symbol and a text
label alongside. Never traditional red/green pairing.

| CSS custom property | Color Set | Light | Dark | Symbol |
| --- | --- | --- | --- | --- |
| `--ch-success` | `State/Success` | `#1A7A5C` | `#69D4BE` | `checkmark.circle` |
| `--ch-attention` | `State/Attention` | `#946000` | `#E9B364` | `exclamationmark.triangle` |
| `--ch-error` | `State/Error` | `#C04525` | `#FAA493` | `xmark.circle` |
| `--ch-info` | `State/Info` | `#2B6CB0` | `#8FC1FF` | `info.circle` |

`State/Attention` replaces the ad-hoc `.orange` in three places today: a voice
sample under 30 s, a duplicate enrolled name, and a roster over the four-speaker
cap. Amber `#946000` is AA on light where `.orange` was not.

## Recording

| CSS custom property | Color Set | Light | Dark | On page |
| --- | --- | --- | --- | --- |
| `--ch-recording` | `Recording/Active` | `#9D5F2A` | `#DBA26F` | 4.9 / 8.0 |
| `--ch-recording-quiet` | `Recording/Quiet` | `#FAE7D9` | `#312012` | fill only |

**Recording is copper, not red.** The app icon is a copper ring; recording fills
it. That keeps red meaning one thing — failure — and it gives the state a shape
change, not just a hue change, which is what makes it survive the menu bar's
monochrome template rendering.

Recording state is only ever legible when three things travel together:

1. the **filled ring** (empty ring = idle, filled = capturing),
2. the word **Recording**,
3. the **elapsed timer**, monospaced digits.

Any surface that shows one must show all three. The menu-bar template image is
single-colour by definition, so it carries 1 alone and must be unmistakable at
18 × 18 pt — that constraint is the proof that colour was never doing this job.

## Speaker identity

Eleven colour sets: nine identity colours (`Self` plus eight slots) and two
supporting tokens (`Unresolved`, `OnChip`). Speaker colour fills the **monogram chip and nothing else** —
never transcript text, never a row background. That rule is what keeps a
400-line transcript readable.

| CSS custom property | Color Set | Light | Dark | Slot |
| --- | --- | --- | --- | --- |
| `--ch-speaker-self` | `Speaker/Self` | `#1D395B` | `#85A7D3` | you — pinned, never rotates |
| `--ch-speaker-1` | `Speaker/Slot1` | `#B74441` | `#F78D85` | rose |
| `--ch-speaker-2` | `Speaker/Slot2` | `#0068B0` | `#72B2EF` | blue |
| `--ch-speaker-3` | `Speaker/Slot3` | `#007967` | `#61C6B1` | teal |
| `--ch-speaker-4` | `Speaker/Slot4` | `#844398` | `#CC91DE` | orchid |
| `--ch-speaker-5` | `Speaker/Slot5` | `#007D96` | `#83D6EA` | sky |
| `--ch-speaker-6` | `Speaker/Slot6` | `#46773B` | `#98CF8B` | green |
| `--ch-speaker-7` | `Speaker/Slot7` | `#533D92` | `#9E8AE7` | violet |
| `--ch-speaker-8` | `Speaker/Slot8` | `#655C13` | `#B0A75E` | olive |
| `--ch-speaker-unresolved` | `Speaker/Unresolved` | `#6F7377` | `#7B8085` | before identification runs |
| `--ch-speaker-on-chip` | `Speaker/OnChip` | `#FFFFFF` | `#0E1218` | monogram foreground |

Every row — `Unresolved` included — clears 4.5:1 against `Speaker/OnChip` in its
own appearance, so the monogram is legible in both modes with one colour set per
slot. (Worst case is `Unresolved` at 4.78 light / 4.71 dark; re-verify if any
value changes.)

### Slot assignment

Slot order is **separation priority, not sequence**. Assign in numeric order as
speakers resolve, so the common cases get the best-separated pairs:

| Speakers | Slots used |
| --- | --- |
| 1 (you only) | `Self` |
| 2 | `Self`, `Slot1` |
| 4 | `Self`, `Slot1–3` |
| 8 | `Self`, `Slot1–7` |

Assignment is **stable per meeting** and persists — re-running identification
must not reshuffle colours under a reader. Store the slot index on the speaker,
not the render.

`Self` is navy and never enters rotation: you are not one of the categories.

---

## Type

The macOS app uses **SF via SwiftUI's semantic styles**. No font files ship in
the app bundle, and none should — Apple's licence covers using the system font,
not redistributing it.

| Cheerio role | SwiftUI style | Notes |
| --- | --- | --- |
| Meeting title | `.title2`, `.semibold` | as built |
| Meeting subtitle | `.caption` | secondary |
| Section heading | `.headline` | |
| Enhanced notes body | `.body` | |
| Transcript line | `.callout` | as built; the app's densest reading surface |
| Speaker label | `.caption`, `.semibold`, `.monospacedDigit()` | monospaced digits stop `Speaker 2`/`Speaker 3` shifting the rail |
| Elapsed timer | `.body`, `.monospacedDigit()` | never let the timer reflow |
| Explanatory caption | `.caption` | secondary |

Dynamic Type must stay live throughout; do not pin sizes. The speaker rail is
fixed at 72 pt today — that has to become a flexible min-width or it clips at
larger accessibility sizes.

The **website and wordmark** type is separate and lives in `site/tokens.css`:
Literata for display, IBM Plex Sans for everything working, JetBrains Mono for
code. All three are OFL and committed to `site/fonts/` with their licences.

Only **400 and 600** ship for the sans, and **400** for the serif and the mono.
Nothing on the site may call for another weight: 700 gets synthesised into mush,
and 500 fails quietly — CSS resolves it down to 400, so the page renders lighter
than the spec says and nobody notices. This constraint is the website's alone;
the app has the full SF family and uses SwiftUI's semantic weights.

## Spacing, radii, motion

4 px grid, tokens `--ch-space-1` … `--ch-space-24`. In Swift these map to plain
`CGFloat` constants, not colour sets. Radii 4 / 8 / 12 / 16 / full, with 8 as the
workhorse. Motion 120 / 200 / 360 ms on `cubic-bezier(0.16, 1, 0.3, 1)`; honour
Reduce Motion.
