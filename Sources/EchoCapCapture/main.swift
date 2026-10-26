import Foundation

/// Entry point of the capture helper.
///
/// Deliberately does not link or start AppKit: the tap can only be created in
/// a process without a GUI run loop.
CaptureHelper.main()
