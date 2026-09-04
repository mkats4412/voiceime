#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

APP_NAME="VoiceIME"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="${ROOT_DIR}/VoiceIME.entitlements"

echo "=== Building ${APP_NAME}.app ==="

# クリーンアップ & 出力ディレクトリ作成
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Swift ソースコードのコンパイル
echo "-> Compiling Swift sources..."
swiftc \
    -O \
    -target arm64-apple-macosx13.0 \
    -parse-as-library \
    Sources/VoiceIME/Models/*.swift \
    Sources/VoiceIME/Services/*.swift \
    Sources/VoiceIME/Views/*.swift \
    Sources/VoiceIME/App/*.swift \
    -o "${MACOS_DIR}/${APP_NAME}"

# Info.plist をバンドル内にコピー
echo "-> Copying Info.plist..."
cp Info.plist "${CONTENTS_DIR}/Info.plist"

# PkgInfo の作成
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# コード署名アイデンティティの自動検出
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning | grep -q "VoiceIME-Dev"; then
    SIGN_IDENTITY="VoiceIME-Dev"
    echo "-> 固定署名用証明書 [VoiceIME-Dev] を使用します（権限が固定・維持されます）"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep 'Apple Development' | head -n 1 | awk -F '"' '{print $2}')"
    echo "-> Apple Development 証明書 [${SIGN_IDENTITY}] を使用します"
else
    echo "-> 注意: コード署名証明書が見つからないためアドホック署名 (-) を使用します。"
    echo "   権限を固定するには './scripts/create_certificate.sh' を実行してください。"
fi

# コード署名 (Entitlements 付与)
echo "-> Code signing application bundle..."
codesign \
    --force \
    --deep \
    --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}"

echo "=== Build Complete! ==="
echo "Application created at: ${APP_BUNDLE}"

# 署名要件（Designated Requirement）の確認表示
echo "-> 署名検証:"
codesign -d -r- "${APP_BUNDLE}" 2>&1 | head -n 3

# オプション: --install 引数があれば /Applications に配置
if [[ "${1:-}" == "--install" ]]; then
    echo "-> /Applications にインストール中..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" "/Applications/"
    echo "Installed to /Applications/${APP_NAME}.app"
fi

echo ""
echo "To run the app, execute:"
echo "  open \"${APP_BUNDLE}\""
