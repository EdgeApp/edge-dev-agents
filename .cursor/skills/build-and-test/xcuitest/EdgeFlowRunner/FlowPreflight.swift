import Foundation

/// Walks a converted flow (and every nested/inlined subflow) before any step
/// runs, and reports each command or argument the interpreter does not
/// implement. The run fails on any report: there is no Maestro fallback.
enum FlowPreflight {
  static let common: Set<String> = ["label", "optional"]
  static let selectorKeys: Set<String> = ["text", "id", "index"]
  static let conditionKeys: Set<String> = ["visible", "notVisible", "true", "platform"]
  static let configKeys: Set<String> = ["appId", "env", "name", "tags", "jsEngine"]
  static let pressKeys: Set<String> = ["enter", "backspace", "home"]

  /// Argument keys each command accepts in map form (plus `common`).
  static let commandKeys: [String: Set<String>] = [
    "launchApp": ["appId", "clearState", "stopApp"],
    "stopApp": ["appId"],
    "tapOn": selectorKeys.union(["waitToSettleTimeoutMs", "retryTapIfNoChange"]),
    "assertVisible": selectorKeys,
    "assertNotVisible": selectorKeys,
    "extendedWaitUntil": ["visible", "notVisible", "timeout"],
    "runFlow": ["file", "_flow", "when", "env", "commands"],
    "inputText": ["text"],
    "eraseText": ["charactersToErase"],
    "pressKey": ["key"],
    "scroll": [],
    "scrollUntilVisible": ["element", "direction", "timeout", "visibilityPercentage", "speed", "waitToSettleTimeoutMs"],
    "swipe": ["from", "direction", "duration", "start", "end", "waitToSettleTimeoutMs"],
    "repeat": ["times", "while", "commands"],
    "retry": ["maxRetries", "commands", "file", "_flow"],
    "evalScript": ["script"],
    "waitForAnimationToEnd": ["timeout"],
    "takeScreenshot": ["path"]
  ]

  /// Commands that may be written as a bare name or with a scalar argument.
  static let scalarForms: Set<String> = [
    "launchApp", "stopApp", "tapOn", "assertVisible", "assertNotVisible", "inputText", "eraseText",
    "pressKey", "scroll", "evalScript", "waitForAnimationToEnd", "takeScreenshot"
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

  private static func checkKey(_ key: String, at: String, into found: inout [String]) {
    if !key.contains("${"), !pressKeys.contains(key.lowercased()) {
      found.append("\(at): unsupported pressKey '\(key)'")
    }
  }
}
