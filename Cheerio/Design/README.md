# Cheerio app theme

The Swift side of the design system. The website's source of truth is
`site/tokens.css`; the crossing-over table is `docs/token-map.md`. This folder
is that table, made real.

```
Cheerio/
  Design/
    Theme.swift                    space · radius · motion · layout constants
    ThemeColors.swift              every colour the app may use
    ThemeTypography.swift          type roles → SwiftUI semantic styles
    SpeakerIdentity.swift          slots, provenance, monograms
    Components/
      SpeakerChip.swift            the chip and the rail label
      RecordingIndicator.swift     the three-signal rule, enforced
      StatusLabel.swift            semantic state + symbol + label
  Resources/
    Assets.xcassets/               36 Color Sets, light + dark
```

## Adding it to the target

Nothing to configure. `project.yml` builds the app target from `sources: path:
Cheerio`, so `Cheerio/Design/**` is compiled the moment it exists — run
`xcodegen generate` and it's in.

The colour sets merge into the **existing** `Cheerio/Resources/Assets.xcassets`
alongside `AppIcon.appiconset`; don't add a second catalog. The eight folders
carry **Provides Namespace**, so catalog names are paths —
`Color("Speaker/Slot1")`. A colour resolving to flat magenta at runtime means
the folder didn't land inside the catalog.

## The four rules worth restating

**Colour is never the only signal.** Speaker identity is carried by the
monogram letters; state is carried by an SF Symbol and a word. Both survive
greyscale, exported Markdown and VoiceOver with the hue removed. That is the
test — if a state stops being legible in greyscale, it isn't finished.

**Speaker colour fills the chip and nothing else.** Never transcript text,
never a row background. This one rule is what keeps a 400-line transcript
readable.

**Certainty is unmarked.** Only `.modelMatched` gets the hairline ring. Correct
a label and the ring goes away — that disappearance is the receipt that your
corrections outrank the model's guesses.

**Recording is copper, and the ring's fill is the real signal.** Red keeps
meaning failure. The menu-bar template image is single-colour by definition, so
empty-ring-versus-filled-ring has to carry the state on its own at 18 pt.

## What this deliberately doesn't do

No font files, no `Font.custom`. The app is SF through SwiftUI's semantic
styles, so Dynamic Type keeps working; Literata and IBM Plex are the website's
alone. No `colorScheme` branching either — the catalog resolves appearance, and
code that asks which mode it's in will eventually get it wrong.

## Still open

The inversion needs a way to confirm a whole speaker at once from the speakers
panel, or every model-assigned name stays ringed forever and the mark stops
meaning anything. That's an IA change, flagged in phase 2 and tracked as
[#77](https://github.com/ObviosCo/cheerio/issues/77) — still unbuilt.

`SpeakerSlotAssigner` persistence (storing slots with the meeting, not the
view) is no longer on this list — it shipped in the same migration that
brought this vocabulary into the app.
