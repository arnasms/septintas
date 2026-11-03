import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let tool = directory.appendingPathComponent("CodexBarCLI")
func writeTool(_ body: String) {
    try! ("#!/bin/sh\n" + body + "\n").write(to: tool, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
}
let source = LimitsSource(tool: tool.path)
let received = DispatchSemaphore(value: 0)
var expectedState = UsageState.sourceMissing
var expectedCount = 0
source.onUpdate = { values, state in
    precondition(state == expectedState && values.count == expectedCount)
    received.signal()
}
func refresh(_ state: UsageState, count: Int) {
    expectedState = state
    expectedCount = count
    source.start()
    precondition(received.wait(timeout: .now() + 5) == .success)
    source.stop()
}
refresh(.sourceMissing, count: 0)
writeTool("exit 1")
refresh(.unavailable, count: 0)
writeTool("echo '{\"usage\":{\"primary\":{\"usedPercent\":12},\"secondary\":{\"usedPercent\":34}},\"daily\":[]}'")
refresh(.available, count: 2)
try FileManager.default.removeItem(at: tool)
refresh(.sourceMissing, count: 0) // Removal must discard the previous successful snapshot.
writeTool("exit 1")
refresh(.unavailable, count: 0) // Reinstall with no providers cannot resurrect old limits.
print("Limits source passed: missing, failure, available, removal clears cache, reinstall")
