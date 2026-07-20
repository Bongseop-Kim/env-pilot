#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

publish=false
if [[ "${1:-}" == "--publish" ]]; then
    publish=true
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--publish]" >&2
    exit 2
fi

if [[ ! -f RELEASE_NOTES.md ]]; then
    echo "RELEASE_NOTES.md가 없습니다." >&2
    exit 1
fi

if $publish; then
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        echo "커밋되지 않은 변경사항이 있습니다." >&2
        exit 1
    fi
    gh auth status >/dev/null
fi

derived_data="$(mktemp -d "${TMPDIR:-/tmp}/env-pilot-release.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT

xcodebuild \
    -resolvePackageDependencies \
    -project env-pilot.xcodeproj \
    -scheme env-pilot \
    -derivedDataPath "$derived_data"

xcodebuild \
    -project env-pilot.xcodeproj \
    -scheme env-pilot \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

app="$derived_data/Build/Products/Release/env-pilot.app"
info="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
tag="v$version"
release_dir="$repo_root/build/release/$tag"

if [[ -e "$release_dir" ]]; then
    echo "$release_dir가 이미 있습니다. 기존 결과를 옮기거나 삭제한 뒤 다시 실행하세요." >&2
    exit 1
fi
mkdir -p "$release_dir"

sparkle="$app/Contents/Frameworks/Sparkle.framework"
sparkle_b="$sparkle/Versions/B"

codesign -f -s - -o runtime "$sparkle_b/XPCServices/Installer.xpc"
codesign -f -s - -o runtime --preserve-metadata=entitlements "$sparkle_b/XPCServices/Downloader.xpc"
codesign -f -s - -o runtime "$sparkle_b/Autoupdate"
codesign -f -s - -o runtime "$sparkle_b/Updater.app"
codesign -f -s - -o runtime "$sparkle"
codesign -f -s - -o runtime --entitlements env-pilot/env-pilot.entitlements "$app"
codesign --verify --deep --strict "$app"

archive="$release_dir/Env-Pilot-$version.zip"
notes="$release_dir/Env-Pilot-$version.md"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
cp RELEASE_NOTES.md "$notes"

sparkle_tools="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" \
    --account com.bongsub.env-pilot \
    --download-url-prefix "https://github.com/Bongseop-Kim/env-pilot/releases/download/$tag/" \
    --embed-release-notes \
    --link "https://github.com/Bongseop-Kim/env-pilot" \
    "$release_dir"

xmllint --noout "$release_dir/appcast.xml"

if $publish; then
    tag_commit="$(git rev-list -n 1 "$tag" 2>/dev/null || true)"
    if [[ "$tag_commit" != "$(git rev-parse HEAD)" ]]; then
        echo "$tag 태그가 현재 커밋을 가리켜야 합니다." >&2
        exit 1
    fi
    gh release create "$tag" \
        "$archive" \
        "$release_dir/appcast.xml" \
        --verify-tag \
        --title "Env Pilot $version" \
        --notes-file RELEASE_NOTES.md
fi

echo "Release 준비 완료: $release_dir"
