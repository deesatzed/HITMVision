import Foundation

public enum CommandParse: Equatable, Sendable {
    case simple([String])
    case notSimple(String)
}

/// Turns a command string into an argument list, or says why it is not a plain command.
/// PARSING ONLY: nothing here runs, expands, resolves or touches the filesystem. Anything the shell would
/// treat specially (pipes, lists, redirects, substitution, expansion, globs, environment prefixes,
/// extended-glob characters, comments, escapes, line breaks) is `.notSimple`, so a standing rule can never cover it.
///
/// ACCEPTED LIMITS: this is stricter than a real shell on purpose (a backslash or `~` anywhere unquoted is
/// rejected, an unquoted `#` starting a word is rejected). Shell aliases and functions are outside the
/// engine; `#` is only rejected at the start of a word (an extended-glob `#` needs a preceding `^` or `(`, both
/// rejected anywhere); the string is judged as written, not as a particular shell would run it.
public enum CommandParser {
    public static func parse(_ command: String) -> CommandParse {
        // Control characters first, inside quotes too. Tab is the only one allowed (as a separator or literal).
        for scalar in command.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { return .notSimple("contains a line break") }
            if scalar.value == 0 { return .notSimple("contains a NUL character") }
            if (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F {
                return .notSimple("contains a control character")
            }
        }
        if startsWithAssignment(command) { return .notSimple("starts with a VAR=value environment assignment") }

        // Walk Unicode scalars, never Characters: a shell sees scalars, so a metacharacter or quote followed by
        // a combining mark (U+0301, U+FE0F, ZWJ...) is still live. As Characters it would hide inside a cluster.
        var argv: [String] = []
        var current = String.UnicodeScalarView()
        var inWord = false
        var quote: Unicode.Scalar? = nil

        for ch in command.unicodeScalars {
            if let q = quote {
                if ch == q { quote = nil; continue }
                if q == "\"" {
                    if ch == "$" { return .notSimple("uses $ inside double quotes") }
                    if ch == "`" { return .notSimple("uses a backtick inside double quotes") }
                    if ch == "\\" { return .notSimple("uses a backslash inside double quotes") }
                }
                current.append(ch)
                continue
            }
            switch ch {
            case " ", "\t":
                if inWord { argv.append(String(current)); current = String.UnicodeScalarView(); inWord = false }
            case "'", "\"":
                quote = ch
                inWord = true
            case "|": return .notSimple("contains a pipe")
            case ";": return .notSimple("contains a command separator (;)")
            case "&": return .notSimple("contains & (background or and-list)")
            case "<", ">": return .notSimple("contains a redirect")
            case "(", ")": return .notSimple("contains parentheses (subshell or substitution)")
            case "`": return .notSimple("contains a backtick (command substitution)")
            case "$": return .notSimple("contains $ (variable or command substitution)")
            case "{", "}": return .notSimple("contains braces (expansion)")
            case "~": return .notSimple("contains ~ (home directory expansion)")
            case "*", "?", "[": return .notSimple("contains a glob character")
            case "^": return .notSimple("contains ^ (extended glob in some shells)")
            case "\\": return .notSimple("contains a backslash escape")
            case "#" where !inWord: return .notSimple("contains a comment marker")
            default:
                current.append(ch)
                inWord = true
            }
        }
        if quote != nil { return .notSimple("has an unterminated quote") }
        if inWord { argv.append(String(current)) }
        if argv.isEmpty { return .notSimple("is empty") }
        return .simple(argv)
    }

    /// `NAME=...` at the very start, before any quote or space, with NAME a valid shell variable name.
    private static func startsWithAssignment(_ command: String) -> Bool {
        var sawName = false
        for ch in command.unicodeScalars.drop(while: { $0 == " " || $0 == "\t" }) {
            if ch == "=" { return sawName }
            let isStart = ch == "_" || (ch.isASCII && ch.properties.isAlphabetic)
            let isRest = isStart || (ch.isASCII && ch.properties.numericType != nil)
            if !(sawName ? isRest : isStart) { return false }
            sawName = true
        }
        return false
    }
}
