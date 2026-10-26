# EchoCap

**Mac 上播放什么，就配上实时字幕。** 菜单栏常驻，浮层置顶，音频不出这台 Mac。

[English](README.en.md) · 简体中文

![浮层效果：历史字幕叠在上方，实时字幕与译文在下](overlay-preview.png)

---

## 这是什么

对标 [subtitles-live.com](https://subtitles-live.com/zh/) 的同名产品：**捕获 Mac 正在播放的任何声音**（会议、播客、视频、网课、直播），在本机完成语音识别，实时画在一层始终置顶的浮层上，可选翻译成另一种语言并双语显示。

与原产品不同的是，EchoCap 不下载任何模型 —— 它直接用 macOS 26 自带的 Speech 与 Translation 框架，装好即用，全程离线。

| | 原产品 Subtitles | EchoCap |
|---|---|---|
| 语音识别 | Parakeet / Nemotron（Core ML，633 MB 模型） | **macOS Speech 框架**（系统自带，无需下载） |
| 翻译 | Apple Translation（设备端） | **Apple Translation**（设备端，同源） |
| 系统音频捕获 | Core Audio process tap | **Core Audio process tap**（同一套 API） |
| 支持语言 | 18 种 + 2 种实验 | 系统已装模型的语言（本机实测中英文等 11 种已装） |
| 识别延迟 | 160 ms – 2.08 s（按模型档位） | 由系统模型决定，本机实测流式出字 |
| 价格 | $19 买断 | 开源免费 |

## 已实现的功能

**声音来源**
- 捕获系统正在播放的一切（任何 App，包括浏览器与 Electron 应用）
- 麦克风输入
- 切换来源时清空字幕并重置识别器

**字幕**
- 置顶浮层，始终在所有窗口之上
- **不吃点击**，可以隔着它继续在下面的 App 里工作
- **指针下方淡出**：光标附近的字幕溶掉，永远不挡住你正在读的字
- 按住 `⇧` 拖动浮层，位置会被记住
- 广播式分页：写满 N 行后清空重开
- 无新文字约 4 秒后淡出（按"最后一次出现新文字"算，不是按音频静默算）

**回溯与搜索**
- 按住 `⌥` 把最近几块字幕叠回当前字幕上方
- `⌥F` 搜索历史字幕
- `Esc` 关闭堆叠

**翻译**
- 翻译成另一种语言，可与原文同时显示
- 设备端完成，译文不出本机

**其它**
- 菜单栏常驻，无 Dock 图标
- 文字记录可导出为纯文本 / Markdown / SRT
- 设置面板：字号、每屏行数、底板不透明度、淡出半径、堆叠间距等，拖动即时生效

### 采集失败时不会卡住

Core Audio 在音频服务器状态异常时会阻塞（实测机器锁屏、无默认输出设备时，`AudioDeviceStart` 会一直等下去）。因此：

- 采集的建立放在独立队列上，**永远不占住主线程**，界面不会冻住
- 8 秒超时后给出明确提示，并在 15 秒后自动重试 —— 机器唤醒、输出设备恢复后会自动接上
- 提示里会直接给出可操作建议（例如改用麦克风）

## 快速开始

```bash
# 构建 .app（无需 Xcode）
./build-app.sh

# 运行
open .build/EchoCap.app
```

首次运行时 macOS 会请求**屏幕与系统音频录制**权限（捕获系统音频所必需）。授权后即可使用。

### 命令行诊断

```bash
# 打印实时识别与翻译到 stderr
.build/debug/EchoCap --log --lang en-US --translate zh-Hans

# 离屏渲染浮层预览（不碰桌面）
.build/debug/EchoCap --render-overlay /tmp/overlay.png
```

## 项目结构

```
Sources/
  EchoCapCore/            纯逻辑，可单元测试，不依赖 AppKit
    CaptionBox.swift        一个字幕框
    CaptionPipeline.swift   分页、历史栈、搜索
    TranscriptAssembler.swift  识别器的累积式输出 → 分段事件
    SampleRateConverter.swift  48 kHz 立体声 → 16 kHz 单声道 Int16
    TextMeasurer.swift      CoreText 行数测量
    TranscriptExporter.swift  txt / md / srt 导出
    LanguageCatalog.swift   语言清单
    AppSettings.swift       持久化设置
  EchoCap/                macOS 应用
    SystemAudioCapture.swift  Core Audio process tap → 聚合设备 → IOProc
    SpeechEngine.swift        macOS Speech 流式识别
    TranslationService.swift   Apple Translation
    CaptionOverlayWindow.swift 置顶浮层窗口
    CaptionOverlayView.swift   字幕绘制、指针淡出、历史堆叠
    MenuBarController.swift    菜单栏
    SettingsWindow.swift       设置面板
    AppController.swift        把整条链路串起来
Tests/EchoCapTests/       19 个单元测试
```

## 技术要点

**捕获系统音频**（`SystemAudioCapture.swift`）

用的是 macOS 14.2 引入的 Core Audio process tap。四步，和 Apple 的参考实现一致：

1. `AudioHardwareCreateProcessTap` 建一个全局 tap
2. 用 `kAudioTapPropertyUID`（`'tuid'`）取它的 UID
3. 把 tap 塞进一个**私有聚合设备**（`kAudioAggregateDeviceIsPrivateKey` 必须为 YES）—— 这一步是 tap 拥有 IO 通路的关键
4. 在聚合设备上挂 IOProc 读帧

实时线程只做一次拷贝，写进无锁环形缓冲；重采样和滤波在 worker 线程上做。

> 踩坑记录：tap 的 UID 属性选择器是 `'tuid'` 而不是 `'uuid'`；聚合设备的 `taps` 要传 **字典数组**（`{kAudioSubTapUIDKey: uid}`）而不是字符串数组；少了 `private` 键，`AudioDeviceStart` 会返回 `'nope'`。

**音频格式**（`SampleRateConverter.swift`）

Speech 框架要的是 **16 kHz 单声道 Int16 交错**。tap 出来的是 48 kHz 立体声 Float32，所以要：

- 降混为单声道
- 用 63 抽头 Blackman 窗低通 FIR 抗混叠
- 3:1 抽取到 16 kHz
- 转 Int16

注意 `AVAudioCommonFormat` 的 raw value 3 是 **Int16**，不是 Float32 —— 传错格式会在 `AnalyzerInput.init` 里直接崩。

**分段与修订**（`TranscriptAssembler.swift`）

Speech 框架每次给出的是**当前整段的累积文字**，而且会用不同的 range 关闭这一段，所以 range 不能当分段标识。这里改成从文字本身判断：

- 新文字是旧文字的前缀 → 同一段，识别器在改口
- 新旧文字公共前缀超过 60% → 同一段的修订
- 否则 → 真的换了一句，提交上一段

这样 "EchoCab" → "EchoCap" 的改口会被正确替换，而不是把旧片段永远留在字幕里。

**并发**（Swift 6 严格并发）

- UI 一律 `@MainActor`
- `TranslationService` 是 actor（`TranslationSession` 有状态，不能并发使用）
- 识别回调放在一个 `SpeechCallbacks` 盒子里，结果任务每次读最新的回调 —— 早先的写法在 `start()` 之前就把回调捕获走了，结果全部丢失
- 音频数据流经 `@unchecked Sendable` 的类，隔离由 actor/主队列保证

## 构建说明

这台机器只有 Command Line Tools，没有完整 Xcode，因此：

- 用 SwiftPM 编译，`build-app.sh` 手工拼出 `.app` 结构并 ad-hoc 签名
- 单元测试用 Swift Testing（`XCTest` 不在 CLT 里）
- **SwiftPM 不会自动把 testing 宏插件传给测试目标**，`Package.swift` 里显式加了 `-plugin-path`；另外 `swiftLanguageModes: [.v5]` 会让 testing 宏失效，必须用 Swift 6 模式

## 已知限制

- 需要 macOS 26 或更高（用了 `SpeechAnalyzer` / `SpeechTranscriber`）
- 需要 Apple silicon
- 系统音频捕获需要"屏幕与系统音频录制"权限；**拒绝授权时 macOS 不会报错，只会得到静音**
- ad-hoc 签名每次重建 CDHash 都会变，macOS 可能因此重新询问权限；用 Developer ID 证书签名可避免
- 自动检测语言需要多语言模型（`mul_IN`），本机未安装时会自动退回已安装的单语言模型
- 尚未实现：换人说话自动另起字幕框（需要说话人分离模型）、朗读译文、单一 App 定向捕获

## 许可证

MIT
