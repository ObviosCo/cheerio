---
applyTo: "Cheerio/Views/**"
---

This diff touches a SwiftUI view — something the user sees. Before approving:

- Does `site/` (the marketing site's screenshots or FAQ copy) need updating to match this
  change?
- Does the first-run walkthrough (#30) need to teach this change to new users?
- If neither applies, say so briefly rather than skipping the question — a silent PR that
  changes the UI without updating either is the failure mode this file exists to catch.
