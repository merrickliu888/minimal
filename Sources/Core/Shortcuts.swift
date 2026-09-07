import Foundation

// MARK: - Modifiers

/// The modifiers a shortcut can require. Mirrors the AppKit and Carbon flags
/// without depending on either, so the config layer stays unit-testable.
struct ShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let command = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    /// Shift alone can't carry a shortcut — it is part of ordinary typing,
    /// and the overlay is a text field first.
    var hasNonShiftModifier: Bool {
        !intersection([.control, .option, .command]).isEmpty
    }

    /// Symbol order matches the hints Minimal has always shown (⌃`, ⌘⇧D).
    var display: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.command) { symbols += "⌘" }
        if contains(.shift) { symbols += "⇧" }
        return symbols
    }

    static func named(_ token: String) -> ShortcutModifiers? {
        switch token {
        case "cmd", "command", "⌘": return .command
        case "opt", "option", "alt", "⌥": return .option
        case "ctrl", "control", "⌃": return .control
        case "shift", "⇧": return .shift
        default: return nil
        }
    }
}

// MARK: - Shortcut

enum ShortcutParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case missingKey
    case multipleKeys(String, String)
    case unknownKey(String)

    var description: String {
        switch self {
        case .empty: return "empty shortcut"
        case .missingKey: return "no key, only modifiers"
        case .multipleKeys(let first, let second): return "two keys ('\(first)' and '\(second)')"
        case .unknownKey(let key): return "unknown key '\(key)'"
        }
    }
}

/// A key plus its modifiers, identified by virtual key code so it survives
/// keyboard-layout differences the same way the global hotkeys always have.
struct Shortcut: Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers

    init(_ keyCode: UInt16, _ modifiers: ShortcutModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// How the shortcut is spelled in the on-screen hints, e.g. "⌘⇧D".
    var display: String {
        modifiers.display + (Self.keysByCode[keyCode]?.display ?? "key \(keyCode)")
    }

    /// The character this key types unshifted on a US layout, when it types
    /// one. Used to also match the same key on other layouts.
    var character: Character? { Self.keysByCode[keyCode]?.character }

    /// Reads spellings like "cmd+shift+d", "⌥Space" or "ctrl+`".
    static func parse(_ text: String) throws -> Shortcut {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ShortcutParseError.empty }

        var modifiers: ShortcutModifiers = []
        var key: String?
        for rawToken in cleaned.split(separator: "+", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !token.isEmpty else { throw ShortcutParseError.unknownKey("+") }
            if let modifier = ShortcutModifiers.named(token) {
                modifiers.insert(modifier)
                continue
            }
            // Peel leading modifier symbols so "⌘⇧D" parses as one token.
            var remainder = Substring(token)
            while let first = remainder.first, let modifier = ShortcutModifiers.named(String(first)) {
                modifiers.insert(modifier)
                remainder = remainder.dropFirst()
            }
            guard !remainder.isEmpty else { continue }
            if let key { throw ShortcutParseError.multipleKeys(key, String(remainder)) }
            key = String(remainder)
        }

        guard let key else { throw ShortcutParseError.missingKey }
        guard let keyCode = Self.codesByName[key] else { throw ShortcutParseError.unknownKey(key) }
        return Shortcut(keyCode, modifiers)
    }
}

// MARK: - Key table

extension Shortcut {

    /// One physical key: the virtual key code AppKit reports in
    /// `NSEvent.keyCode` (and Carbon expects for global hotkeys), the
    /// spellings accepted in the config file, the character it types on a US
    /// layout, and how it is drawn in a hint.
    struct KeyDefinition {
        let code: UInt16
        let names: [String]
        let character: Character?
        let display: String

        init(_ code: UInt16, _ names: [String], character: Character? = nil, display: String? = nil) {
            self.code = code
            self.names = names
            self.character = character
            self.display = display ?? names[0].uppercased()
        }
    }

    static let keys: [KeyDefinition] = {
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5),
            ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45),
            ("o", 31), ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32),
            ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6),
        ]
        let digits: [(Character, UInt16)] = [
            ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ]
        var definitions: [KeyDefinition] = []
        for (character, code) in letters + digits {
            definitions.append(KeyDefinition(code, [String(character)], character: character))
        }
        definitions += [
            KeyDefinition(27, ["-", "minus"], character: "-", display: "-"),
            KeyDefinition(24, ["=", "equal"], character: "=", display: "="),
            KeyDefinition(33, ["[", "leftbracket"], character: "[", display: "["),
            KeyDefinition(30, ["]", "rightbracket"], character: "]", display: "]"),
            KeyDefinition(42, ["\\", "backslash"], character: "\\", display: "\\"),
            KeyDefinition(41, [";", "semicolon"], character: ";", display: ";"),
            KeyDefinition(39, ["'", "quote", "apostrophe"], character: "'", display: "'"),
            KeyDefinition(43, [",", "comma"], character: ",", display: ","),
            KeyDefinition(47, [".", "period", "dot"], character: ".", display: "."),
            KeyDefinition(44, ["/", "slash"], character: "/", display: "/"),
            KeyDefinition(50, ["`", "grave", "backtick"], character: "`", display: "`"),
            KeyDefinition(49, ["space"], character: " ", display: "Space"),
            KeyDefinition(48, ["tab"], display: "Tab"),
            KeyDefinition(36, ["return", "enter"], display: "⏎"),
            KeyDefinition(53, ["escape", "esc"], display: "⎋"),
            KeyDefinition(51, ["delete", "backspace"], display: "⌫"),
            KeyDefinition(117, ["forwarddelete", "forward_delete"], display: "⌦"),
            KeyDefinition(123, ["left", "leftarrow"], display: "←"),
            KeyDefinition(124, ["right", "rightarrow"], display: "→"),
            KeyDefinition(125, ["down", "downarrow"], display: "↓"),
            KeyDefinition(126, ["up", "uparrow"], display: "↑"),
            KeyDefinition(115, ["home"], display: "↖"),
            KeyDefinition(119, ["end"], display: "↘"),
            KeyDefinition(116, ["pageup", "page_up"], display: "⇞"),
            KeyDefinition(121, ["pagedown", "page_down"], display: "⇟"),
        ]
        let functionKeys: [(Int, UInt16)] = [
            (1, 122), (2, 120), (3, 99), (4, 118), (5, 96), (6, 97), (7, 98), (8, 100),
            (9, 101), (10, 109), (11, 103), (12, 111), (13, 105), (14, 107), (15, 113),
            (16, 106), (17, 64), (18, 79), (19, 80), (20, 90),
        ]
        for (number, code) in functionKeys {
            definitions.append(KeyDefinition(code, ["f\(number)"], display: "F\(number)"))
        }
        return definitions
    }()

    static let codesByName: [String: UInt16] = {
        var table: [String: UInt16] = [:]
        for key in Shortcut.keys {
            for name in key.names { table[name] = key.code }
        }
        return table
    }()

    static let keysByCode: [UInt16: KeyDefinition] = {
        var table: [UInt16: KeyDefinition] = [:]
        for key in Shortcut.keys { table[key.code] = key }
        return table
    }()
}

// MARK: - Actions

/// Every shortcut a user can rebind. The raw value is the key used under
/// `[shortcuts]` in config.toml.
enum ShortcutAction: String, CaseIterable {
    case newAgent = "new_agent"
    case manageAgents = "manage_agents"
    case settings = "settings"
    case voice = "voice"
    case projectPicker = "project_picker"
    case modelPicker = "model_picker"
    case toggleTerminal = "toggle_terminal"
    case toggleDiff = "toggle_diff"
    case stopAgent = "stop_agent"
    case allowPermission = "allow_permission"
    case denyPermission = "deny_permission"

    var defaultShortcut: Shortcut {
        switch self {
        case .newAgent: return Shortcut(49, [.option])           // ⌥Space
        case .manageAgents: return Shortcut(48, [.option])       // ⌥Tab
        case .settings: return Shortcut(43, [.command])          // ⌘,
        case .voice: return Shortcut(2, [.command])              // ⌘D
        case .projectPicker: return Shortcut(35, [.command])     // ⌘P
        case .modelPicker: return Shortcut(46, [.command])       // ⌘M
        case .toggleTerminal: return Shortcut(50, [.control])    // ⌃`
        case .toggleDiff: return Shortcut(2, [.command, .shift]) // ⌘⇧D
        case .stopAgent: return Shortcut(8, [.control])          // ⌃C
        case .allowPermission: return Shortcut(16, [.command])   // ⌘Y
        case .denyPermission: return Shortcut(45, [.command])    // ⌘N
        }
    }

    /// System-wide hotkeys, registered with Carbon rather than routed from
    /// the overlay's key monitor.
    var isGlobal: Bool { self == .newAgent || self == .manageAgents }

    var summary: String {
        switch self {
        case .newAgent: return "open the prompt"
        case .manageAgents: return "manage agents"
        case .settings: return "open settings"
        case .voice: return "voice prompt"
        case .projectPicker: return "pick project"
        case .modelPicker: return "pick model"
        case .toggleTerminal: return "toggle terminal"
        case .toggleDiff: return "toggle diff"
        case .stopAgent: return "stop the agent"
        case .allowPermission: return "allow a permission"
        case .denyPermission: return "deny a permission"
        }
    }
}

// MARK: - Config

/// The shortcut table the app runs on: defaults, overridden by whatever a
/// user's `config.toml` binds. Always complete — an action the file doesn't
/// mention, or binds badly, keeps its default.
struct ShortcutConfig {
    private(set) var bindings: [ShortcutAction: Shortcut]
    /// Problems found while loading, surfaced in Settings and the log.
    private(set) var warnings: [String] = []
    /// The file the overrides came from; nil when none was found.
    private(set) var source: URL?

    static let defaults = ShortcutConfig()

    init() {
        bindings = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    }

    subscript(action: ShortcutAction) -> Shortcut {
        bindings[action] ?? action.defaultShortcut
    }

    // MARK: Parsing

    static func parse(toml text: String, source: URL? = nil) -> ShortcutConfig {
        var config = ShortcutConfig()
        config.source = source
        let document: TOML.Document
        do {
            document = try TOML.parse(text)
        } catch {
            config.warnings.append("config is not valid TOML (\(error)); using default shortcuts")
            return config
        }

        for table in document.keys.sorted() where table != "shortcuts" {
            guard let entries = document[table], !entries.isEmpty else { continue }
            config.warnings.append(
                "ignoring unknown section '\(table.isEmpty ? "top level" : "[\(table)]")'")
        }

        for (name, value) in (document["shortcuts"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let action = ShortcutAction(rawValue: name) else {
                config.warnings.append("ignoring unknown shortcut '\(name)'")
                continue
            }
            let fallback = "keeping \(action.defaultShortcut.display)"
            do {
                let shortcut = try Shortcut.parse(value)
                guard shortcut.modifiers.hasNonShiftModifier else {
                    config.warnings.append(
                        "\(name) = \"\(value)\" needs a ⌘, ⌥ or ⌃ modifier; \(fallback)")
                    continue
                }
                config.bindings[action] = shortcut
            } catch {
                config.warnings.append("\(name) = \"\(value)\" is not a shortcut (\(error)); \(fallback)")
            }
        }

        let conflicts = config.conflictWarnings()
        config.warnings.append(contentsOf: conflicts)
        return config
    }

    /// Two actions on one shortcut isn't fatal — key routing picks the first
    /// match — but it is never what the user meant, so say so.
    private func conflictWarnings() -> [String] {
        var order: [Shortcut] = []
        var actions: [Shortcut: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            let shortcut = self[action]
            if actions[shortcut] == nil { order.append(shortcut) }
            actions[shortcut, default: []].append(action)
        }
        return order.compactMap { shortcut in
            guard let bound = actions[shortcut], bound.count > 1 else { return nil }
            let names = bound.map(\.rawValue).joined(separator: " and ")
            return "\(shortcut.display) is bound to \(names); the first match wins"
        }
    }

    // MARK: Loading

    /// Where a user's config file is expected to live.
    static func userConfigPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.config"
        return URL(fileURLWithPath: configHome + "/minimal/config.toml")
    }

    /// Candidates in priority order; the first one that exists is used.
    static func searchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [URL] {
        var paths: [URL] = []
        if let explicit = environment["MINIMAL_CONFIG"], !explicit.isEmpty {
            paths.append(URL(fileURLWithPath: expandingTilde(explicit, home: home)))
        }
        paths.append(userConfigPath(environment: environment, home: home))
        paths.append(URL(fileURLWithPath: home + "/Library/Application Support/Minimal/config.toml"))
        return paths
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }

    static func load(searchPaths: [URL] = ShortcutConfig.searchPaths()) -> ShortcutConfig {
        for url in searchPaths {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                var config = ShortcutConfig()
                config.source = url
                config.warnings = ["\(url.path) could not be read; using default shortcuts"]
                return config
            }
            return parse(toml: text, source: url)
        }
        return ShortcutConfig()
    }
}

// MARK: - Process-wide bindings

/// The one table every key handler and hint reads. Loaded at launch and on
/// demand from the menu bar, so editing config.toml doesn't need a restart.
enum Shortcuts {
    private(set) static var config = ShortcutConfig.defaults

    static subscript(action: ShortcutAction) -> Shortcut { config[action] }

    /// Hint text for an action, e.g. "⌘⇧D".
    static func display(_ action: ShortcutAction) -> String { config[action].display }

    @discardableResult
    static func reload() -> ShortcutConfig {
        config = ShortcutConfig.load()
        for warning in config.warnings { NSLog("Shortcuts: %@", warning) }
        return config
    }
}
