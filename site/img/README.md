# site/img

Nine images. Eight of them are screenshots, and none of them are taken by hand.

## The screenshots

`library`, `library-transcript`, `onboarding-voice` and `settings-callback` — each
as a 1× and a 2× — are produced by the harness in
[`Scripts/screenshots`](../../Scripts/screenshots/README.md):

```sh
./Scripts/screenshots/capture.sh
./Scripts/screenshots/publish.sh
```

`capture.sh` seeds a store of invented meetings, launches the app against a scratch
container, and captures the windows at Retina scale. `publish.sh` copies the four
the page references into this directory, quantized to a 256-colour palette on the
way — visually lossless on flat UI screenshots, and about a quarter of the size.

**Regenerate them when the UI in them changes**, which is cheaper than deciding
whether the change is visible. If you add a figure to `index.html`, add its capture
name to the `PUBLISHED` list in `publish.sh` so the next run keeps it up to date.

Nothing in these comes from a real meeting. The demo data is invented in
`Scripts/screenshots/SeedDemoStore` and that's the only place it should ever come
from — these are published on the open web.

**If the alt text no longer matches what's in the shot, fix the alt text.** It's in
`index.html` and it describes the picture, not the feature.

### Sizes and shapes

- `library` and `library-transcript` are 1440 × 900, which is what
  `-screenshotWindowSize` asks for. The `.shot` frame is 16:10 and crops to fill, so
  that ratio is the one to keep.
- `onboarding-voice` (560 × 632) and `settings-callback` (480 × 450) are the app's
  own fixed window sizes. They're shown in `.shot--panel`, which doesn't crop.
- Light appearance only. There's no dark variant wired up; if you want one, it's a
  `<picture>` element rather than a redesign.

## `social-card.png` — the GitHub repository card

1280 × 640, generated rather than shot:

```sh
swift Scripts/render-wordmark.swift
```

That writes `docs/social-card.png`. Copy it here if the site needs it too, or leave
it in `docs/` and point the `og:image` at the GitHub-hosted copy.
