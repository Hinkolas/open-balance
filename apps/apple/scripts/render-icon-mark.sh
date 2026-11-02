#!/bin/sh
# Renders AppIcon.icon into the AppIconMark image the app shows in its own UI
# (e.g. the Welcome screen). Run again after changing the icon in Icon Composer.
set -eu
cd "$(dirname "$0")/../OpenBalance"
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
out=Assets.xcassets/AppIconMark.imageset
mkdir -p "$out"
"$ictool" AppIcon.icon --export-image --output-file "$out/AppIconMark.png" \
  --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
cat > "$out/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "AppIconMark.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "Rendered $out/AppIconMark.png"
