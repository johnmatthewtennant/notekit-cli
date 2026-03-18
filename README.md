# notekit-cli

CLI for Apple Notes via the private NotesShared framework. Full control over styles, checklists, folders, and structure — not available through AppleScript or any public API. JSON output.

## Install

```bash
brew install johnmatthewtennant/tap/notekit-cli
notekit install-skill
```

## Claude Code

```
/apple-notes
```

## CLI

```
notekit folders
notekit list [--folder <name>]
notekit get (<title> | --title <title>) [--folder <name>]
notekit read (<title> | --title <title>) [--folder <name>]
notekit read-attrs (<title> | --title <title>) [--folder <name>]
notekit append (<title> | --title <title>) (<text> | --text <text>) [--folder <name>]
notekit insert (<title> | --title <title>) (<text> | --text <text>) --position <n> [--folder <name>]
notekit delete-range (<title> | --title <title>) --start <n> --length <n> [--folder <name>]
notekit set-attr (<title> | --title <title>) --offset <n> --length <n> [--style <n>] [--indent <n>] [--link <url>]
notekit search (<query> | --query <query>) [--folder <name>]
notekit help                               # full usage
```

## Private API Notice

Uses Apple's private `NotesShared.framework`. Not endorsed by Apple. May break with macOS updates.
