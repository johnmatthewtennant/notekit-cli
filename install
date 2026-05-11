#!/bin/bash
set -e

REPO="johnmatthewtennant/notekit-cli"
SKILL="apple-notes"
FORMULA="johnmatthewtennant/tap/notekit-cli"

echo "Installing notekit-cli..."

# Install or upgrade via Homebrew
if brew list notekit-cli &>/dev/null; then
  brew upgrade "$FORMULA" 2>/dev/null || echo "  notekit-cli $(brew list --versions notekit-cli | awk '{print $2}') (latest)"
else
  brew install "$FORMULA"
fi

# Install Claude Code skill
echo "Installing Claude Code skill..."
mkdir -p ~/.agents/skills/"$SKILL"
curl -sL "https://raw.githubusercontent.com/$REPO/master/.agents/skills/$SKILL/SKILL.md" \
  -o ~/.agents/skills/"$SKILL"/SKILL.md
mkdir -p ~/.claude/skills
ln -sfn ~/.agents/skills/"$SKILL" ~/.claude/skills/"$SKILL"

echo ""
echo "Done! Use /apple-notes in Claude Code."
