import Foundation

/// When the history stack is allowed to show.
///
/// ⌥ on its own means "let me peek at what came before". ⌥⌘S is the
/// start/stop shortcut, not a peek: if it triggered the peek too, stopping a
/// recording would leave the history stacked behind the save dialog and the
/// captions would appear in two parts.
public enum HistoryPeek {
    public static func shouldShow(option: Bool, command: Bool) -> Bool {
        option && !command
    }
}
