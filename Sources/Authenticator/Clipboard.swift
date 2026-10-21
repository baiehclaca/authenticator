import AppKit

@MainActor
enum Clipboard {
    private static var clearTask: Task<Void, Never>?

    /// Copies `string`, marks it concealed/transient for clipboard managers, and
    /// clears it after `seconds` (if > 0) unless something else was copied meanwhile.
    static func copy(_ string: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        // http://nspasteboard.org conventions, honoured by most clipboard managers.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pb.changeCount

        clearTask?.cancel()
        guard seconds > 0 else { return }
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == changeCount { pb.clearContents() }
        }
    }
}
