import Foundation
import Testing

/// scripts/stack-checks.sh, which CI's changes jobs ask what a stack lets them skip.
///
/// A wrong skip leaves a change's screens untested, so the screenshot tests are
/// skipped only on the first attempt of a run whose payload proves the pull
/// request is below the top of its stack (docs/ci.md "Stacked pull requests").
@Suite struct StackChecksTests {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // the repository
  private static let script = repository.appendingPathComponent("scripts/stack-checks.sh")

  struct Case: Sendable, CustomTestStringConvertible {
    let testDescription: String
    var event = "pull_request"
    var attempt = "1"
    /// The event's payload, or nil for a file that is not there.
    let payload: String?
  }

  private struct Decision {
    let skipsScreenshots: Bool
    let allowsDocsOnly: Bool
    let reason: String
  }

  /// A pull request's payload with the fields the script reads, where `stack`
  /// is the JSON of its stack, or nil for a payload with no such key.
  private static func pullRequest(
    action: String = "synchronize",
    base: String = "main",
    draft: Bool = false,
    stack: String? = nil
  ) -> String {
    let stackField = stack.map { #", "stack": \#($0)"# } ?? ""
    return """
      {"action": "\(action)",
       "pull_request": {"draft": \(draft), "base": {"ref": "\(base)"}\(stackField)},
       "repository": {"default_branch": "main"}}
      """
  }

  private static func stack(_ position: String, of size: String, trunk: String = "main") -> String {
    """
    {"id": 7, "number": 9, "position": \(position), "size": \(size),
     "base": {"ref": "\(trunk)", "sha": "0a1b2c"}}
    """
  }

  private func decide(_ input: Case) throws -> Decision {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "event-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: file) }
    if let payload = input.payload { try Data(payload.utf8).write(to: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.script.path, input.event, input.attempt, file.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    // What the workflows append to GITHUB_OUTPUT: one line for each output.
    let lines = String(decoding: printed, as: UTF8.self).split(separator: "\n")
    try #require(lines.count == 3)
    try #require(lines[0] == "screenshots=run" || lines[0] == "screenshots=skip")
    try #require(lines[1] == "docs-only-allowed=true" || lines[1] == "docs-only-allowed=false")
    try #require(lines[2].hasPrefix("reason="))
    return Decision(
      skipsScreenshots: lines[0] == "screenshots=skip",
      allowsDocsOnly: lines[1] == "docs-only-allowed=true",
      reason: String(lines[2].dropFirst("reason=".count))
    )
  }

  @Test(arguments: [
    Case(
      testDescription: "the bottom",
      payload: pullRequest(stack: stack("1", of: "3"))
    ),
    Case(
      testDescription: "a middle layer",
      payload: pullRequest(base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "the layer just below the top",
      payload: pullRequest(base: "layer-23", stack: stack("24", of: "25"))
    ),
    Case(
      testDescription: "a layer opened already linked",
      payload: pullRequest(action: "opened", base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "a draft layer",
      payload: pullRequest(base: "layer-1", draft: true, stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "a layer marked ready",
      payload: pullRequest(action: "ready_for_review", base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "a layer reopened",
      payload: pullRequest(action: "reopened", base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "the old top, pushed after a layer was added above it",
      payload: pullRequest(base: "layer-2", stack: stack("3", of: "4"))
    ),
    Case(
      testDescription: "the lowest open layer after two merged, which keeps its position",
      payload: pullRequest(stack: stack("3", of: "6"))
    ),
    // The size still counts a closed layer, so this reads as any middle does.
    Case(
      testDescription: "the layer under a closed top",
      payload: pullRequest(base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "any future stack, known only by position and size",
      payload: pullRequest(base: "feature/later", stack: #"{"position": 1, "size": 2}"#)
    ),
    Case(
      testDescription: "a layer of a stack on another trunk",
      payload: pullRequest(base: "layer-1", stack: stack("2", of: "3", trunk: "release/1"))
    ),
  ])
  func aLayerBelowTheTopSkipsScreenshotsAndSaysWhy(_ input: Case) throws {
    let decision = try decide(input)
    #expect(decision.skipsScreenshots)
    #expect(!decision.allowsDocsOnly)
    #expect(decision.reason.contains("top"))
  }

  @Test(arguments: [
    Case(
      testDescription: "the top",
      payload: pullRequest(base: "layer-2", stack: stack("3", of: "3"))
    ),
    Case(
      testDescription: "a top still a draft",
      payload: pullRequest(base: "layer-2", draft: true, stack: stack("3", of: "3"))
    ),
    Case(
      testDescription: "a top marked ready",
      payload: pullRequest(action: "ready_for_review", base: "layer-2", stack: stack("3", of: "3"))
    ),
    Case(
      testDescription: "a newly added top",
      payload: pullRequest(base: "layer-3", stack: stack("4", of: "4"))
    ),
    Case(
      testDescription: "the top after every layer below merged",
      payload: pullRequest(stack: stack("6", of: "6"))
    ),
    Case(
      testDescription: "a stack of one",
      payload: pullRequest(stack: stack("1", of: "1"))
    ),
    Case(
      testDescription: "a layer opened before it was linked",
      payload: pullRequest(action: "opened", base: "layer-1")
    ),
    Case(
      testDescription: "a layer opened before it was linked, its stack null",
      payload: pullRequest(action: "opened", base: "layer-1", stack: "null")
    ),
  ])
  func theTopAndALayerNotYetLinkedRunEverything(_ input: Case) throws {
    try expectEverything(input)
  }

  /// A rerun replays the payload of its first attempt, which may be stale.
  @Test(arguments: [
    Case(
      testDescription: "a middle layer's rerun",
      attempt: "2",
      payload: pullRequest(base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "a layer that became the top without a push, rerun",
      attempt: "3",
      payload: pullRequest(base: "layer-1", stack: stack("2", of: "3"))
    ),
    Case(
      testDescription: "the rerun of a run from before linking",
      attempt: "2",
      payload: pullRequest(action: "opened", base: "layer-1")
    ),
    Case(
      testDescription: "an attempt that cannot be read",
      attempt: "",
      payload: pullRequest(base: "layer-1", stack: stack("2", of: "3"))
    ),
  ])
  func aRerunRunsEverything(_ input: Case) throws {
    try expectEverything(input)
  }

  @Test(arguments: [
    Case(testDescription: "a push to main", event: "push", payload: #"{"ref": "refs/heads/main"}"#),
    Case(testDescription: "a merge group", event: "merge_group", payload: #"{"merge_group": {}}"#),
    Case(
      testDescription: "a merge group whose payload names a lower layer",
      event: "merge_group",
      payload: pullRequest(stack: stack("1", of: "3"))
    ),
    Case(
      testDescription: "another event whose payload names a lower layer",
      event: "pull_request_target",
      payload: pullRequest(stack: stack("1", of: "3"))
    ),
  ])
  func anEventOtherThanAPullRequestRunsEverything(_ input: Case) throws {
    try expectEverything(input)
  }

  @Test(arguments: [
    Case(testDescription: "no file", payload: nil),
    Case(testDescription: "an empty file", payload: ""),
    Case(testDescription: "not JSON", payload: "{"),
    Case(testDescription: "not an object", payload: "[]"),
    Case(testDescription: "two payloads", payload: pullRequest() + pullRequest()),
    Case(testDescription: "no pull request", payload: "{}"),
    Case(testDescription: "a pull request that is text", payload: #"{"pull_request": "2"}"#),
    Case(testDescription: "a base that is text", payload: #"{"pull_request": {"base": "main"}}"#),
    Case(testDescription: "no base", payload: #"{"pull_request": {}}"#),
  ])
  func anUnreadablePayloadRunsEverything(_ input: Case) throws {
    try expectEverything(input)
  }

  @Test(arguments: [
    Case(testDescription: "false", payload: pullRequest(stack: "false")),
    Case(testDescription: "a number", payload: pullRequest(stack: "2")),
    Case(testDescription: "a list", payload: pullRequest(stack: "[1, 3]")),
    Case(testDescription: "empty", payload: pullRequest(stack: "{}")),
    Case(
      testDescription: "only a base",
      payload: pullRequest(stack: #"{"base": {"ref": "main"}}"#)
    ),
    Case(testDescription: "no position", payload: pullRequest(stack: #"{"size": 3}"#)),
    Case(testDescription: "no size", payload: pullRequest(stack: #"{"position": 1}"#)),
    Case(testDescription: "a null position", payload: pullRequest(stack: stack("null", of: "3"))),
    Case(testDescription: "a null size", payload: pullRequest(stack: stack("1", of: "null"))),
    Case(
      testDescription: "a position of text",
      payload: pullRequest(stack: stack(#""1""#, of: "3"))
    ),
    Case(testDescription: "a size of text", payload: pullRequest(stack: stack("1", of: #""3""#))),
    Case(testDescription: "position zero", payload: pullRequest(stack: stack("0", of: "3"))),
    Case(testDescription: "a negative position", payload: pullRequest(stack: stack("-1", of: "3"))),
    Case(testDescription: "size zero", payload: pullRequest(stack: stack("1", of: "0"))),
    Case(testDescription: "half a position", payload: pullRequest(stack: stack("1.5", of: "3"))),
    Case(testDescription: "half a size", payload: pullRequest(stack: stack("1", of: "3.5"))),
    Case(testDescription: "above the top", payload: pullRequest(stack: stack("4", of: "3"))),
  ])
  func anUnreadableOrInconsistentStackRunsEverything(_ input: Case) throws {
    try expectEverything(input)
  }

  /// Outside a stack, a pull request into the default branch keeps the docs-only
  /// shortcut, rerun or not; a stack's layers never take it.
  @Test(arguments: [
    Case(testDescription: "no stack key", payload: pullRequest()),
    Case(testDescription: "a null stack", payload: pullRequest(stack: "null")),
    Case(testDescription: "opened", payload: pullRequest(action: "opened")),
    Case(testDescription: "a draft", payload: pullRequest(draft: true)),
    Case(testDescription: "rerun", attempt: "2", payload: pullRequest()),
  ])
  func aPullRequestWithNoStackMayStillBeDocsOnly(_ input: Case) throws {
    let decision = try decide(input)
    #expect(!decision.skipsScreenshots)
    #expect(decision.allowsDocsOnly)
  }

  /// A green skip outlives the layer's place in its stack, so it is safe only
  /// while everything reaches main through the queue, which skips nothing.
  @Test func nothingReachesMainAroundTheMergeQueue() throws {
    let file = Self.repository.appendingPathComponent(".github/rulesets/main.json")
    let ruleset = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    )
    let rules = try #require(ruleset["rules"] as? [[String: Any]])
    #expect(rules.contains { $0["type"] as? String == "merge_queue" })
    #expect(try #require(ruleset["bypass_actors"] as? [Any]).isEmpty)
  }

  private func expectEverything(_ input: Case) throws {
    let decision = try decide(input)
    #expect(!decision.skipsScreenshots)
    #expect(!decision.allowsDocsOnly)
  }
}
