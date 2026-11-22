import Foundation
import Testing

/// Where a test may make a `TestStore`: in this target, which runs in a process
/// of its own, and there only inside `StoreTests`, which runs one at a time
/// (docs/testing.md "Stores in tests").
@Suite struct StorePlacementTests {
  private static let thisFile = "AthinaFeaturesTests/StorePlacementTests.swift"
  private static let tests = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AthinaFeaturesTests
    .deletingLastPathComponent()  // Tests

  /// Whether `source` makes a store or flips the switch one flips.
  private static func flipsTheExecutor(_ source: String) -> Bool {
    let code = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    return code.contains(/\bTestStore(Of)?\s*(<[^>\n]*>)?\s*(\(|\.init\b)/)
      || code.contains(/\bwithMainSerialExecutor\s*[({]/)
      || code.contains(/\buncheckedUseMainSerialExecutor\s*=[^=]/)
  }

  /// Every test source that flips the executor, by its path below Tests, but
  /// this one, which only spells the flips out to look for them.
  private static func flippers() throws -> [(path: String, source: String)] {
    let files = try #require(FileManager.default.enumerator(atPath: tests.path))
    var found: [(path: String, source: String)] = []
    while let path = files.nextObject() as? String {
      guard path.hasSuffix(".swift"), path != thisFile else { continue }
      let source = try String(contentsOf: tests.appendingPathComponent(path), encoding: .utf8)
      if flipsTheExecutor(source) { found.append((path, source)) }
    }
    return found
  }

  @Test func noOtherTargetMakesAStore() throws {
    let found = try Self.flippers()
    try #require(!found.isEmpty, "found no store at all, so the check sees nothing")
    let elsewhere = found.map(\.path).filter { !$0.hasPrefix("AthinaFeaturesTests/") }
    #expect(elsewhere == [], "only AthinaFeaturesTests runs apart from the tests a store can hang")
  }

  @Test func everyStoreIsMadeInsideStoreTests() throws {
    var outside: [String] = []
    for (path, source) in try Self.flippers() where path.hasPrefix("AthinaFeaturesTests/") {
      // swift-format keeps only top-level code at the margin.
      let stray = source.split(separator: "\n").filter { line in
        guard let first = line.first, first != " " else { return false }
        return !["import ", "@testable import ", "extension StoreTests ", "}", "//", "#"]
          .contains { line.hasPrefix($0) }
      }
      outside += stray.map { "\(path): \($0)" }
    }
    #expect(outside == [], "a file that makes a store holds only extensions of StoreTests")
  }

  @Test(arguments: [
    "let store = TestStore(initialState: State()) { Feature() }",
    "let store = TestStoreOf<Feature>(initialState: State()) { Feature() }",
    "let store: TestStoreOf<Feature> = TestStore.init(initialState: State()) { Feature() }",
    "await withMainSerialExecutor { await work() }",
    "uncheckedUseMainSerialExecutor = true",
  ])
  func aFlipIsSeen(_ source: String) {
    #expect(Self.flipsTheExecutor(source))
  }

  @Test(arguments: [
    "/// Drives it through a `TestStore`, as TestStore(initialState:) does.",
    "let store = Store(initialState: State()) { Feature() }",
    "#expect(uncheckedUseMainSerialExecutor == false)",
  ])
  func whatFlipsNothingIsNotSeen(_ source: String) {
    #expect(!Self.flipsTheExecutor(source))
  }
}
