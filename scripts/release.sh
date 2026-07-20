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

notary_profile="${NOTARY_PROFILE:-env-pilot}"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "키체인에 Developer ID Application 인증서가 없습니다." >&2
    echo "Xcode → Settings → Accounts → Manage Certificates → + 에서 발급하세요 (Account Holder 계정 필요)." >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    echo "notarytool 키체인 프로파일 \"$notary_profile\"을 확인할 수 없습니다. 다음으로 등록하세요:" >&2
    echo "  xcrun notarytool store-credentials \"$notary_profile\" --apple-id <Apple ID> --team-id DKYJDHFLUG" >&2
    echo "(암호는 appleid.apple.com에서 만든 앱 암호를 사용)" >&2
    exit 1
fi

derived_data="$(mktemp -d "${TMPDIR:-/tmp}/env-pilot-release.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT

xcodebuild \
    -resolvePackageDependencies \
    -project env-pilot.xcodeproj \
    -scheme env-pilot \
    -derivedDataPath "$derived_data"

# archive + export(developer-id, automatic signing)로 서명한다.
# -allowProvisioningUpdates가 Developer ID 프로비저닝 프로파일(iCloud 포함) 생성·임베드와
# entitlement 주입, Sparkle 등 내장 코드 재서명까지 처리한다.
xcarchive="$derived_data/env-pilot.xcarchive"
xcodebuild \
    -project env-pilot.xcodeproj \
    -scheme env-pilot \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data" \
    -archivePath "$xcarchive" \
    -allowProvisioningUpdates \
    archive

export_options="$derived_data/ExportOptions.plist"
cat > "$export_options" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>DKYJDHFLUG</string>
</dict>
</plist>
PLIST

xcodebuild \
    -exportArchive \
    -archivePath "$xcarchive" \
    -exportOptionsPlist "$export_options" \
    -exportPath "$derived_data/export" \
    -allowProvisioningUpdates

app="$derived_data/export/env-pilot.app"
info="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
tag="v$version"
release_dir="$repo_root/build/release/$tag"

if [[ -e "$release_dir" ]]; then
    echo "$release_dir가 이미 있습니다. 기존 결과를 옮기거나 삭제한 뒤 다시 실행하세요." >&2
    exit 1
fi
mkdir -p "$release_dir"

codesign --verify --deep --strict "$app"

archive="$release_dir/Env-Pilot-$version.zip"
notes="$release_dir/Env-Pilot-$version.md"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait

# 스테이플은 zip이 아니라 .app에만 붙는다 — 스테이플 후 배포용 zip을 다시 만든다.
xcrun stapler staple "$app"
rm "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
spctl -a -vv "$app"

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
