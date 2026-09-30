import Foundation
import JavaScriptCore

/// JavaScript engine for `${...}` interpolation, `evalScript` and `when: true`.
///
/// Maestro evaluates these as JavaScript, and the library flows use real JS
/// (Math.random, JSON.parse, arrow functions, `||` defaults), so a hand-rolled
/// subset would have to guess. JavaScriptCore runs the exact expression; any
/// script error fails the step with the offending source.
final class FlowScript {
  private let context: JSContext
  private var lastException: String?

  init() {
    context = JSContext()
    context.exceptionHandler = { [weak self] _, exception in
      self?.lastException = exception?.toString() ?? "unknown JavaScript error"
    }
    context.evaluateScript("var output = {};")
  }

  /// Evaluates one JavaScript expression or statement.
  func evaluate(_ source: String) throws -> JSValue {
    lastException = nil
    let value = context.evaluateScript(source)
    if let error = lastException {
      throw FlowError("JavaScript error in `\(source)`: \(error)")
    }
    guard let value = value else { throw FlowError("JavaScript returned nothing for `\(source)`") }
    return value
  }

  /// Replaces every `${expr}` in the string with the expression's result
  /// (converted with JavaScript String()), the way Maestro does.
  func interpolate(_ text: String) throws -> String {
    guard text.contains("${") else { return text }
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      if text[index] == "$", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "{" {
        let start = text.index(index, offsetBy: 2)
        let end = try closingBrace(in: text, from: start)
        let value = try evaluate(String(text[start..<end]))
        result += value.toString() ?? "undefined"
        index = text.index(after: end)
      } else {
        result.append(text[index])
        index = text.index(after: index)
      }
    }
    return result
  }

  /// Finds the `}` that closes a `${`, skipping braces inside string literals.
  private func closingBrace(in text: String, from start: String.Index) throws -> String.Index {
    var depth = 0
    var quote: Character?
    var index = start
    while index < text.endIndex {
      let char = text[index]
      if let open = quote {
        if char == "\\" {
          index = text.index(after: index)
        } else if char == open {
          quote = nil
        }
      } else if char == "\"" || char == "'" || char == "`" {
        quote = char
      } else if char == "{" {
        depth += 1
      } else if char == "}" {
        if depth == 0 { return index }
        depth -= 1
      }
      if index < text.endIndex { index = text.index(after: index) }
    }
    throw FlowError("unterminated ${ in `\(text)`")
  }

  func isDefined(_ name: String) -> Bool {
    context.globalObject.hasProperty(name)
  }

  func value(_ name: String) -> JSValue? {
    isDefined(name) ? context.globalObject.forProperty(name) : nil
  }

  func set(_ name: String, _ value: Any?) {
    context.globalObject.setValue(value ?? JSValue(undefinedIn: context) as Any, forProperty: name)
  }

  func remove(_ name: String) {
    context.globalObject.deleteProperty(name)
  }

  /// Declares a name as `undefined` when nothing defines it yet, so a flow's
  /// own `KEY: ${KEY || default}` header can read it without a ReferenceError.
  func declare(_ name: String) {
    if !isDefined(name) { set(name, nil) }
  }
}

/// Saves and restores the variables a flow scope overrides (runFlow `env:`
/// and the subflow's own header `env:`), so they do not leak to the caller.
final class EnvScope {
  private var saved: [(String, JSValue?)] = []
  private let script: FlowScript

  init(_ script: FlowScript) {
    self.script = script
  }

  func set(_ name: String, _ value: String) {
    save(name)
    script.set(name, value)
  }

  /// Declares `name` as undefined for this scope (removed again on restore).
  func declare(_ name: String) {
    save(name)
    script.declare(name)
  }

  private func save(_ name: String) {
    if !saved.contains(where: { $0.0 == name }) {
      saved.append((name, script.value(name)))
    }
  }

  func restore() {
    for (name, value) in saved.reversed() {
      if let value = value {
        script.set(name, value)
      } else {
        script.remove(name)
      }
    }
    saved = []
  }
}

struct FlowError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
