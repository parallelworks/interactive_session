#!/usr/bin/env bash
# Install the `activate-workflows` Claude Code skill for this approach.
#
#   bash install.sh
#
# Copies this approach's SKILL.md + the shared references/ into
# ~/.claude/skills/activate-workflows/ where Claude Code (CLI and the VS Code
# extension — both read ~/.claude) auto-discovers it. Re-run any time to update.
set -euo pipefail

# Resolve paths relative to this script, so it works from any cwd.
APPROACH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_REFS="$(cd "${APPROACH_DIR}/.." && pwd)/references/activate-platform.md"
DST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/activate-workflows"

if [[ ! -f "${APPROACH_DIR}/SKILL.md" ]]; then
  echo "ERROR: SKILL.md not found next to install.sh (${APPROACH_DIR})" >&2
  exit 1
fi
if [[ ! -f "${SHARED_REFS}" ]]; then
  echo "ERROR: shared reference not found at ${SHARED_REFS}" >&2
  exit 1
fi

mkdir -p "${DST}/references"
cp "${APPROACH_DIR}/SKILL.md" "${DST}/SKILL.md"
cp "${SHARED_REFS}"           "${DST}/references/activate-platform.md"

echo "Installed activate-workflows skill to: ${DST}"
echo "  - SKILL.md"
echo "  - references/activate-platform.md"
echo
echo "The skill points at the interactive_session repo's own workflows and tutorials"
echo "(workflow/yamls/, workflow/tutorials/) for working examples — keep that repo"
echo "available on the node."
echo
echo 'In Claude Code: "Using the activate-workflows skill, build a workflow that ..."'
