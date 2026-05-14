import XCTest
@testable import ClaudeStatusBar

final class TerminalNavigatorTests: XCTestCase {
    private let neverGui: TerminalNavigator.IsGuiAppFn = { _ in false }
    private let alwaysGui: TerminalNavigator.IsGuiAppFn = { _ in true }

    func testReturnsFirstGuiAncestor() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { pid in
            switch pid {
            case 100: return (parent: 50, name: "claude")
            case 50:  return (parent: 30, name: "zsh")
            case 30:  return (parent: 10, name: "tmux")
            case 10:  return (parent: 1, name: "iTerm2")
            default:  return nil
            }
        }
        // Only pid 10 is a GUI app; everything else (claude, zsh, tmux) is not.
        let isGuiApp: TerminalNavigator.IsGuiAppFn = { $0 == 10 }
        XCTAssertEqual(
            TerminalNavigator.findGuiAncestor(startingFrom: 100, processInfo: processInfo, isGuiApp: isGuiApp),
            10
        )
    }

    func testReturnsStartingPidWhenItselfIsAGuiApp() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { _ in (parent: 1, name: "x") }
        XCTAssertEqual(
            TerminalNavigator.findGuiAncestor(startingFrom: 999, processInfo: processInfo, isGuiApp: alwaysGui),
            999
        )
    }

    func testReturnsNilWhenNoGuiInChain() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { pid in
            switch pid {
            case 100: return (parent: 50, name: "zsh")
            case 50:  return (parent: 1, name: "launchd")
            default:  return nil
            }
        }
        XCTAssertNil(
            TerminalNavigator.findGuiAncestor(startingFrom: 100, processInfo: processInfo, isGuiApp: neverGui)
        )
    }

    func testReturnsNilOnMissingProcess() {
        let processInfo: TerminalNavigator.ProcessInfoFn = { _ in nil }
        XCTAssertNil(
            TerminalNavigator.findGuiAncestor(startingFrom: 100, processInfo: processInfo, isGuiApp: neverGui)
        )
    }

    func testBoundsHopCountAt32() {
        var calls = 0
        let processInfo: TerminalNavigator.ProcessInfoFn = { pid in
            calls += 1
            return (parent: pid + 1, name: "zsh")  // chain never bottoms out
        }
        XCTAssertNil(
            TerminalNavigator.findGuiAncestor(startingFrom: 1000, processInfo: processInfo, isGuiApp: neverGui)
        )
        XCTAssertEqual(calls, 32, "should stop after 32 hops to avoid runaway loops")
    }
}
