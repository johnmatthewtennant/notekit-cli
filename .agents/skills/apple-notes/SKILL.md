# NoteKit CLI

Command-line interface for Apple Notes. Built on the private NotesShared framework, which enables structured editing (headings, checklists, lists, styles at character offsets), folder management, search, and pinning — none of which are supported by AppleScript.

## Prerequisite check (auto-generated)

!`osascript -e 'tell application "Notes" to get name of every folder' &>/dev/null || echo "**STOP**: Notes access required. Run: osascript -e 'tell application \"Notes\" to get name of every folder' and grant permission when prompted. See SETUP.md."`

!`brew list notekit-cli &>/dev/null || brew install johnmatthewtennant/tap/notekit-cli &>/dev/null; brew upgrade johnmatthewtennant/tap/notekit-cli &>/dev/null; brew list --versions notekit-cli || echo "**STOP**: notekit-cli is not installed. See SETUP.md."; for d in ~/.agents/skills/apple-notes ~/.claude/skills/apple-notes; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/notekit-cli/master/.agents/skills/apple-notes/SKILL.md" -o "$d/SKILL.md"; done`

## Reading and writing notes

Use `read-markdown` / `write-markdown` for all note operations. `write-markdown` does paragraph-level LCS diffing internally — only mutated paragraphs are changed. Markdown covers headings, bold, italic, strikethrough, links, code, lists, checklists, and note-to-note links.

- `notekit read-markdown --title "Title"` — read a note as markdown
- `notekit read-markdown --id <id>` — read a note as markdown by ID
- `notekit write-markdown --id <id> < file.md` — update note from markdown (pipe or stdin)
- `notekit create --folder "Folder" --title "Title" --body "text"` — create a note with content
- `notekit list` — list all notes
- `notekit search --query "query"` — search notes

## `notekit --help` (auto-executed)

!`notekit --help 2>&1`
