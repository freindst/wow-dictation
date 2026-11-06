import AppKit

/// The Record / Stop keys chosen in the addon's Hotkeys panel. The addon writes them into
/// its SavedVariables file (WTF/Account/*/SavedVariables/LocalDictation.lua) on /reload or logout.
struct InGameBindings: Equatable {
    var recordKeys: [String]
    var padShift: String
    var padCtrl: String
    var padAlt: String
    var file: String
    var modified: Date
}

/// A WoW binding string converted to something the helper can match.
enum WoWTrigger: Equatable {
    case keyboard(keyCode: UInt16, flags: NSEvent.ModifierFlags.RawValue, name: String)
    case gamepad(chord: [String], name: String)
}

enum InGameBindingReader {
    static let installRoots = ["/Applications/World of Warcraft"]

    /// The most recently saved LocalDictation.lua across all WoW flavors and accounts.
    static func newestFile() -> (URL, Date)? {
        let fm = FileManager.default
        var best: (URL, Date)?
        for root in installRoots {
            guard let flavors = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for flavor in flavors where flavor.hasPrefix("_") {
                let accounts = "\(root)/\(flavor)/WTF/Account"
                guard let names = try? fm.contentsOfDirectory(atPath: accounts) else { continue }
                for name in names {
                    let url = URL(fileURLWithPath: "\(accounts)/\(name)/SavedVariables/LocalDictation.lua")
                    guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
                    if best == nil || date > best!.1 { best = (url, date) }
                }
            }
        }
        return best
    }

    static func read(_ url: URL, modified: Date) -> InGameBindings? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func value(_ key: String) -> String {
            let pattern = "\\[\"\(key)\"\\]\\s*=\\s*\"([^\"]*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return "" }
            return String(text[r])
        }
        let keys = [value("helperRecord1"), value("helperRecord2")].filter { !$0.isEmpty }
        return InGameBindings(recordKeys: keys, padShift: value("padShift"), padCtrl: value("padCtrl"),
                              padAlt: value("padAlt"), file: url.path, modified: modified)
    }

    // MARK: WoW binding strings

    /// Splits "ALT-CTRL-SHIFT-META-KEY" (the key itself may be "-").
    static func split(_ binding: String) -> (mods: Set<String>, key: String) {
        var rest = Substring(binding)
        var mods = Set<String>()
        var changed = true
        while changed {
            changed = false
            for mod in ["ALT", "CTRL", "SHIFT", "META"] where rest.hasPrefix(mod + "-") && rest.count > mod.count + 1 {
                mods.insert(mod); rest = rest.dropFirst(mod.count + 1); changed = true
            }
        }
        return (mods, String(rest))
    }

    static let macKeyCodes: [String: UInt16] = {
        var m: [String: UInt16] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13,
            "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "ENTER": 36,
            "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47,
            "TAB": 48, "SPACE": 49, "`": 50, "BACKSPACE": 51, "ESCAPE": 53,
            "NUMPADDECIMAL": 65, "NUMPADMULTIPLY": 67, "NUMPADPLUS": 69, "NUMPADDIVIDE": 75, "NUMPADMINUS": 78,
            "NUMPAD0": 82, "NUMPAD1": 83, "NUMPAD2": 84, "NUMPAD3": 85, "NUMPAD4": 86, "NUMPAD5": 87,
            "NUMPAD6": 88, "NUMPAD7": 89, "NUMPAD8": 91, "NUMPAD9": 92,
            "INSERT": 114, "HOME": 115, "PAGEUP": 116, "DELETE": 117, "END": 119, "PAGEDOWN": 121,
            "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126
        ]
        for (code, name) in GlobalHotKey.functionKeys { m[name] = code }
        return m
    }()

    /// WoW gamepad button names → this app's controller button names.
    static let padButtons: [String: String] = [
        "PAD1": "A / Cross", "PAD2": "B / Circle", "PAD3": "X / Square", "PAD4": "Y / Triangle",
        "PADLSHOULDER": "L1", "PADRSHOULDER": "R1", "PADLTRIGGER": "L2", "PADRTRIGGER": "R2",
        "PADLSTICK": "L3", "PADRSTICK": "R3", "PADDUP": "D-pad Up", "PADDDOWN": "D-pad Down",
        "PADDLEFT": "D-pad Left", "PADDRIGHT": "D-pad Right", "PADFORWARD": "Menu", "PADBACK": "Options"
    ]

    static func trigger(_ binding: String, in bindings: InGameBindings) -> WoWTrigger? {
        let (mods, key) = split(binding)
        if let button = padButtons[key] {
            // On a gamepad, WoW's SHIFT/CTRL/ALT are whichever buttons the GamePadEmulate* settings name.
            var chord = [button]
            for (mod, cvar) in [("SHIFT", bindings.padShift), ("CTRL", bindings.padCtrl), ("ALT", bindings.padAlt)] where mods.contains(mod) {
                guard let modButton = padButtons[cvar] else { return nil }
                chord.insert(modButton, at: 0)
            }
            return .gamepad(chord: chord, name: binding)
        }
        guard let code = macKeyCodes[key] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if mods.contains("ALT") { flags.insert(.option) }
        if mods.contains("CTRL") { flags.insert(.control) }
        if mods.contains("SHIFT") { flags.insert(.shift) }
        if mods.contains("META") { flags.insert(.command) }
        return .keyboard(keyCode: code, flags: flags.rawValue, name: binding)
    }
}
