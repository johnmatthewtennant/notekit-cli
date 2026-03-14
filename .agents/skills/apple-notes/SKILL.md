# NoteKit CLI

Command-line interface for Apple Notes. Built on the private NotesShared framework, which enables structured editing (headings, checklists, styles at character offsets), folder management, search, and pinning — none of which are supported by AppleScript.

## Auto-install and self-update

!`brew list notekit-cli &>/dev/null || brew install johnmatthewtennant/tap/notekit-cli &>/dev/null; brew upgrade johnmatthewtennant/tap/notekit-cli &>/dev/null; brew list --versions notekit-cli; for d in ~/.agents/skills/apple-notes ~/.claude/skills/apple-notes; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/notekit-cli/master/.agents/skills/apple-notes/SKILL.md" -o "$d/SKILL.md"; done`

## Usage

!`notekit --help 2>&1`
