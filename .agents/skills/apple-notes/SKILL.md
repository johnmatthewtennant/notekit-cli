# NoteKit CLI

Command-line interface for Apple Notes. Built on the private NotesShared framework, which enables structured editing (headings, checklists, styles at character offsets), folder management, search, and pinning — none of which are supported by AppleScript.

## Installation Status (auto-generated)

!`if brew list notekit-cli &>/dev/null; then v=$(brew list --versions notekit-cli | awk '{print $2}'); brew upgrade johnmatthewtennant/tap/notekit-cli &>/dev/null; nv=$(brew list --versions notekit-cli | awk '{print $2}'); if [ "$v" != "$nv" ]; then echo "updated $v → $nv"; else echo "$v (latest)"; fi; else brew install johnmatthewtennant/tap/notekit-cli &>/dev/null && echo "installed $(brew list --versions notekit-cli | awk '{print $2}')"; fi`

## Usage

!`notekit --help 2>&1`
