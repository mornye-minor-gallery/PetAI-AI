import Foundation
import JavaScriptCore

/// Explicit inputs for the supported legacy macro subset. No browser globals or callbacks are exposed.
/// Rolls are in [0, 1). Picks persist by original input and evaluated UTF-16 position, consuming one
/// injected roll on first use. This is deterministic replay, not SillyTavern's seedrandom algorithm.
public struct WorldInfoTextContext: Codable, Equatable, Sendable {
    public var user: String
    public var char: String
    public var description: String
    public var personality: String
    public var scenario: String
    public var persona: String
    public var localVariables: [String: String]
    public var globalVariables: [String: String]
    public var outlets: [String: String]
    public var randomRolls: [Double]
    public var randomIndex: Int
    public var picks: [String: String]

    public init(user: String = "", char: String = "", description: String = "", personality: String = "",
                scenario: String = "", persona: String = "", localVariables: [String: String] = [:],
                globalVariables: [String: String] = [:], outlets: [String: String] = [:],
                randomRolls: [Double] = [], randomIndex: Int = 0, picks: [String: String] = [:]) {
        self.user = user; self.char = char; self.description = description
        self.personality = personality; self.scenario = scenario; self.persona = persona
        self.localVariables = localVariables; self.globalVariables = globalVariables; self.outlets = outlets
        self.randomRolls = randomRolls; self.randomIndex = randomIndex; self.picks = picks
    }
}

public enum WorldInfoTextError: Error, Equatable, Sendable {
    case unsupportedMacro(String)
    case invalidMacro(String)
    case randomSourceExhausted
    case invalidRandomRoll
    case javascript(String)
}

/// Source: SillyTavern 06bde939, world-info.js parseRegexFromString, regex/engine.js,
/// utils.js regexFromString, macros.js evaluateMacros and variables.js getVariableMacros.
/// Only flat legacy name/card/variable/outlet/random/pick and newline/trim/noop macros are supported.
/// Nested/scoped macros, time, roll, instruct, custom extensions and the experimental engine fail.
/// Each call owns its JS context; native objects, networking and arbitrary evaluation are unavailable.
/// JavaScriptCore execution is synchronous; a Swift task timeout is not a regex interruption mechanism.
public enum WorldInfoText {
    /// Evaluates supported legacy passes. State commits only on complete success, unlike the browser's
    /// partially committed state on a failing macro. Callers must persist the returned context explicitly.
    public static func expand(_ text: String, context: inout WorldInfoTextContext) throws -> String {
        let encoded = try JSONEncoder().encode(context)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw WorldInfoTextError.javascript("Context is not UTF-8")
        }
        let result = try invoke("expand", arguments: [text, json])
        guard let value = result.text, let next = result.context else {
            throw WorldInfoTextError.javascript("Missing expansion result")
        }
        context = next
        return value
    }

    /// nil means upstream rejected regex syntax; the caller should use plaintext matching.
    public static func matchesRegex(_ key: String, text: String) throws -> Bool? {
        try invoke("matches", arguments: [key, text]).matched
    }

    /// The extension's separate parser accepts bare patterns. Invalid patterns preserve the input,
    /// exactly as runRegexScript does. Capture replacement only: macro expansion and trimStrings
    /// require the caller's explicit text context and are deliberately separate operations.
    public static func replace(_ text: String, pattern: String, replacement: String) throws -> String {
        guard let result = try invoke("replace", arguments: [text, pattern, replacement]).text else {
            throw WorldInfoTextError.javascript("Missing replacement result")
        }
        return result
    }

    /// Expands macros only in each replacement callback, after capture substitution. Unmatched
    /// input is untouched. Matches share sequential state; a failure rolls back the entire call.
    public static func replace(_ text: String, pattern: String, replacement: String,
                               context: inout WorldInfoTextContext) throws -> String {
        let encoded = try JSONEncoder().encode(context)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw WorldInfoTextError.javascript("Context is not UTF-8")
        }
        let result = try invoke("replaceExpanded", arguments: [text, pattern, replacement, json])
        guard let value = result.text, let next = result.context else {
            throw WorldInfoTextError.javascript("Missing replacement context")
        }
        context = next
        return value
    }

    private struct Result: Decodable {
        struct Failure: Decodable { var kind: String; var detail: String? }
        var text: String?
        var matched: Bool?
        var context: WorldInfoTextContext?
        var error: Failure?
    }

    private static func invoke(_ operation: String, arguments: [String]) throws -> Result {
        guard let context = JSContext() else { throw WorldInfoTextError.javascript("Cannot create JSContext") }
        context.evaluateScript(source)
        if let exception = context.exception { throw WorldInfoTextError.javascript(exception.toString()) }
        guard let function = context.objectForKeyedSubscript("worldInfoText"),
              let json = function.call(withArguments: [operation, arguments])?.toString() else {
            throw WorldInfoTextError.javascript("Missing JavaScript bridge result")
        }
        if let exception = context.exception { throw WorldInfoTextError.javascript(exception.toString()) }
        let result = try JSONDecoder().decode(Result.self, from: Data(json.utf8))
        if let error = result.error {
            switch error.kind {
            case "unsupported": throw WorldInfoTextError.unsupportedMacro(error.detail ?? "")
            case "invalid": throw WorldInfoTextError.invalidMacro(error.detail ?? "")
            case "exhausted": throw WorldInfoTextError.randomSourceExhausted
            case "roll": throw WorldInfoTextError.invalidRandomRoll
            default: throw WorldInfoTextError.javascript(error.detail ?? error.kind)
            }
        }
        return result
    }

    // Kept in JavaScript to preserve UTF-16, capture semantics, Number conversion and upstream's
    // deliberately distinct regex parsers. User data crosses the JSValue argument bridge, never source.
    private static let source = #"""
    function worldInfoText(operation, args) {
      const fail = (kind, detail = '') => { throw {kind, detail}; };
      const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
      function keyRegex(input) {
        const match = input.match(/^\/([\w\W]+?)\/([gimsuy]*)$/);
        if (!match) return null;
        let [, pattern, flags] = match;
        if (pattern.match(/(^|[^\\])\//)) return null;
        pattern = pattern.replace('\\/', '/');
        try { return new RegExp(pattern, flags); } catch (_) { return null; }
      }
      function scriptRegex(input) {
        try {
          const m = input.match(/(\/?)(.+)\1([a-z]*)/i);
          if (m[3] && !/^(?!.*?(.).*?\1)[gmixXsuUAJ]+$/.test(m[3])) return RegExp(input);
          return new RegExp(m[2], m[3]);
        } catch (_) { return null; }
      }
      function replace(text, pattern, replacement, context) {
        const regex = scriptRegex(pattern);
        if (!regex) return text;
        return text.replace(regex, function () {
          const captures = [...arguments];
          const replaced = replacement.replace(/{{match}}/gi, '$0').replace(/\$(\d+)|\$<([^>]+)>/g,
            (_, number, name) => {
              const groups = captures[captures.length - 1];
              const value = number ? captures[Number(number)]
                : groups && typeof groups === 'object' && groups[name];
              return value || '';
            });
          return context ? expand(replaced, context).text : replaced;
        });
      }
      function expand(raw, context) {
        let text = raw;
        // The legacy engine does not parse nested blocks. Reject instead of pretending to evaluate them.
        if (/{{(?:(?!}})[\s\S])*{{/.test(text)) fail('unsupported', 'nested macro');
        const dict = value => Object.assign(Object.create(null), value);
        context.localVariables = dict(context.localVariables);
        context.globalVariables = dict(context.globalVariables);
        context.outlets = dict(context.outlets);
        context.picks = dict(context.picks);
        function get(variables, name) {
          const value = own(variables, name) ? variables[name] : '';
          return value.trim() === '' || isNaN(Number(value)) ? value : Number(value);
        }
        function set(variables, name, value) {
          if (!name) fail('invalid', 'empty variable name');
          variables[name] = String(value);
        }
        function add(variables, name, value) {
          const current = get(variables, name) || 0;
          let parsed;
          try { parsed = JSON.parse(current); } catch (_) { /* Plain values are not JSON arrays. */ }
          if (Array.isArray(parsed)) {
            parsed.push(value);
            set(variables, name, JSON.stringify(parsed));
            return String(parsed);
          }
          const increment = Number(value);
          if (isNaN(increment) || isNaN(Number(current))) {
            const result = String(current || '') + value;
            set(variables, name, result);
            return result;
          }
          const result = Number(current) + increment;
          if (isNaN(result)) return '';
          set(variables, name, result);
          return String(result);
        }
        text = text.replace(/<USER>/gi, () => context.user)
          .replace(/<(?:BOT|CHAR)>/gi, () => context.char);
        // getVariableMacros order, not lexical macro order: setters, additions, increments,
        // decrements, then getters, with the local family preceding the global family.
        for (const global of [false, true]) {
          const variables = global ? context.globalVariables : context.localVariables;
          const suffix = global ? 'globalvar' : 'var';
          text = text.replace(new RegExp('{{set' + suffix + '::([^:]+)::([^}]*)}}', 'gi'),
            (_, name, value) => { set(variables, name.trim(), value); return ''; });
          text = text.replace(new RegExp('{{add' + suffix + '::([^:]+)::([^}]+)}}', 'gi'),
            (_, name, value) => { add(variables, name.trim(), value); return ''; });
          text = text.replace(new RegExp('{{inc' + suffix + '::([^}]+)}}', 'gi'),
            (_, name) => add(variables, name.trim(), 1));
          text = text.replace(new RegExp('{{dec' + suffix + '::([^}]+)}}', 'gi'),
            (_, name) => add(variables, name.trim(), -1));
          text = text.replace(new RegExp('{{get' + suffix + '::([^}]+)}}', 'gi'),
            (_, name) => String(get(variables, name.trim())));
        }
        text = text.replace(/{{newline}}/gi, '\n')
          .replace(/(?:\r?\n)*{{trim}}(?:\r?\n)*/gi, '').replace(/{{noop}}/gi, '');
        for (const name of ['description', 'personality', 'scenario', 'persona', 'user', 'char']) {
          text = text.replace(new RegExp('{{' + name + '}}', 'gi'), () => context[name]);
        }
        text = text.replace(/{{outlet::(.+?)}}/gi, (_, key) => context.outlets[key.trim()] || '');
        function roll() {
          if (!Number.isInteger(context.randomIndex) || context.randomIndex < 0) fail('roll');
          if (context.randomIndex >= context.randomRolls.length) fail('exhausted');
          const value = context.randomRolls[context.randomIndex++];
          if (!Number.isFinite(value) || value < 0 || value >= 1) fail('roll');
          return value;
        }
        function choices(value) {
          return value.includes('::') ? value.split('::') : value.replace(/\\,/g, '\u0000')
            .split(',').map(item => item.trim().replace(/\u0000/g, ','));
        }
        text = text.replace(/{{random\s?::?([^}]+)}}/gi, (_, values) => {
          const list = choices(values);
          return list[Math.floor(roll() * list.length)];
        });
        text = text.replace(/{{pick\s?::?([^}]+)}}/gi, (_, values, offset) => {
          const key = JSON.stringify([raw, offset, values]);
          if (!own(context.picks, key)) {
            const list = choices(values);
            context.picks[key] = list[Math.floor(roll() * list.length)];
          }
          return context.picks[key];
        });
        const unresolved = text.match(/{{[\s\S]*?(?:}}|$)/);
        if (unresolved) fail('unsupported', unresolved[0]);
        return {text, context};
      }
      try {
        switch (operation) {
          case 'matches': {
            const regex = keyRegex(args[0]);
            return JSON.stringify({matched: regex ? regex.test(args[1]) : null});
          }
          case 'replace': return JSON.stringify({text: replace(...args)});
          case 'replaceExpanded': {
            const context = JSON.parse(args[3]);
            const text = replace(args[0], args[1], args[2], context);
            return JSON.stringify({text, context});
          }
          case 'expand': return JSON.stringify(expand(args[0], JSON.parse(args[1])));
          default: fail('operation', operation);
        }
      } catch (error) {
        return JSON.stringify({error: {kind: error.kind || 'javascript', detail: error.detail || String(error)}});
      }
    }
    """#
}
