#!/bin/zsh
# Compile and inspect the iOS app without signing, staging, zipping or publishing an IPA.
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$IOS/deps/StikJIT.xcframework" ] || "$IOS/scripts/fetch_deps.sh"
cd "$IOS"
xcodegen generate >/dev/null
DD="$IOS/build/DerivedData"
mkdir -p "$IOS/build"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed; no app output accepted" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/Henge.app"
# An iPhone Duo gives its whole inner screen only to apps built with the iOS 27.1 SDK or newer (bars otherwise).
SDK="$(plutil -extract DTSDKName raw "$APP/Info.plist" 2>/dev/null | sed 's/^iphoneos//')"
case "$SDK" in
    ''|*[!0-9.]*) ;;
    *) [ "$(printf '%s\n27.1\n' "$SDK" | sort -V | head -1)" = "27.1" ] || echo "  note     built with the iOS $SDK SDK: an iPhone Duo will not give Henge its whole inner screen (Xcode 27.1 or later does)" ;;
esac
rc=0
for f in "$APP/Henge" "$APP/henge-jit.js" "$APP/PlugIns/HengeJITHelper.appex/HengeJITHelper" \
         "$APP/Frameworks/StikJIT.framework/StikJIT" "$APP/Frameworks/StikJIT.framework/Info.plist"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; app validation failed" >&2; exit 1; }

echo "==> app compile verified: $APP (no IPA generated)"
