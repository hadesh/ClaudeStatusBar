import Foundation

public enum TerminalNavigator {
    public typealias ProcessInfoFn = (Int) -> (parent: Int, name: String)?
    public typealias IsGuiAppFn = (Int) -> Bool

    /// Walks the parent process chain and returns the first pid where `isGuiApp` returns true.
    /// "GUI app" means a LaunchServices-registered .app (i.e. `NSRunningApplication(processIdentifier:)`
    /// returns a non-nil instance). The starting pid itself is checked first.
    /// Bounded at 32 hops so a corrupt parent map can never spin forever.
    public static func findGuiAncestor(
        startingFrom pid: Int,
        processInfo: ProcessInfoFn,
        isGuiApp: IsGuiAppFn
    ) -> Int? {
        var current = pid
        for _ in 0..<32 {
            guard current > 1 else { return nil }
            if isGuiApp(current) { return current }
            guard let info = processInfo(current) else { return nil }
            current = info.parent
        }
        return nil
    }
}
