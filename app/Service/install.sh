#!/bin/bash
# Builds the Mac's file service (plan phase 1) and puts it at
# ~/Library/Application Support/PrepareMe/tools/prepareme-service: the probe's service, started by hand in Terminal.
# The library's service is PrepareMe.app's own since plan phase 6 (kiwix-mac/build.sh --app-mac builds it), and the
# scheduler's `service` job that once ran this copy was removed 2026-10-15. Like every live install, it runs only from
# the PrepareMe folder itself on branch main with app/Service committed (phase 4 whole-branch review).
#
# It is signed with the owner's Apple Development identity when Xcode has made one (Xcode › Settings › Accounts), so
# the Mac's firewall asks about it once and keeps the answer through rebuilds; without one it is signed ad hoc, and
# the firewall asks again after every rebuild (the verifier's finding, 2026-10-12: the firewall knows a program by its
# signature). Run it again only when app/Service changes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
git_dir=$(git -C "$REPO" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
common_dir=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
branch=$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || true)
if [ -z "$git_dir" ] || [ "$git_dir" != "$common_dir" ] || [ "$branch" != main ]; then
    echo "Not installed: run this from the PrepareMe folder itself (the main checkout, not a worktree), on branch main." >&2
    exit 1
fi
if [ -n "$(git -C "$REPO" status --porcelain -- app/Service)" ]; then
    echo "Not installed: app/Service has changes that aren't committed; commit them first." >&2
    exit 1
fi
TOOLS="$HOME/Library/Application Support/PrepareMe/tools"
DEST="$TOOLS/prepareme-service"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release --package-path "$HERE" >/dev/null
built="$(swift build -c release --package-path "$HERE" --show-bin-path)/prepareme-service"
mkdir -p "$TOOLS"
cp "$built" "$DEST.new"
ID=com.bigmike382.prepareme.service  # a fixed name in the signature, so the firewall knows it across rebuilds
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" \
        && codesign --force --identifier "$ID" --sign "Apple Development" "$DEST.new" 2>/dev/null; then
    how="signed with your Apple Development identity"
else
    codesign --force --identifier "$ID" --sign - "$DEST.new" 2>/dev/null
    how="signed ad hoc (no Apple Development identity could sign it), so the firewall will ask again after a rebuild"
fi
mv -f "$DEST.new" "$DEST"
echo "prepareme-service is in Application Support › PrepareMe › tools, $how."
