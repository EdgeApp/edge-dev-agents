import Foundation

/// Walks a converted flow (and every nested/inlined subflow) before any step
/// runs, and reports each command or argument the interpreter does not
/// implement. The run fails on any report: there is no Maestro fallback.
enum FlowPreflight {
  static let common: Set<String> = ["label", "optional"]
  static let selectorKeys: Set<String> = ["text", "id", "index", "enabled"]
  static let conditionKeys: Set<String> = ["visible", "notVisible", "true", "platform"]
  static let configKeys: Set<String> = ["appId", "env", "name", "tags", "jsEngine"]
  static let tapKeys: Set<String> = ["point", "waitToSettleTimeoutMs", "retryTapIfNoChange"]
  static let pressKeys: Set<String> = ["enter", "backspace", "home", "back"]

  /// Argument keys each command accepts in map form (plus `common`).
  static let commandKeys: [String: Set<String>] = [
    "launchApp": ["appId", "clearState", "stopApp"],
    "stopApp": ["appId"],
    "openLink": ["link", "autoVerify", "browser"],
    "tapOn": selectorKeys.union(tapKeys),
    "longPressOn": selectorKeys.union(tapKeys),
    "copyTextFrom": selectorKeys,
    "pasteText": [],
    "inputRandomText": ["length"],
    "hideKeyboard": [],
    "back": [],
    "assertVisible": selectorKeys,
    "assertNotVisible": selectorKeys,
    "extendedWaitUntil": ["visible", "notVisible", "timeout"],
    "runFlow": ["file", "_flow", "when", "env", "commands"],
    "inputText": ["text"],
    "eraseText": ["charactersToErase"],
    "pressKey": ["key"],
    "scroll": [],
    "scrollUntilVisible": ["element", "direction", "timeout", "visibilityPercentage", "centerElement", "speed", "waitToSettleTimeoutMs"],
    "swipe": ["from", "direction", "duration", "start", "end", "waitToSettleTimeoutMs"],
    "repeat": ["times", "while", "commands"],
    "retry": ["maxRetries", "commands", "file", "_flow"],
    "evalScript": ["script"],
    "waitForAnimationToEnd": ["timeout"],
    "takeScreenshot": ["path"],
    "inspectScreen": ["full", "verify"]
  ]

  /// Commands that may be written as a bare name or with a scalar argument.
  static let scalarForms: Set<String> = [
    "launchApp", "stopApp", "openLink", "tapOn", "assertVisible", "assertNotVisible", "inputText", "eraseText",
    "pressKey", "scroll", "evalScript", "waitForAnimationToEnd", "takeScreenshot", "longPressOn",
    "copyTextFrom", "pasteText", "inputRandomText", "hideKeyboard", "back", "inspectScreen"
  ]

  static func problems(in flow: [String: Any]) -> [String] {
    var found: [String] = []
    check(flow: flow, into: &found)
    return found
  }

  private static func name(of flow: [String: Any]) -> String {
    ((flow["file"] as? String).map { ($0 as NSString).lastPathComponent }) ?? "<flow>"
  }

  private static func check(flow: [String: Any], into found: inout [String]) {
    let flowName = name(of: flow)
    let config = flow["config"] as? [String: Any] ?? [:]
    for key in config.keys.sorted() where !configKeys.contains(key) {
      found.append("\(flowName): unsupported flow config key '\(key)'")
    }
    let commands = flow["commands"] as? [Any] ?? []
    check(commands: commands, flowName: flowName, into: &found)
  }

  private static func check(commands: [Any], flowName: String, into found: inout [String]) {
    for (offset, command) in commands.enumerated() {
      let at = "\(flowName) #\(offset + 1)"
      let name: String
      let args: Any?
      if let bare = command as? String {
        name = bare
        args = nil
      } else if let map = command as? [String: Any], map.count == 1, let entry = map.first {
        name = entry.key
        args = entry.value is NSNull ? nil : entry.value
      } else {
        found.append("\(at): malformed command \(command)")
        continue
      }
      guard let allowed = commandKeys[name] else {
        found.append("\(at): unsupported command '\(name)'")
        continue
      }
      guard let map = args as? [String: Any] else {
        if !scalarForms.contains(name) {
          found.append("\(at): '\(name)' needs a map argument")
        }
        if name == "openLink", args == nil { found.append("\(at): openLink needs a link") }
        if name == "pressKey", let key = args as? String {
          checkKey(key, at: at, into: &found)
        }
        continue
      }
      for key in map.keys.sorted() where !allowed.contains(key) && !common.contains(key) {
        found.append("\(at): unsupported argument '\(key)' for \(name)")
      }
      checkArguments(name: name, map: map, at: at, flowName: flowName, into: &found)
    }
  }

  private static func checkArguments(name: String, map: [String: Any], at: String, flowName: String, into found: inout [String]) {
    switch name {
    case "launchApp":
      if let clear = map["clearState"] as? Bool, clear {
        found.append("\(at): launchApp clearState: true is unsupported (it would wipe the sim's roster accounts)")
      }
    case "openLink":
      if map["link"] == nil { found.append("\(at): openLink needs link") }
    case "tapOn", "longPressOn":
      if let point = map["point"] { checkPoint("\(point)", at: at, into: &found) }
      if map["point"] == nil, map["text"] == nil, map["id"] == nil {
        found.append("\(at): \(name) needs text, id or point")
      }
    case "extendedWaitUntil":
      for key in ["visible", "notVisible"] {
        if let selector = map[key] { checkSelector(selector, at: "\(at) \(key)", into: &found) }
      }
    case "scrollUntilVisible":
      if let selector = map["element"] { checkSelector(selector, at: "\(at) element", into: &found) }
    case "swipe":
      if let selector = map["from"] { checkSelector(selector, at: "\(at) from", into: &found) }
    case "pressKey":
      if let key = map["key"] as? String { checkKey(key, at: at, into: &found) }
    case "runFlow", "retry", "repeat":
      if let when = map["when"] { checkCondition(when, at: at, into: &found) }
      if let condition = map["while"] { checkCondition(condition, at: at, into: &found) }
      if let flow = map["_flow"] as? [String: Any] { check(flow: flow, into: &found) }
      if let commands = map["commands"] as? [Any] { check(commands: commands, flowName: flowName, into: &found) }
    default:
      break
    }
  }

  private static func checkSelector(_ selector: Any, at: String, into found: inout [String]) {
    guard let map = selector as? [String: Any] else { return }
    for key in map.keys.sorted() where !selectorKeys.contains(key) {
      found.append("\(at): unsupported selector key '\(key)'")
    }
  }

  private static func checkCondition(_ condition: Any, at: String, into found: inout [String]) {
    guard let map = condition as? [String: Any] else {
      found.append("\(at): condition must be a map")
      return
    }
    for key in map.keys.sorted() where !conditionKeys.contains(key) {
      found.append("\(at): unsupported condition key '\(key)'")
    }
    for key in ["visible", "notVisible"] {
      if let selector = map[key] { checkSelector(selector, at: "\(at) \(key)", into: &found) }
    }
  }

  /// "x%,y%" with both in 0...100, or "x,y" in points.
  private static func checkPoint(_ point: String, at: String, into found: inout [String]) {
    if point.contains("${") { return }
    let parts = point.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    let percent = point.contains("%")
    let valid = parts.count == 2 && parts.allSatisfy { part in
      guard part.hasSuffix("%") == percent, let value = Double(percent ? String(part.dropLast()) : part) else { return false }
      return value >= 0 && (!percent || value <= 100)
    }
    if !valid { found.append("\(at): bad point '\(point)' (want \"50%,80%\" or \"120,640\")") }
  }

  private static func checkKey(_ key: String, at: String, into found: inout [String]) {
    if !key.contains("${"), !pressKeys.contains(key.lowercased()) {
      found.append("\(at): unsupported pressKey '\(key)'")
    }
  }
}
