import AppKit
import SwiftUI
import EchoCapCore

/// Applies the "dissolve under the pointer" effect.
///
/// The caption is masked so that the region under the cursor fades to fully
/// transparent, recovering to fully opaque once the cursor moves away. The
/// mask is drawn with a radial gradient whose inner hole matches the pointer.
struct DissolveUnderPointer: ViewModifier {
    var pointerLocation: CGPoint?
    var radius: Double
    var extent: Double
    var size: CGSize

    func body(content: Content) -> some View {
        content.mask {
            if let pointerLocation, radius > 0 {
                // A radial gradient centred on the pointer: clear in the middle,
                // opaque towards the edges.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: holeFraction),
                        .init(color: .black, location: 1),
                    ]),
                    center: UnitPoint(
                        x: pointerLocation.x / max(size.width, 1),
                        y: pointerLocation.y / max(size.height, 1)
                    ),
                    startRadius: 0,
                    endRadius: max(radius + extent, 1)
                )
            } else {
                Rectangle()
            }
        }
    }

    /// Where the fully transparent hole ends, as a fraction of the outer radius.
    private var holeFraction: Double {
        let total = max(radius + extent, 1)
        return min(max(radius / total, 0), 0.98)
    }
}

extension View {
    func dissolveUnderPointer(
        location: CGPoint?,
        radius: Double,
        extent: Double,
        size: CGSize
    ) -> some View {
        modifier(DissolveUnderPointer(
            pointerLocation: location,
            radius: radius,
            extent: extent,
            size: size
        ))
    }
}
