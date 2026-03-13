# notekit-cli

A command-line interface for Apple Notes, built on the private NotesShared framework.

Read and edit notes with full control over styles, checklists, folders, and structure — capabilities not available through AppleScript or any public API.

## Requirements

- macOS (tested on macOS 15+)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
brew install johnmatthewtennant/tap/notekit-cli
```

### Build from source

```bash
git clone https://github.com/johnmatthewtennant/notekit-cli.git
cd notekit-cli
make
```

## Usage

```
notekit help
```

### Primitives

```
notekit folders
notekit list [--folder <name>] [--limit <n>]
notekit get <title> [--folder <name>]
notekit read <title> [--folder <name>]
notekit read-attrs <title> [--folder <name>]
notekit create-empty --folder <name>
notekit delete <title> [--folder <name>]
notekit append <title> <text> [--folder <name>]
notekit insert <title> <text> --position <n> [--folder <name>]
notekit delete-range <title> --start <n> --length <n> [--folder <name>]
notekit set-attr <title> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--folder <name>]
notekit move <title> --folder <from> --to <to-folder>
notekit create-folder <name>
notekit delete-folder <name>
notekit search <query> [--folder <name>]
notekit pin <title> [--folder <name>]
notekit unpin <title> [--folder <name>]
```

### Convenience commands

```
notekit replace <title> --search <text> --replacement <text> [--folder <name>]
notekit read-structured <title> [--folder <name>]
notekit duplicate <title> [--folder <name>] [--title <new-title>]
notekit delete-line <title> <search-text> [--folder <name>]
```

### Data model

A note is a flat string with attribute ranges at character offsets. Each range has a style (0=title, 1=heading, 3=body, 103=checklist), indent level, and optional properties (todo-done, link, strikethrough). Use `read-attrs` to see the raw attribute stream.

Primitives give you full control — you can do anything with `read-attrs`, `set-attr`, `insert`, and `delete-range`.

## Claude Code Skill

Install the skill so Claude Code can use notekit automatically:

```bash
mkdir -p ~/.agents/skills/apple-notes && curl -sL https://raw.githubusercontent.com/johnmatthewtennant/notekit-cli/master/.agents/skills/apple-notes/SKILL.md -o ~/.agents/skills/apple-notes/SKILL.md && ln -sfn ~/.agents/skills/apple-notes ~/.claude/skills/apple-notes
```

## Private API Notice

This tool uses Apple's private `NotesShared.framework`. It is not endorsed by Apple and may break with any macOS update. Use at your own risk.
