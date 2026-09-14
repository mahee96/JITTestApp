#!/usr/bin/env bash

set -euo pipefail

# Default values
SCHEME="JITTestApp"
CONFIGURATION="Release"
OUTPUT_IPA="JITTestApp.ipa"
ENTITLEMENTS="JITTestApp/JITTestApp.entitlements"
DO_CLEAN=false
DO_FAKESIGN=true
BUILD_DIR="build"

usage() {
    cat << HELP
Usage: $(basename "\$0") [options]

Options:
  -s, --scheme <name>          Xcode scheme to build (default: JITTestApp)
  -c, --configuration <config> Build configuration: Debug or Release (default: Release)
  -o, --output <file.ipa>      Output IPA filename/path (default: JITTestApp.ipa)
  -e, --entitlements <path>    Path to entitlements file (default: JITTestApp/JITTestApp.entitlements)
      --clean                  Clean build artifacts before building
      --no-fakesign            Skip ad-hoc/fake-signing with entitlements
  -h, --help                   Display this help message

Examples:
  ./build.sh
  ./build.sh --clean --output JITTestApp_v1.0.0.ipa
  ./build.sh --configuration Debug --output build/JITTestApp-Debug.ipa
HELP
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--scheme)
            SCHEME="$2"
            shift 2
            ;;
        -c|--configuration)
            CONFIGURATION="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_IPA="$2"
            shift 2
            ;;
        -e|--entitlements)
            ENTITLEMENTS="$2"
            shift 2
            ;;
        --clean)
            DO_CLEAN=true
            shift
            ;;
        --no-fakesign)
            DO_FAKESIGN=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"

if [ "$DO_CLEAN" = true ]; then
    echo "==> Cleaning previous build artifacts..."
    rm -rf "$BUILD_DIR" Payload "$OUTPUT_IPA"
fi

mkdir -p "$BUILD_DIR"

echo "==> Archiving $SCHEME ($CONFIGURATION)..."
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild archive \
        -project "$SCHEME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        -sdk iphoneos \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        AD_HOC_CODE_SIGNING_ALLOWED=YES | xcbeautify
else
    xcodebuild archive \
        -project "$SCHEME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -archivePath "$ARCHIVE_PATH" \
        -sdk iphoneos \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        AD_HOC_CODE_SIGNING_ALLOWED=YES
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Application bundle not found at $APP_PATH" >&2
    exit 1
fi

if [ "$DO_FAKESIGN" = true ]; then
    echo "==> Fake-signing binary with entitlements ($ENTITLEMENTS)..."
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "Warning: Entitlements file not found at $ENTITLEMENTS, skipping entitlements embedding."
    else
        if command -v ldid >/dev/null 2>&1; then
            echo "  Using ldid..."
            ldid -S"$ENTITLEMENTS" "$APP_PATH/$SCHEME"
        else
            echo "  Using codesign (ad-hoc)..."
            codesign -s - --force --entitlements "$ENTITLEMENTS" "$APP_PATH"
        fi
    fi
fi

echo "==> Packaging into $OUTPUT_IPA..."
rm -rf Payload
mkdir -p Payload
cp -R "$APP_PATH" Payload/

mkdir -p "$(dirname "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
zip -qr "$OUTPUT_IPA" Payload
rm -rf Payload

echo "==> Successfully created $OUTPUT_IPA ($(du -h "$OUTPUT_IPA" | cut -f1))"
