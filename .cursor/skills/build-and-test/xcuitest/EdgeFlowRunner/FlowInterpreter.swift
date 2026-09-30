import Foundation
import XCTest

/// Run-wide settings, read from the runner's environment (xcodebuild passes
/// `TEST_RUNNER_<NAME>` through as `<NAME>`).
struct RunOptions {
  var quiescenceCap: TimeInterval = 1
  /// `off` or `fast` is passed to the app as `-EdgeTestAnimations <mode>` on
  /// launchApp; `on` passes nothing.
  var animations = "off"
  /// Maestro's defaults: 17s element lookup, 7s for optional lookups and
  /// `when:` conditions.
  var lookupTimeout: TimeInterval = 17
  var optionalLookupTimeout: TimeInterval = 7
  var workingDirectory = FileManager.default.currentDirectoryPath

  init(environment: [String: String]) {
    if let cap = environment["EDGE_QUIESCENCE_CAP"].flatMap(Double.init) { quiescenceCap = cap }
    if let mode = environment["EDGE_TEST_ANIMATIONS"], !mode.isEmpty { animations = mode }
    if let ms = environment["EDGE_LOOKUP_MS"].flatMap(Double.init) { lookupTimeout = ms / 1000 }
    if let ms = environment["EDGE_OPTIONAL_LOOKUP_MS"].flatMap(Double.init) { optionalLookupTimeout = ms / 1000 }
    if let cwd = environment["EDGE_FLOW_CWD"], !cwd.isEmpty { workingDirectory = cwd }
  }
}

/// Element selector: Maestro `text` and `id` are case-insensitive regexes
/// (dot matches newline) that must match the whole attribute, or equal it
/// literally. `text` is checked against label, value and placeholderValue.
struct Selector: CustomStringConvertible {
  var text: String?
  var id: String?
  var index: Int?

  var description: String {
    var parts: [String] = []
    if let text = text { parts.append("text=\"\(text)\"") }
    if let id = id { parts.append("id=\"\(id)\"") }
    if let index = index { parts.append("index=\(index)") }
    return parts.joined(separator: " ")
  }
}

final class FlowInterpreter {
  private let options: RunOptions
  private let script = FlowScript()
  private var appId = "co.edgesecure.app"
  private var app = XCUIApplication(bundleIdentifier: "co.edgesecure.app")
  private var screenBounds: CGRect?
  private var lastInteraction = Date()
  private let started = Date()

  init(options: RunOptions) {
    self.options = options
    EdgeQuiescence.cap = options.quiescenceCap
  }

  // MARK: Flows

  func run(_ document: [String: Any]) throws {
    let cliEnv = (document["env"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
    for (key, value) in cliEnv { script.set(key, value) }
    try runFlow(document, callerEnv: [], skipHeaderKeys: Set(cliEnv.keys))
  }

  /// Runs one flow document in its own env scope. Caller env applies first
  /// and the flow's header `env:` is evaluated after it, which is Maestro
  /// 2.x behavior (a subflow's header shadows the caller's value, hence the
  /// `KEY: ${KEY || default}` idiom in the library flows).
  private func runFlow(_ flow: [String: Any], callerEnv: [(String, String)], skipHeaderKeys: Set<String> = []) throws {
    let flowName = ((flow["file"] as? String).map { ($0 as NSString).lastPathComponent }) ?? "<flow>"
    let config = flow["config"] as? [String: Any] ?? [:]
    let scope = EnvScope(script)
    let previousCap = EdgeQuiescence.cap
    defer {
      scope.restore()
      EdgeQuiescence.cap = previousCap
    }
    for (key, value) in callerEnv { scope.set(key, value) }
    for pair in config["env"] as? [[Any]] ?? [] {
      guard pair.count == 2, let key = pair[0] as? String else { continue }
      if skipHeaderKeys.contains(key) { continue }
      if !script.isDefined(key) { scope.declare(key) }
      scope.set(key, try script.interpolate("\(pair[1])"))
    }
    if let cap = script.value("EDGE_QUIESCENCE_CAP")?.toString().flatMap(Double.init) {
      EdgeQuiescence.cap = cap
    }
    if let appId = config["appId"] as? String {
      let bundleId = try script.interpolate(appId)
      if bundleId != appId { selectApp(bundleId) }
    }
    try runCommands(flow["commands"] as? [Any] ?? [], flowName: flowName)
  }

  private func runCommands(_ commands: [Any], flowName: String) throws {
    for (offset, command) in commands.enumerated() {
      try execute(command, at: "\(flowName) #\(offset + 1)")
    }
  }

  private func execute(_ command: Any, at: String) throws {
    let name: String
    let args: Any?
    if let bare = command as? String {
      name = bare
      args = nil
    } else if let map = command as? [String: Any], let entry = map.first {
      name = entry.key
      args = entry.value is NSNull ? nil : entry.value
    } else {
      throw FlowError("\(at): malformed command")
    }
    let map = args as? [String: Any]
    let optional = map?["optional"] as? Bool ?? false
    let step = "\(at) \(name) \(summary(args))"
    EdgeQuiescence.currentStep = step
    let begin = Date()
    do {
      let note = try dispatch(name, args, optional: optional)
      log(step, begin, note ?? "ok")
    } catch let error as FlowError where optional {
      log(step, begin, "skipped (optional): \(error)")
    } catch {
      log(step, begin, "FAILED: \(error)")
      throw FlowError("\(step): \(error)")
    }
  }

  // MARK: Commands

  private func dispatch(_ name: String, _ args: Any?, optional: Bool) throws -> String? {
    let map = args as? [String: Any] ?? [:]
    switch name {
    case "launchApp":
      if let appId = map["appId"] as? String { selectApp(try script.interpolate(appId)) }
      if map["stopApp"] as? Bool == false, app.state == .runningForeground || app.state == .runningBackground {
        app.activate()
      } else {
        app.launchArguments = options.animations == "on" ? [] : ["-EdgeTestAnimations", options.animations]
        app.launch()
      }
      screenBounds = nil
      interacted()
    case "stopApp":
      if let appId = map["appId"] as? String { selectApp(try script.interpolate(appId)) }
      app.terminate()
      interacted()
    case "tapOn":
      let selector = try parseSelector(args)
      let timeout = optional ? options.optionalLookupTimeout : options.lookupTimeout
      guard let frame = try waitForElement(selector, timeout: timeout) else {
        throw FlowError("element not found: \(selector)")
      }
      let before = map["retryTapIfNoChange"] as? Bool == true ? screenPixels() : nil
      tap(frame)
      if let before = before, screenPixels() == before { tap(frame) }
      if let ms = try optionalNumber(map["waitToSettleTimeoutMs"]) { waitForSettle(timeout: ms / 1000) }
    case "assertVisible":
      let selector = try parseSelector(args)
      let timeout = adjusted(optional ? options.optionalLookupTimeout : options.lookupTimeout)
      if try waitForElement(selector, timeout: timeout) == nil {
        throw FlowError("assertion failed: \(selector) is not visible")
      }
    case "assertNotVisible":
      let selector = try parseSelector(args)
      let timeout = adjusted(optional ? options.optionalLookupTimeout : options.lookupTimeout)
      if try !waitForAbsence(selector, timeout: timeout) {
        throw FlowError("assertion failed: \(selector) is still visible")
      }
    case "extendedWaitUntil":
      let timeout = (try optionalNumber(map["timeout"]) ?? 17000) / 1000
      if let visible = map["visible"] {
        let selector = try parseSelector(visible)
        if try waitForElement(selector, timeout: timeout) == nil {
          throw FlowError("\(selector) not visible after \(timeout)s")
        }
      }
      if let hidden = map["notVisible"] {
        let selector = try parseSelector(hidden)
        if try !waitForAbsence(selector, timeout: timeout) {
          throw FlowError("\(selector) still visible after \(timeout)s")
        }
      }
    case "runFlow":
      if let when = map["when"], try !evaluateCondition(when) { return "skipped (condition false)" }
      let env = try envPairs(map["env"])
      if let flow = map["_flow"] as? [String: Any] {
        try runFlow(flow, callerEnv: env)
      } else if let commands = map["commands"] as? [Any] {
        try runFlow(["file": "inline", "commands": commands], callerEnv: env)
      }
    case "inputText":
      let text = try script.interpolate(stringArg(args, key: "text"))
      try typeKeys(text)
    case "eraseText":
      let count = Int(try optionalNumber(map.isEmpty ? args : map["charactersToErase"]) ?? 50)
      try typeKeys(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    case "pressKey":
      let key = try script.interpolate(stringArg(args, key: "key")).lowercased()
      switch key {
      case "enter": try typeKeys(XCUIKeyboardKey.return.rawValue)
      case "backspace": try typeKeys(XCUIKeyboardKey.delete.rawValue)
      case "home":
        XCUIDevice.shared.press(.home)
        interacted()
      default: throw FlowError("unsupported pressKey '\(key)'")
      }
    case "scroll":
      let bounds = screen()
      drag(from: CGPoint(x: bounds.midX, y: bounds.height * 0.7), to: CGPoint(x: bounds.midX, y: bounds.height * 0.3), duration: 0.4)
    case "scrollUntilVisible":
      return try scrollUntilVisible(map)
    case "swipe":
      try swipe(map)
    case "repeat":
      let times = try optionalNumber(map["times"]).map { Int($0) }
      var count = 0
      while times.map({ count < $0 }) ?? true {
        if let condition = map["while"], try !evaluateCondition(condition) { break }
        try runFlow(["file": "repeat", "commands": map["commands"] as? [Any] ?? []], callerEnv: [])
        count += 1
      }
      return "ran \(count)x"
    case "retry":
      let retries = Int(try optionalNumber(map["maxRetries"]) ?? 1)
      var attempt = 0
      while true {
        do {
          if let flow = map["_flow"] as? [String: Any] {
            try runFlow(flow, callerEnv: [])
          } else {
            try runFlow(["file": "retry", "commands": map["commands"] as? [Any] ?? []], callerEnv: [])
          }
          return attempt == 0 ? nil : "passed on retry \(attempt)"
        } catch {
          attempt += 1
          if attempt > retries { throw error }
          print("[edge-flow] retry \(attempt)/\(retries) after: \(error)")
        }
      }
    case "evalScript":
      let source = try stringArg(args, key: "script").trimmingCharacters(in: .whitespaces)
      if source.hasPrefix("${"), source.hasSuffix("}") {
        _ = try script.evaluate(String(source.dropFirst(2).dropLast()))
      } else {
        _ = try script.evaluate(source)
      }
    case "waitForAnimationToEnd":
      let timeout = (try optionalNumber(map["timeout"]) ?? 15000) / 1000
      if !waitForSettle(timeout: timeout) { return "still animating after \(timeout)s, continuing" }
    case "takeScreenshot":
      var path = try script.interpolate(stringArg(args, key: "path"))
      if !path.hasPrefix("/") { path = (options.workingDirectory as NSString).appendingPathComponent(path) }
      if !path.hasSuffix(".png") { path += ".png" }
      try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
      return "saved \(path)"
    default:
      throw FlowError("unsupported command '\(name)'")
    }
    return nil
  }

  private func scrollUntilVisible(_ map: [String: Any]) throws -> String? {
    guard let element = map["element"] else { throw FlowError("scrollUntilVisible needs element") }
    let selector = try parseSelector(element)
    let direction = try script.interpolate("\(map["direction"] ?? "DOWN")").uppercased()
    let timeout = (try optionalNumber(map["timeout"]) ?? 20000) / 1000
    let percent = (try optionalNumber(map["visibilityPercentage"]) ?? 100) / 100
    let settle = (try optionalNumber(map["waitToSettleTimeoutMs"])).map { $0 / 1000 }
    let deadline = Date().addingTimeInterval(timeout)
    var swipes = 0
    while true {
      if let frame = try findElement(selector), visibleFraction(frame) >= percent {
        return swipes == 0 ? nil : "visible after \(swipes) swipe(s)"
      }
      if Date() >= deadline { throw FlowError("\(selector) not visible after scrolling \(timeout)s") }
      let bounds = screen()
      let (from, to): (CGPoint, CGPoint)
      switch direction {
      case "UP": (from, to) = (CGPoint(x: bounds.midX, y: bounds.height * 0.3), CGPoint(x: bounds.midX, y: bounds.height * 0.7))
      case "LEFT": (from, to) = (CGPoint(x: bounds.width * 0.3, y: bounds.midY), CGPoint(x: bounds.width * 0.7, y: bounds.midY))
      case "RIGHT": (from, to) = (CGPoint(x: bounds.width * 0.7, y: bounds.midY), CGPoint(x: bounds.width * 0.3, y: bounds.midY))
      default: (from, to) = (CGPoint(x: bounds.midX, y: bounds.height * 0.7), CGPoint(x: bounds.midX, y: bounds.height * 0.3))
      }
      drag(from: from, to: to, duration: 0.4)
      swipes += 1
      if let settle = settle { waitForSettle(timeout: settle) }
    }
  }

  private func swipe(_ map: [String: Any]) throws {
    let bounds = screen()
    let duration = (try optionalNumber(map["duration"]) ?? 400) / 1000
    if let start = map["start"], let end = map["end"] {
      drag(from: try point(start, in: bounds), to: try point(end, in: bounds), duration: duration)
      return
    }
    let direction = try script.interpolate("\(map["direction"] ?? "")").uppercased()
    var from = CGPoint(x: bounds.midX, y: bounds.midY)
    if let element = map["from"] {
      let selector = try parseSelector(element)
      guard let frame = try waitForElement(selector, timeout: options.lookupTimeout) else {
        throw FlowError("swipe origin not found: \(selector)")
      }
      from = CGPoint(x: frame.midX, y: frame.midY)
    }
    // Maestro swipes from the origin to the screen edge in the direction.
    let to: CGPoint
    switch direction {
    case "LEFT": to = CGPoint(x: bounds.width * 0.02, y: from.y)
    case "RIGHT": to = CGPoint(x: bounds.width * 0.98, y: from.y)
    case "UP": to = CGPoint(x: from.x, y: bounds.height * 0.1)
    case "DOWN": to = CGPoint(x: from.x, y: bounds.height * 0.9)
    default: throw FlowError("swipe needs direction LEFT, RIGHT, UP or DOWN (or start and end)")
    }
    drag(from: from, to: to, duration: duration)
    if let ms = try optionalNumber(map["waitToSettleTimeoutMs"]) { waitForSettle(timeout: ms / 1000) }
  }

  // MARK: Conditions

  /// Maestro evaluates `visible` / `notVisible` with the optional lookup
  /// timeout, reduced by the time since the last interaction.
  private func evaluateCondition(_ raw: Any) throws -> Bool {
    guard let condition = raw as? [String: Any] else { throw FlowError("condition must be a map") }
    if let platform = condition["platform"] {
      if try script.interpolate("\(platform)").lowercased() != "ios" { return false }
    }
    if let visible = condition["visible"] {
      let selector = try parseSelector(visible)
      if try waitForElement(selector, timeout: adjusted(options.optionalLookupTimeout)) == nil { return false }
    }
    if let hidden = condition["notVisible"] {
      let selector = try parseSelector(hidden)
      if try !waitForAbsence(selector, timeout: adjusted(options.optionalLookupTimeout)) { return false }
    }
    if let value = condition["true"] {
      let result = try script.interpolate("\(value)")
      let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || ["false", "undefined", "null", "0"].contains(trimmed.lowercased()) { return false }
    }
    return true
  }

  private func adjusted(_ timeout: TimeInterval) -> TimeInterval {
    max(0, timeout - Date().timeIntervalSince(lastInteraction))
  }

  // MARK: Elements

  private func parseSelector(_ raw: Any?) throws -> Selector {
    if let map = raw as? [String: Any] {
      var selector = Selector()
      if let text = map["text"] { selector.text = try script.interpolate("\(text)") }
      if let id = map["id"] { selector.id = try script.interpolate("\(id)") }
      if let index = try optionalNumber(map["index"]) { selector.index = Int(index) }
      if selector.text == nil, selector.id == nil { throw FlowError("selector needs text or id") }
      return selector
    }
    guard let raw = raw else { throw FlowError("missing selector") }
    return Selector(text: try script.interpolate("\(raw)"))
  }

  private func waitForElement(_ selector: Selector, timeout: TimeInterval) throws -> CGRect? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let frame = try findElement(selector) { return frame }
      if Date() >= deadline { return nil }
      Thread.sleep(forTimeInterval: 0.15)
    }
  }

  private func waitForAbsence(_ selector: Selector, timeout: TimeInterval) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if try findElement(selector) == nil { return true }
      if Date() >= deadline { return false }
      Thread.sleep(forTimeInterval: 0.15)
    }
  }

  /// Fast path: one query with `.firstMatch`. `firstMatch` returns the
  /// outermost match, and a container's label concatenates its children's
  /// text, so the fast path only holds when nothing inside it matches too.
  /// Otherwise (off screen, nested match, or an index) fall back to one
  /// hierarchy snapshot walked with Maestro's rules (deepest match only, on
  /// screen, ordered by position).
  private func findElement(_ selector: Selector) throws -> CGRect? {
    if selector.index == nil {
      let first = query(selector).firstMatch
      guard first.exists else { return nil }
      let frame = first.frame
      if visibleFraction(frame) > 0, !query(selector, in: first).firstMatch.exists { return frame }
    }
    let matches = try snapshotMatches(selector)
    let index = selector.index ?? 0
    return index < matches.count ? matches[index] : nil
  }

  private func query(_ selector: Selector, in root: XCUIElement? = nil) -> XCUIElementQuery {
    var query = (root ?? app).descendants(matching: .any)
    if let id = selector.id { query = query.matching(predicate(fields: ["identifier"], pattern: id)) }
    if let text = selector.text { query = query.matching(predicate(fields: ["label", "value", "placeholderValue"], pattern: text)) }
    return query
  }

  private func predicate(fields: [String], pattern: String) -> NSPredicate {
    var clauses: [String] = []
    var args: [Any] = []
    for field in fields {
      clauses.append("\(field) == %@")
      args.append(pattern)
    }
    if let regex = matchRegex(pattern) {
      for field in fields {
        clauses.append("\(field) MATCHES %@")
        args.append(regex.pattern)
      }
    }
    return NSPredicate(format: clauses.joined(separator: " OR "), argumentArray: args)
  }

  /// The whole-string, case-insensitive, dot-matches-newline regex Maestro
  /// builds from a selector (nil when the pattern is not a valid regex, in
  /// which case only literal equality can match).
  private func matchRegex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: "(?ism)" + pattern)
  }

  private func snapshotMatches(_ selector: Selector) throws -> [CGRect] {
    let textRegex = selector.text.flatMap(matchRegex)
    let idRegex = selector.id.flatMap(matchRegex)
    func fullMatch(_ regex: NSRegularExpression?, _ pattern: String, _ value: String?) -> Bool {
      guard let value = value, !value.isEmpty || pattern.isEmpty else { return false }
      for candidate in [value, value.replacingOccurrences(of: "\n", with: " ")] {
        if candidate == pattern { return true }
        if let regex = regex, let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
           match.range.location == 0, match.range.length == (candidate as NSString).length {
          return true
        }
      }
      return false
    }
    func matches(_ node: XCUIElementSnapshot) -> Bool {
      if let id = selector.id, !fullMatch(idRegex, id, node.identifier) { return false }
      if let text = selector.text {
        let values = [node.label, node.value as? String, node.placeholderValue]
        if !values.contains(where: { fullMatch(textRegex, text, $0) }) { return false }
      }
      return true
    }
    var found: [CGRect] = []
    // Returns whether the subtree holds a match; a node only counts when no
    // descendant matches (Maestro's deepestMatchingElement).
    func walk(_ node: XCUIElementSnapshot) -> Bool {
      var childMatched = false
      for child in node.children where walk(child) { childMatched = true }
      let isMatch = matches(node)
      if isMatch, !childMatched, visibleFraction(node.frame) > 0 { found.append(node.frame) }
      return isMatch || childMatched
    }
    _ = walk(try app.snapshot())
    return found.sorted { $0.minY != $1.minY ? $0.minY < $1.minY : $0.minX < $1.minX }
  }

  private func visibleFraction(_ frame: CGRect) -> CGFloat {
    guard frame.width > 0, frame.height > 0 else { return 0 }
    let overlap = frame.intersection(screen())
    if overlap.isNull { return 0 }
    return (overlap.width * overlap.height) / (frame.width * frame.height)
  }

  private func screen() -> CGRect {
    if let bounds = screenBounds, bounds.width > 0 { return bounds }
    let frame = app.frame
    screenBounds = frame
    return frame
  }

  private func selectApp(_ bundleId: String) {
    appId = bundleId
    app = XCUIApplication(bundleIdentifier: bundleId)
    screenBounds = nil
  }

  // MARK: Gestures

  private func coordinate(_ point: CGPoint) -> XCUICoordinate {
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
  }

  private func tap(_ frame: CGRect) {
    coordinate(CGPoint(x: frame.midX, y: frame.midY)).tap()
    interacted()
  }

  private func drag(from: CGPoint, to: CGPoint, duration: TimeInterval) {
    let distance = hypot(to.x - from.x, to.y - from.y)
    let velocity = XCUIGestureVelocity(rawValue: distance / CGFloat(max(duration, 0.05)))
    coordinate(from).press(forDuration: 0.05, thenDragTo: coordinate(to), withVelocity: velocity, thenHoldForDuration: 0.05)
    interacted()
  }

  /// Accepts "x%,y%" (screen-relative) or "x,y" (points).
  private func point(_ raw: Any, in bounds: CGRect) throws -> CGPoint {
    let text = try script.interpolate("\(raw)")
    let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2 else { throw FlowError("bad point '\(text)'") }
    func value(_ part: String, _ size: CGFloat) throws -> CGFloat {
      if part.hasSuffix("%"), let percent = Double(part.dropLast()) { return size * CGFloat(percent) / 100 }
      if let points = Double(part) { return CGFloat(points) }
      throw FlowError("bad point '\(text)'")
    }
    return CGPoint(x: try value(parts[0], bounds.width), y: try value(parts[1], bounds.height))
  }

  private func interacted() {
    lastInteraction = Date()
  }

  // MARK: Keyboard

  /// Types into the focused field. React Native can hide the focused input
  /// (Edge's PIN entry), so no element reports keyboard focus and `typeText`
  /// fails with the keyboard up. Maestro synthesizes key events regardless of
  /// focus; this falls back to tapping the on-screen keys instead.
  private func typeKeys(_ text: String) throws {
    let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
    if focused.exists {
      app.typeText(text)
      interacted()
      return
    }
    let keyboard = app.keyboards.firstMatch
    guard keyboard.exists else { throw FlowError("no element has keyboard focus and no keyboard is showing") }
    for character in text {
      let labels: [String]
      switch String(character) {
      case XCUIKeyboardKey.delete.rawValue: labels = ["delete"]
      case XCUIKeyboardKey.return.rawValue: labels = ["return", "done", "go", "search", "next", "send"]
      case " ": labels = ["space"]
      default: labels = [String(character)]
      }
      let match = labels.lazy.map { label in
        keyboard.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
      }.first { $0.exists }
      guard let key = match else {
        throw FlowError("no element has keyboard focus, and the keyboard has no '\(labels[0])' key to tap")
      }
      key.tap()
    }
    interacted()
  }

  // MARK: Screen settle

  private func screenPixels() -> Data? {
    guard let image = XCUIScreen.main.screenshot().image.cgImage else { return nil }
    return image.dataProvider?.data as Data?
  }

  /// Returns once two consecutive screenshots are identical (Maestro's
  /// waitForAnimationToEnd), or false at the timeout.
  @discardableResult
  private func waitForSettle(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var previous = screenPixels()
    while Date() < deadline {
      let current = screenPixels()
      if current != nil, current == previous { return true }
      previous = current
    }
    return false
  }

  // MARK: Arguments

  private func stringArg(_ args: Any?, key: String) throws -> String {
    if let map = args as? [String: Any] {
      guard let value = map[key] else { throw FlowError("missing '\(key)'") }
      return "\(value)"
    }
    guard let args = args else { throw FlowError("missing argument") }
    return "\(args)"
  }

  private func optionalNumber(_ raw: Any?) throws -> Double? {
    guard let raw = raw, !(raw is NSNull) else { return nil }
    if let number = raw as? NSNumber { return number.doubleValue }
    let text = try script.interpolate("\(raw)")
    guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
      throw FlowError("expected a number, got '\(text)'")
    }
    return value
  }

  private func envPairs(_ raw: Any?) throws -> [(String, String)] {
    guard let pairs = raw as? [[Any]] else { return [] }
    return try pairs.compactMap { pair in
      guard pair.count == 2, let key = pair[0] as? String else { return nil }
      return (key, try script.interpolate("\(pair[1])"))
    }
  }

  // MARK: Logging

  private func summary(_ args: Any?) -> String {
    guard let args = args else { return "" }
    var copy = args
    if var map = args as? [String: Any] {
      map["_flow"] = nil
      map["commands"] = (map["commands"] as? [Any]).map { "[\($0.count) commands]" }
      copy = map
    }
    let data = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? "\(copy)"
    return text.count > 100 ? String(text.prefix(97)) + "..." : text
  }

  private func log(_ step: String, _ begin: Date, _ note: String) {
    let total = Date().timeIntervalSince(started)
    let took = Date().timeIntervalSince(begin)
    print(String(format: "[edge-flow] %7.2fs (+%5.2fs) %@ -> %@", total, took, step, note))
  }
}
