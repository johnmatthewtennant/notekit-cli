# notekit-cli

CLI for Apple Notes via the private NotesShared framework. Full control over styles, checklists, folders, and structure — not available through AppleScript or any public API. JSON output.

## Install

```bash
brew install --with-skill johnmatthewtennant/tap/notekit-cli
```

## Claude Code

```
/apple-notes
```

## CLI

```
notekit folders
notekit list [--folder <name>]
notekit get <title> [--folder <name>]
notekit read <title> [--folder <name>]
notekit read-attrs <title> [--folder <name>]
notekit append <title> <text> [--folder <name>]
notekit insert <title> <text> --position <n> [--folder <name>]
notekit delete-range <title> --start <n> --length <n> [--folder <name>]
notekit set-attr <title> --offset <n> --length <n> [--style <n>] [--indent <n>]
notekit search <query> [--folder <name>]
notekit help                               # full usage
```

## Private API Notice

Uses Apple's private `NotesShared.framework`. Not endorsed by Apple. May break with macOS updates.
