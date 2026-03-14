# Apple Notes Setup

1. Install the CLI:
```bash
brew install johnmatthewtennant/tap/notekit-cli
```

2. Grant Notes access (triggers macOS permission prompt):
```bash
osascript -e 'tell application "Notes" to get name of every folder'
```

3. Verify: `notekit list` should return note titles.
