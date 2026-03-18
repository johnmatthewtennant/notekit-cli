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

Primitive commands give you full control. Convenience commands compose multiple primitives for common operations.

```
Primitives:
  notekit folders
  notekit list [--folder <name>] [--limit <n>]
  notekit get (--title <title> | --id <id>) [--folder <name>]
  notekit read (--title <title> | --id <id>) [--folder <name>]
  notekit read-attrs (--title <title> | --id <id>) [--folder <name>]
  notekit create-empty --folder <name>
  notekit delete --id <id>
  notekit append --id <id> --text <text> [--style <n>]
  notekit insert --id <id> --text <text> --position <n> [--style <n>] [--body-offset]
  notekit delete-range --id <id> --start <n> --length <n> [--body-offset]
  notekit set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>] [--body-offset]
  notekit move --id <id> --to <to-folder>
  notekit create-folder --name <name>
  notekit delete-folder --name <name>
  notekit search --query <query> [--folder <name>]
  notekit pin --id <id>
  notekit unpin --id <id>
  notekit get-link --id <id>

Convenience (composed from primitives):
  notekit replace --id <id> --search <text> --replacement <text>
  notekit read-structured (--title <title> | --id <id>) [--folder <name>]
  notekit read-markdown (--title <title> | --id <id>) [--folder <name>]
  notekit write-markdown --id <id> [--dry-run] [--backup]
  notekit duplicate --id <id> [--new-title <new-title>]
  notekit delete-line --id <id> --search-text <search-text>
  notekit add-link --id <id> --target <id> [--text <text>] [--position <n>]
  notekit --help                               # full usage
```

## Private API Notice

Uses Apple's private `NotesShared.framework`. Not endorsed by Apple. May break with macOS updates.
