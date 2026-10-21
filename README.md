# notekit-cli

CLI for Apple Notes via the private NotesShared framework. Full control over styles, checklists, folders, and structure — not available through AppleScript or any public API. JSON output.

## Install

```bash
brew install johnmatthewtennant/tap/notekit-cli
notekit install-skill
```

## Full Disk Access

notekit needs Full Disk Access to read Apple Notes. To open the settings pane:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

Then retry:

```bash
notekit folders
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
  notekit get (--title <title> | --id <id>) [--folder <name>] [--exact]
  notekit read (--title <title> | --id <id>) [--folder <name>]
  notekit read-attrs (--title <title> | --id <id>) [--folder <name>]
  notekit create-empty --folder <name>
  notekit delete --id <id>
  notekit append --id <id> --text <text> [--style <n>]
  notekit insert --id <id> --text <text> --position <n> [--style <n>] [--body-offset]
  notekit delete-range --id <id> --start <n> --length <n> [--body-offset]
  notekit set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>] [--strikethrough true|false] [--color <hex|reset>] [--body-offset]
  notekit move --id <id> --to <to-folder>
  notekit create-folder --name <name>
  notekit delete-folder --name <name>
  notekit search --query <query> [--folder <name>]
  notekit pin --id <id>
  notekit unpin --id <id>
  notekit get-link --id <id>

Convenience (composed from primitives):
  notekit search-offset --id <id> --text <text> [--case-insensitive]
  notekit replace --id <id> --search <text> --replacement <text>
  notekit read-structured (--title <title> | --id <id>) [--folder <name>]
  notekit read-markdown (--title <title> | --id <id>) [--folder <name>]
  notekit write-markdown --id <id> [--dry-run] [--backup]
  notekit create-markdown --folder <name> --title <title>
  notekit duplicate --id <id> [--new-title <new-title>]
  notekit delete-line --id <id> --search-text <search-text>
  notekit add-link --id <id> --target <id> [--text <text>] [--position <n>]
  notekit sync [--dir <dir>] [--folder <name>] [--state <path>] [--dry-run]
  notekit sync-daemon [--dir <dir>] [--folder <name>] [--state <path>] [--interval <seconds>] [--dry-run]
  notekit --help                               # full usage
```

## iCloud saves

After saving an edited note locally, Notekit asks Notes.app to save it through
its own scripting handler by moving it to its current folder. The note stays in
that folder, and its rich text, attachments, pin state, and modification date are
preserved. This schedules the normal asynchronous iCloud upload; a successful
command does not mean another device has already downloaded it.

Notes.app may launch in the background. Allow the launching app to control Notes
if macOS requests Automation permission. If Notes cannot respond or Automation is
denied, the local edit remains saved and Notekit prints a warning to stderr.

## Image attachments

```bash
notekit insert-image --id NOTE_ID --file schedule.png --position 0 --body-offset
notekit insert-image --id NOTE_ID --file photo.jpeg
notekit delete-attachment --id NOTE_ID --attachment ATTACHMENT_ID
```

`insert-image` accepts PNG or JPEG files and returns JSON containing `id`,
`attachmentId`, and `position`. Positions count UTF-16 code units in the full
note, including its title. `--body-offset` makes an explicit position relative to
the body. Omitting `--position` appends to the end. Password-protected notes are
not supported by these attachment commands.

`read-markdown` represents existing media using stable references:

```markdown
![image](notekit-attachment:ATTACHMENT_ID)
```

Keep these references when editing surrounding text. Both replacement writes
and `write-markdown --diff` preserve the referenced native attachments. References
must belong to the destination note and may occur only once. They reference
Notes' media rather than exporting files or importing arbitrary image URLs;
copying the Markdown into a different note does not copy the media.
Use `delete-attachment` to remove an attachment and its text marker explicitly.

## Note-to-note links

`read-markdown` outputs note-to-note links as standard markdown links with `applenotes://` URLs:

```
[Display Text](applenotes://showNote?identifier=NOTE_ID)
```

`write-markdown` recognizes this syntax and converts them back to native Apple Notes inline link attachments. To get a note's ID for linking:

```bash
notekit get --title "Target Note" --exact | jq -r .id
```

## Two-way sync

`sync` reconciles markdown files with an Apple Notes folder once, and `sync-daemon` runs the same pass repeatedly. Defaults are set for agent notes:

```bash
notekit sync --dir ~/Development/agent-documents/agent-notes --folder agent-notes
notekit sync-daemon --dir ~/Development/agent-documents/agent-notes --folder agent-notes --interval 5
```

Files are markdown with YAML frontmatter and a `.notekit-sync.json` state file in the sync directory. Deletions are non-destructive by default: if one side is missing, the remaining side is preserved on the next pass. If both sides changed since the last sync, the Apple Notes version wins and notekit writes the local disk version to a `.local-conflict-<timestamp>.md` file.

## Inline color

`read-markdown` emits character color as HTML spans:

```markdown
<span style="color:#a371f7">colored text</span>
```

`write-markdown` accepts the same syntax, and `set-attr --color "#a371f7"` applies color directly. Use `set-attr --color reset` to remove color.

## Private API Notice

Uses Apple's private `NotesShared.framework`. Not endorsed by Apple. May break with macOS updates.

## Regression tests

On a Mac with access to Notes, build and run:

```bash
make notekit note-state
./notekit test
python3 tests/issues.py images
python3 tests/issues.py cloud
```

The issue regressions create uniquely named disposable notes and folders and
clean them up afterward. They verify image bytes, native Notes HTML, Markdown
preservation, input validation, and iCloud's recorded acknowledgement of local
versions. Both issue suites require a working iCloud account and Notes Automation
permission. Run them sequentially, separately from the existing suite's folder
cleanup. The `note-state` helper reads test-note state without modifying it.
