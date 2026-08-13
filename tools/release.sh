#!/usr/bin/env bash
#
# Publish a release: build, sign, zip, and push it to GitHub with the catalog file.
#
#     $ ./tools/release.sh 1.0.0
#
# The zip is what `puddle:install` downloads, and index.json is what Puddle's Browse screen
# reads. Both are release assets under `latest`, so the install line in the readme never has a
# version in it.
#
# Signing is Developer ID rather than ad hoc because this bundle now arrives over the network.
# Puddle disables library validation to load it either way, but a signature that names someone
# is the difference between "a plugin I published" and "a plugin".

set -euo pipefail

VERSION="${1:-}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
REPOSITORY="gapul/puddle-chess"
PRODUCTS="build/Build/Products/Release"

if [[ -z $VERSION ]]; then
	echo "usage: $0 <version>" >&2
	exit 1
fi

cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project PuddleChess.xcodeproj -scheme PuddleChess -configuration Release -derivedDataPath build build

codesign --force --sign "$IDENTITY" --timestamp --options runtime "$PRODUCTS/PuddleChess.bundle"
codesign --verify --strict "$PRODUCTS/PuddleChess.bundle"

rm -rf dist
mkdir -p dist

# `--keepParent` so the archive holds `PuddleChess.bundle` rather than its contents loose;
# `ditto` because it is what preserves a bundle's symlinks and its signature.
ditto -c -k --sequesterRsrc --keepParent "$PRODUCTS/PuddleChess.bundle" dist/puddle-chess.zip

cat > dist/index.json <<JSON
{
  "version": 1,
  "name": "$REPOSITORY",
  "wallpapers": [
    {
      "id": "puddle-chess",
      "name": "Chess",
      "description": "A playable 3D chess set. Click a piece and its legal squares light up, or let Stockfish play both sides.",
      "author": "gapul",
      "kind": "plugin",
      "url": "https://github.com/$REPOSITORY/releases/latest/download/puddle-chess.zip",
      "preview": "https://github.com/$REPOSITORY/releases/latest/download/preview.jpg"
    }
  ]
}
JSON

gh release create "v$VERSION" \
	--repo "$REPOSITORY" \
	--title "v$VERSION" \
	--notes "A playable 3D chess set as a Puddle wallpaper.

Install (needs \`https://github.com/$REPOSITORY/releases/\` in \`~/.config/puddle/install.toml\`):

    open -g 'puddle:install?url=https://github.com/$REPOSITORY/releases/latest/download/puddle-chess.zip'" \
	dist/puddle-chess.zip dist/index.json docs/preview.jpg

echo "released v$VERSION"
