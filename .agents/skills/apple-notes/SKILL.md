# NoteKit CLI

Command-line interface for Apple Notes. Built on the private NotesShared framework, which enables structured editing (headings, checklists, lists, styles at character offsets), folder management, search, and pinning — none of which are supported by AppleScript.

## Prerequisite check (auto-generated)

!`osascript -e 'tell application "Notes" to get name of every folder' &>/dev/null || echo "**STOP**: Notes access required. Run: osascript -e 'tell application \"Notes\" to get name of every folder' and grant permission when prompted. See SETUP.md."`

!`brew list notekit-cli &>/dev/null || brew install johnmatthewtennant/tap/notekit-cli &>/dev/null; brew upgrade johnmatthewtennant/tap/notekit-cli &>/dev/null; brew list --versions notekit-cli || echo "**STOP**: notekit-cli is not installed. See SETUP.md."; for d in ~/.agents/skills/apple-notes ~/.claude/skills/apple-notes; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/notekit-cli/master/.agents/skills/apple-notes/SKILL.md" -o "$d/SKILL.md"; done`

## Basic usage

- `notekit list` — list all notes
- `notekit read --title "Title"` — read a note's content
- `notekit create-empty --folder "Folder"` — create a new note
- `notekit append --id <id> --text "text"` — append text to a note
- `notekit append --id <id> --text "item" --style 100` — append a dash list item
- `notekit append --id <id> --text "item" --style 102` — append a numbered list item
- `notekit append --id <id> --text "item" --style 103` — append a checklist item
- `notekit search --query "query"` — search notes
- `notekit search-offset --id <id> --text "text" [--case-insensitive]` — find text offset in note

## Styles

Valid style values for `--style`:
- `0` — title
- `1` — heading
- `3` — body (default)
- `100` — dash list (unordered/bullet)
- `102` — numbered list (ordered)
- `103` — checklist

## `notekit --help` (auto-executed)

!`notekit --help 2>&1`
