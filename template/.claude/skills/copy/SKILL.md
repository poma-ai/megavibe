---
name: copy
description: Copy content to clipboard in a format suited to the target (Slack, Markdown, plain text). Use when the user says "clip", "copy that", "clipboard", or "/copy".
allowed-tools: Bash, AskUserQuestion
user-invocable: true
---

# Copy to Clipboard

Copies the most recent output (or specified content) to the clipboard in the right format for the user's target.

## Steps

1. **Ask the user** (unless they already specified): "Where is this going? (slack / md / plain)"

2. **Format based on target:**

   **`slack`** — Slack uses `mrkdwn`, NOT Markdown. Convert:
   - `*bold*` (not `**bold**`)
   - `_italic_` (not `*italic*`)
   - `~strikethrough~` (not `~~strikethrough~~`)
   - `*HEADING*` on its own line (no `#` headings)
   - No markdown tables — use code-block ASCII tables (triple backtick) or bullet lists
   - `<url|text>` links (not `[text](url)`)
   - Code: single backtick for inline, triple backtick for blocks (same as markdown)

   **`md`** — Clean GitHub-Flavored Markdown:
   - Tables, headings, links all standard GFM
   - No hard wraps, no gutter artifacts, no line-number prefixes

   **`plain`** — No formatting at all:
   - Strip all markup
   - Use indentation and whitespace for structure

3. **Copy to clipboard** using the platform tool:
   - macOS: `pbcopy`
   - Linux: `xclip -selection clipboard` or `xsel --clipboard`
   - Windows/WSL: `clip.exe`

4. **Confirm** with a one-line message: "Copied (slack/md/plain) — N lines"

## Notes

- If the user says just "copy that" or "clip" without a target, always ask.
- If they say "copy for slack" or "slack copy", skip the question — target is `slack`.
- If they say "copy" with no prior output to copy, ask what they want copied.
