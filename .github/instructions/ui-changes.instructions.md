---
applyTo: "Cheerio/Views/**"
---

This diff touches a SwiftUI view — something the user sees. Before approving:

- Does the site's *copy* (`site/*.html`) now claim something this diff makes false? Flag
  that. Do NOT ask for `site/img` screenshot regeneration — site images document the
  released build and are regenerated once per release by the release checklist; the CI
  capture preview on this PR is the review-time visual evidence.
- Does the first-run walkthrough (#30) need to teach this change to new users?
- If neither applies, say so briefly rather than skipping the question — a silent PR that
  changes the UI without updating either is the failure mode this file exists to catch.
