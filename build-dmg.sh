#!/bin/bash
#
# Build EchoCap-<version>.dmg — a distributable disk image.
#
# No Xcode here, so the image is assembled by hand with hdiutil:
#   1. build the .app
#   2. stage it with an /Applications symlink
#   3. create a read-write image, lay out its window, convert to compressed
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="EchoCap"
VERSION="${VERSION:-1.0.0}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGING="${PROJECT_DIR}/.build/dmg-staging"
MOUNT_DIR="/Volumes/${APP_NAME} ${VERSION}"
OUTPUT="${PROJECT_DIR}/dist/${DMG_NAME}"

echo "==> 编译 .app"
./build-app.sh >/dev/null

APP="${PROJECT_DIR}/.build/${APP_NAME}.app"
if [[ ! -d "$APP" ]]; then
    echo "找不到 ${APP}" >&2
    exit 1
fi

echo "==> 准备暂存目录"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

# A short note for whoever opens the image.
cat > "${STAGING}/README.txt" <<'TXT'
EchoCap — Mac 上播放什么，就配上实时字幕。

安装
----
1. 把 EchoCap.app 拖进 Applications 文件夹
2. 首次打开时，在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」里允许 EchoCap

没有它就抓不到系统正在播放的声音（macOS 不会报错，只会得到静音）。

卸载
----
把 EchoCap.app 拖回废纸篓即可。
TXT

echo "==> 创建磁盘映像"
rm -f "$OUTPUT"
mkdir -p "${PROJECT_DIR}/dist"
# -UDRW creates a read-write image so the window layout can be set before
# compressing it.
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "${APP_NAME} ${VERSION}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -ov "${OUTPUT}"

echo "==> 设置卷标与窗口布局"
hdiutil attach "$OUTPUT" -mountpoint "$MOUNT_DIR" -nobrowse -quiet || true

# Best effort: place the app icon on the left and the Applications symlink on
# the right, and set the window to a sensible size. Skipped silently when
# Finder automation is unavailable (for example on a locked screen).
osascript <<APPLESCRIPT 2>/dev/null || true
tell application "Finder"
    tell disk "${APP_NAME} ${VERSION}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set position of item "${APP_NAME}.app" of container window to {150, 180}
        set position of item "Applications" of container window to {430, 180}
        set position of item "README.txt" of container window to {150, 350}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# Mark the volume read-only so the user cannot modify its contents.
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
hdiutil detach "$MOUNT_DIR" -quiet || true

echo "==> 压缩为只读映像"
# hdiutil refuses to write over the source image and appends ".dmg" to the
# output name, so convert to a temporary file and swap it in.
TEMP_DMG="${PROJECT_DIR}/.build/dmg-compressed"
rm -f "$TEMP_DMG" "${TEMP_DMG}.dmg"
hdiutil convert "$OUTPUT" -format UDZO -imagekey zlib-level=9 -o "$TEMP_DMG"
mv -f "${TEMP_DMG}.dmg" "$OUTPUT"

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "==> 完成: ${OUTPUT} (${SIZE})"

# Verify the image can be mounted and the app is inside.
echo "==> 校验"
VERIFY_MOUNT="/tmp/echocap-verify"
rm -rf "$VERIFY_MOUNT" && mkdir -p "$VERIFY_MOUNT"
if hdiutil attach "$OUTPUT" -mountpoint "$VERIFY_MOUNT" -nobrowse -quiet; then
    if [[ -d "${VERIFY_MOUNT}/${APP_NAME}.app" ]]; then
        echo "    ✓ 映像内含 ${APP_NAME}.app"
    else
        echo "    ✗ 映像内缺少 ${APP_NAME}.app" >&2
        hdiutil detach "$VERIFY_MOUNT" -quiet || true
        exit 1
    fi
    hdiutil detach "$VERIFY_MOUNT" -quiet || true
else
    echo "    ✗ 映像无法挂载" >&2
    exit 1
fi
