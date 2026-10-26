#!/bin/bash
#
# Build EchoCap.app — a menu-bar app bundle.
#
# The toolchain here is Command Line Tools only (no Xcode), so the bundle is
# assembled by hand: SwiftPM produces the binary, this script lays out the
# .app structure and ad-hoc signs it.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="EchoCap"
BUNDLE_ID="com.echocap.EchoCap"
VERSION="${VERSION:-1.0.0}"

cd "$PROJECT_DIR"

echo "==> 编译 (release)"
swift build -c release --disable-sandbox --package-path "$PROJECT_DIR"

echo "==> 生成应用图标"
ICON_FILE="${BUILD_DIR}/${APP_NAME}.icns"
"${BUILD_DIR}/release/${APP_NAME}" --render-icon "$ICON_FILE" 2>/dev/null || \
    swift build -c release --disable-sandbox --package-path "$PROJECT_DIR" >/dev/null && \
    "${BUILD_DIR}/release/${APP_NAME}" --render-icon "$ICON_FILE"
if [[ ! -f "$ICON_FILE" ]]; then
    echo "图标生成失败，继续打包（将使用系统默认图标）" >&2
fi

BINARY="${BUILD_DIR}/release/${APP_NAME}"
if [[ ! -x "$BINARY" ]]; then
    echo "找不到可执行文件: $BINARY" >&2
    exit 1
fi

echo "==> 组装 .app"
APP="${BUILD_DIR}/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "$BINARY" "${APP}/Contents/MacOS/${APP_NAME}"
# The capture helper lives next to the app inside the bundle.
HELPER="${BUILD_DIR}/release/EchoCapCapture"
if [[ -x "$HELPER" ]]; then
    cp "$HELPER" "${APP}/Contents/MacOS/EchoCapCapture"
fi
if [[ -f "$ICON_FILE" ]]; then
    cp "$ICON_FILE" "${APP}/Contents/Resources/${APP_NAME}.icns"
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>EchoCap</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <!-- Menu-bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <!-- 采集系统音频所需 -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>EchoCap 需要捕获系统正在播放的声音，以便实时生成字幕。音频只在本机处理。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>EchoCap 可以使用麦克风为正在说话的人生成字幕。音频只在本机处理。</string>
    <key>NSHumanReadableCopyright</key>
    <string>EchoCap — 本机实时字幕</string>
</dict>
</plist>
PLIST

echo "==> 签名"
# Ad-hoc 签名足以本地运行。注意：ad-hoc 签名每次重建都会改变 CDHash，
# macOS 可能因此重新询问音频权限 —— 用 Developer ID 证书签名可避免。
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
    || codesign --force --sign - "$APP"

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> 完成: ${APP}"
echo "    运行: open '${APP}'"
