import SwiftUI
import AppKit
import EchoCapCore

/// The SwiftUI layer that draws captions, dissolves them under the pointer,
/// and stacks history when `⌥` is held.
struct CaptionOverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // The stack is laid out bottom-up: history first, live caption last.
                VStack(spacing: model.settings.historySpacing) {
                    Spacer(minLength: 0)

                    if model.isShowingHistory {
                        ForEach(model.historyBoxes) { box in
                            CaptionBoxView(
                                box: box,
                                settings: model.settings,
                                isLive: false,
                                isHighlighted: model.searchResults.contains(box.id)
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    if let live = model.liveBox, !model.isFadingOut {
                        CaptionBoxView(
                            box: live,
                            settings: model.settings,
                            isLive: true,
                            isHighlighted: false
                        )
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .background(Color.clear)
            .allowsHitTesting(false)
            .onAppear { model.containerSize = proxy.size }
            .onChange(of: proxy.size) { _, newValue in model.containerSize = newValue }
        }
    }
}

/// One caption box: the text, its optional translation, and the source app tag.
struct CaptionBoxView: View {
    let box: CaptionBox
    let settings: AppSettings
    let isLive: Bool
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            if settings.showSourceAppName, let source = box.sourceAppName {
                Text(source)
                    .font(.system(size: max(11, settings.fontSize * 0.42), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            Text(box.displayText)
                .font(.system(size: settings.fontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(settings.alignment == .center ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: settings.alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)

            if settings.showBothLanguages, !box.displayTranslation.isEmpty {
                Text(box.displayTranslation)
                    .font(.system(size: settings.fontSize * 0.86, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(settings.alignment == .center ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: settings.alignment == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(settings.boxOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08),
                    lineWidth: isHighlighted ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    private var alignment: HorizontalAlignment {
        settings.alignment == .center ? .center : .leading
    }
}

/// Observable state the overlay renders from.
final class OverlayModel: ObservableObject {
    @Published var liveBox: CaptionBox?
    @Published var historyBoxes: [CaptionBox] = []
    @Published var isShowingHistory = false
    @Published var isFadingOut = false
    @Published var searchResults: Set<UUID> = []
    @Published var containerSize: CGSize = .zero

    let settings: AppSettings

    /// Where the pointer is, in the overlay's coordinate space.
    @Published var pointerLocation: CGPoint?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Update the pointer position used for the dissolve effect.
    func pointerMoved(to point: CGPoint) {
        guard settings.fadeAwayUnderPointer else {
            if pointerLocation != nil { pointerLocation = nil }
            return
        }
        pointerLocation = point
    }
}
