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
                    } else if let banner = model.banner {
                        BannerView(banner: banner)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // The part of the caption under the pointer dissolves away so
                // it never covers what the user is reading or writing.
                .dissolveUnderPointer(
                    location: model.pointerLocation,
                    radius: model.settings.pointerDissolveRadius,
                    extent: model.settings.pointerDissolveExtent,
                    size: proxy.size
                )
            }
            // A hair of opacity instead of full transparency: a window with
            // `isOpaque = false` and a completely clear root layer gives the
            // compositor nothing to draw, and the masked caption stack then
            // renders as nothing at all.
            .background(Color.black.opacity(0.004))
            .allowsHitTesting(false)
            .onAppear { model.containerSize = proxy.size }
            .onChange(of: proxy.size) { _, newValue in model.containerSize = newValue }
        }
    }
}

/// A compact notice shown when the app cannot produce captions.
struct BannerView: View {
    let banner: OverlayBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(banner.kind.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail = banner.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(banner.kind.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
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

/// A message shown in the overlay when something needs the user's attention.
struct OverlayBanner: Equatable {
    enum Kind {
        case error
        case warning
        case info

        var symbol: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return .accentColor
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String?
}

/// Observable state the overlay renders from.
final class OverlayModel: ObservableObject {
    /// A message to show in place of captions, when the app cannot caption.
    @Published var banner: OverlayBanner?

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
