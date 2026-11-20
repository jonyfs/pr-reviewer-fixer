---
# gstack: design-md-format=spec
name: pr-reviewer-fixer
description: A typeset review record on graphite. The verdict is the hero object; a person still decides.
colors:
  background: "#15171a"
  surface: "#1c1f23"
  text: "#e9e7e2"
  text-muted: "#9b9fa7"
  line: "#2c3036"
  accent: "#7fc4d1"
  accent-ink: "#15171a"
  note: "#7fc4d1"
  critical: "#ff7a66"
  warning: "#e9b553"
  passed: "#6fc795"
  paper: "#f3f4f1"
  paper-text: "#16181b"
  paper-muted: "#596069"
  paper-line: "#d9dcd6"
  paper-accent: "#1d6b7a"
  paper-accent-ink: "#ffffff"
  paper-surface: "#ffffff"
  paper-critical: "#b3261e"
  paper-warning: "#8f5c00"
  paper-passed: "#1d7a40"
  paper-note: "#1d6b7a"
typography:
  display:
    fontFamily: Satoshi
    fontWeight: 700
    fontSize: clamp(36px, 5.4vw, 64px)
    letterSpacing: -0.02em
  body:
    fontFamily: Instrument Sans
    fontSize: 1rem
    lineHeight: 1.6
  ui:
    fontFamily: Instrument Sans
    fontWeight: 500
    fontSize: 0.9375rem
  mono:
    fontFamily: JetBrains Mono
    fontSize: 0.875rem
rounded:
  sm: 4px
  md: 6px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 40px
components:
  verdict-slip:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
  install-command:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.accent}"
    rounded: "{rounded.sm}"
  rule:
    backgroundColor: "{colors.line}"
---

# pr-reviewer-fixer

## Overview

**Creative North Star:** A reviewed pull request states its verdict in plain text, bound to a commit, and a person still decides. The page looks like the review record itself, not a product screenshot.
**Product context:** Three open Agent Skills for developers who use AI coding agents on GitHub pull requests: pr-reviewer, pr-fixer, pr-merge-fixer. The skills never merge, approve or release.
**Mode per surface:** Persuade (first viewport), Read (the rest of the page and the docs).
**Reference sites:** Mintlify and Storybook DESIGN.md files (semantic tokens); GitHub Page Generator (official, for project pages).
**Key characteristics:**
- Graphite ground, flat rules, no glow, no gradient, no ornament.
- The verdict is shown as mono text, labelled as an illustrative format.
- The install command is the primary action.
- Three status colors, used only for severity.

## Colors

**Strategy:** Restrained. One accent, neutrals, and severity colors used only where a verdict or a severity appears.
**Light or dark:** Dark by default, because readers arrive from GitHub and terminals, both usually dark. Light is served when the system asks for it, through the `paper-*` tokens, on a cool paper ground (not cream); the paper surface is white.

Light mode uses the paper tokens (`paper-*`): the ground is cool paper (`#f3f4f1`), surfaces are white (`#ffffff`), and severity uses the `paper-critical`, `paper-warning`, `paper-passed` and `paper-note` values, which pass contrast on paper. The dark critical `#ff7a66` measures 2.31:1 on paper, so it is never used on the light ground.

Neutrals derive from the graphite ground. The accent marks links, focus rings and the install prompt only. Dark-mode surfaces separate by a one-step lightness change and a 1px line, not by shadow.

## Typography

**Display:** Satoshi 700, loaded from the Fontshare API (`https://api.fontshare.com/v2/css?f%5B%5D=satoshi@700&display=swap`). Source: Fontshare. License: ITF Free Font License v2.0 (17 Aug 2026), read from the official package. Section 01 allows the API for the licensee's own website, and section 02 forbids serving the font to third parties. The font files are not kept in this repository, so nothing is redistributed from it.
**Body and UI:** Instrument Sans, 400 to 700 (Google Fonts, SIL Open Font License). Verified weight range 400 to 700.
**Mono:** JetBrains Mono 400 and 500 (Google Fonts). Mono marks text the tool writes: the install command, the verdict slip, markers and label names, and inline code.

Rejected: Clash Grotesk (license not verified), Geist (display is on the overused list; used here nowhere).

## Layout

Desktop, 12 columns, max width 1120px. Header: wordmark on the left, three plain text links on the right, no buttons. First viewport: the headline and lead on seven columns; the verdict slip on five. Below: the skills as a ledger of rows, the pull request path as a numbered list, severity as a table, then the checked claims.

Phone under 600px: the slip moves below the install command; gutter 16px; no horizontal page scroll; code blocks scroll inside themselves.

## Elevation & Depth

No shadows. Depth is a 1px line and a one-step surface tint. No zero-offset colored glow.

## Shapes

Radius 4px for the slip and the command block, 6px maximum anywhere. No pill shapes; no uniform large radius.

## Components

- **Install command:** full-width mono block on the surface tint, with a copy control that is keyboard reachable. Hover and focus-visible show the accent outline.
- **Verdict slip:** a ruled block with mono lines (verdict, commit, counts, blocks, merge). It carries the label "illustrative format" in small muted text.
- **Severity rows:** a 4px left bar in the severity color, label in mono, meaning in text.
- **Links:** accent color, underline on hover and focus.

## Do's and Don'ts

- Do: state every claim with a place to check it.
- Do: use mono only for text the tool writes.
- Do: keep the four severity colors (critical, warning, passed, note) on the severity legend and the verdict slip only.
- Don't: use a three-column icon grid, cards for everything, or centered headings.
- Don't: use a kicker or eyebrow label above a heading.
- Don't: put a gradient on a button or behind the hero.

## Motion

- **Approach:** minimal-functional.
- **Easing:** enter(ease-out) exit(ease-out) move(ease-in-out)
- **Duration:** micro(50-100ms) short(150-250ms) medium(250-400ms) long(400-700ms)
- **The one authored moment:** none. Motion only confirms state (copy success, focus).

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-11-20 | Initial design system created | Created by /design-consultation from the approved proposal ("verdict ledger") and independent research |
| 2026-11-20 | Satoshi loaded from the Fontshare API, not kept in the repository | Section 01 allows the API for the licensee's website; keeping the file in a public repository is a redistribution question the file itself avoids |
| 2026-11-20 | Clash Grotesk dropped | License not verified; the skill omits unverified faces |
| 2026-11-20 | "Open Agent Skills" label to be removed | The label names a category, not the tool; the wordmark takes its place |
| 2026-11-20 | Flow strip in the first viewport; share image and favicon; Copy button confirms on itself; JSON-LD names the author and a free offer | The first view should show the loop at a glance; links shared outside GitHub need an image; the button should confirm the copy where the eye is |
