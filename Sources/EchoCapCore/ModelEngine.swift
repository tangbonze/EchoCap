import Foundation

/// Which model does a job: the one built into macOS, or a cloud endpoint the
/// user configured.
///
/// Speech recognition is always local — Apple's transcriber never leaves the
/// machine — so this only applies to translation and summarising.
public enum ModelEngine: String, CaseIterable, Sendable {
    case local
    case cloud

    public var displayName: String {
        switch self {
        case .local: return "本机模型"
        case .cloud: return "云端 API"
        }
    }
}
