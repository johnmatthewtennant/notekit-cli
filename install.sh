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

# Install agent skill
echo "Installing skill..."
AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
mkdir -p "$AGENTS_SKILLS/$SKILL"
curl -sL "https://raw.githubusercontent.com/$REPO/master/.agents/skills/$SKILL/SKILL.md" \
  -o "$AGENTS_SKILLS/$SKILL/SKILL.md"
mkdir -p "$CLAUDE_SKILLS"
if [[ "$(cd -P "$AGENTS_SKILLS" && pwd)" != "$(cd -P "$CLAUDE_SKILLS" && pwd)" ]]; then
  ln -sfn "$AGENTS_SKILLS/$SKILL" "$CLAUDE_SKILLS/$SKILL"
fi

echo ""
echo "Done! Use /apple-notes in Claude Code."
