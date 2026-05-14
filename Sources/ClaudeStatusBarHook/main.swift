import Foundation
import ClaudeStatusBarHookCore

// `~/Library/Application Support/ClaudeStatusBar/prompt.sock` — must match the
// path the main app's listener binds to (see AppDelegate.permissionSocketPath).
let socketPath = (NSString("~/Library/Application Support/ClaudeStatusBar/prompt.sock")
    .expandingTildeInPath as String)

let stdinData = (try? FileHandle.standardInput.readToEnd()) ?? Data()
guard !stdinData.isEmpty else { exit(0) }

let output = HookProcessor.process(input: stdinData) { request in
    SocketClient.requestResponse(socketPath: socketPath, requestLine: request)
}

if let output {
    FileHandle.standardOutput.write(output)
}
exit(0)
