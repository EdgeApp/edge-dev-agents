import XCTest

/// The single test the runner bundle holds: interpret the flow named by
/// `EDGE_FLOW_FILE` (JSON written by scripts/maestro-yaml-to-json.rb). With
/// `EDGE_INSPECT` set to `compact` or `full` it prints the screen's elements
/// after the last step, and also after a failed one.
final class FlowRunnerTests: XCTestCase {
  private var recordedIssue = false

  override func setUp() {
    continueAfterFailure = false
  }

  func testFlow() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["EDGE_FLOW_FILE"], !path.isEmpty else {
      XCTFail("EDGE_FLOW_FILE is not set (pass TEST_RUNNER_EDGE_FLOW_FILE to xcodebuild)")
      return
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      XCTFail("\(path) is not a flow JSON object")
      return
    }
    let flowName = ((document["file"] as? String) ?? path as String) as NSString

    let problems = FlowPreflight.problems(in: document)
    if !problems.isEmpty {
      let list = problems.map { "  - \($0)" }.joined(separator: "\n")
      print("[edge-flow] PREFLIGHT FAILED for \(flowName.lastPathComponent):\n\(list)")
      XCTFail("\(flowName.lastPathComponent) uses commands the interpreter does not support:\n\(list)")
      return
    }

    let options = RunOptions(environment: environment)
    EdgeQuiescence.install()
    print("[edge-flow] start \(flowName.lastPathComponent) cap=\(options.quiescenceCap)s animations=\(options.animations)")
    let started = Date()
    let interpreter = FlowInterpreter(options: options)
    var failure: Error?
    do {
      try interpreter.run(document)
    } catch {
      failure = error
    }
    if let mode = environment["EDGE_INSPECT"], !mode.isEmpty {
      do {
        try interpreter.inspectScreen(full: mode == "full")
      } catch {
        print("[edge-flow] inspect failed: \(error)")
        failure = failure ?? error
      }
    }
    if let failure = failure {
      print(String(format: "[edge-flow] FAILED %@ after %.2fs: %@", flowName.lastPathComponent, Date().timeIntervalSince(started), "\(failure)"))
      XCTFail("\(failure)")
    } else {
      print(String(format: "[edge-flow] PASSED %@ in %.2fs", flowName.lastPathComponent, Date().timeIntervalSince(started)))
    }
    printCapHits()
  }

  override func record(_ issue: XCTIssue) {
    recordedIssue = true
    super.record(issue)
  }

  override func tearDown() {
    // XCUI API failures (e.g. a tap on a vanished element) record an XCTest
    // failure without throwing, so name the step that was running.
    // testRun.hasSucceeded is not final yet inside tearDown, so track issues.
    if recordedIssue, !EdgeQuiescence.currentStep.isEmpty {
      print("[edge-flow] last step: \(EdgeQuiescence.currentStep)")
    }
  }

  /// Each hit was already logged with its step as it happened.
  private func printCapHits() {
    print("[edge-flow] quiescence cap hits: \(EdgeQuiescence.capHits)")
  }
}
