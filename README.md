# notekit-cli

A command-line interface for Apple Notes, built on the private NotesShared framework.

Read and write notes as Markdown, with support for headings, checklists, and folder filtering.

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

This produces a `notekit` binary in the current directory. Move it to your PATH if desired.

## Usage

```
notekit read <title> [--folder <folder>]
notekit write <title> [--folder <folder>]    # reads markdown from stdin
notekit list [--folder <folder>]
notekit test
```

### Examples

List all notes:
```bash
notekit list
```

Read a note as Markdown:
```bash
notekit read "My Note"
```

Update a note from Markdown:
```bash
echo "# My Note\nNew content" | notekit write "My Note"
```

## Private API Notice

This tool uses Apple's private `NotesShared.framework`. It is not endorsed by Apple and may break with any macOS update. Use at your own risk.
