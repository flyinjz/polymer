// The activity log, Docs/ACTIVITY.md: one line per thing an agent did, in
// plain words, newest last, so the owner can see what happened without
// reading code. `polymer log "..."` adds a line; `polymer activity` reads them.
import PolymerBase
import PolymerPlatform

enum Activity {
    static let file = "Docs/ACTIVITY.md"

    /// What a new log starts with.
    static let header = """
        # Activity

        What agents did on Polymer, one plain sentence each, newest last. Agents add a line \
        with `polymer log "..."` after each piece of work; nobody edits or removes lines. \
        `polymer activity` shows the latest.


        """

    /// The longest message `polymer log` takes: one sentence, not a report.
    static let maximumLength = 300

    struct Entry: Equatable {
        /// Local time to the minute, `YYYY-MM-DD HH:MM`.
        var time: String
        /// Who did it: an agent's name or role. Empty when the line has none.
        var by: String
        var message: String
    }

    /// `YYYY-MM-DD HH:MM`, zero-padded.
    static func timestamp(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> String {
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2)) \(pad(hour, 2)):\(pad(minute, 2))"
    }

    /// The line as written in the file: `- 2026-11-22 14:05, name: What was done.`
    static func line(_ e: Entry) -> String {
        e.by.isEmpty ? "- \(e.time): \(e.message)" : "- \(e.time), \(e.by): \(e.message)"
    }

    /// An entry from a line of the file; nil when the line is not one.
    static func parse(_ line: String) -> Entry? {
        let chars = Array(line)
        guard chars.count > 2 + 16, chars[0] == "-", chars[1] == " " else { return nil }
        let time = Array(chars[2..<18])
        for (i, c) in time.enumerated() {
            switch i {
            case 4, 7: guard c == "-" else { return nil }
            case 10: guard c == " " else { return nil }
            case 13: guard c == ":" else { return nil }
            default: guard c.isASCII, c.isNumber else { return nil }
            }
        }
        let rest = Array(chars[18...])
        if rest.count >= 2, rest[0] == ":", rest[1] == " " {
            return Entry(time: String(time), by: "", message: String(rest[2...]))
        }
        guard rest.count >= 2, rest[0] == ",", rest[1] == " " else { return nil }
        // The name has no colon, so the first ": " ends it.
        var i = 2
        while i + 1 < rest.count, !(rest[i] == ":" && rest[i + 1] == " ") { i += 1 }
        guard i + 1 < rest.count else { return nil }
        return Entry(time: String(time), by: String(rest[2..<i]), message: String(rest[(i + 2)...]))
    }

    /// Every entry in the file's text, and how many list lines (`- ...`) were not entries.
    static func entries(_ text: String) -> (entries: [Entry], unreadable: Int) {
        var out: [Entry] = [], bad = 0
        // `isNewline`, not "\n": Swift holds "\r\n" as one Character, so a file saved with
        // Windows line ends would otherwise read as one long line.
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            guard line.hasPrefix("- ") else { continue }
            if let e = parse(line) { out.append(e) } else { bad += 1 }
        }
        return (out, bad)
    }

    /// Why a message or name cannot be logged, with the fix; nil when it can.
    static func problem(message: String, by: String) -> String? {
        if message.isEmpty { return "The message is empty. Say in one plain sentence what you just did." }
        if message.contains(where: { $0.isNewline }) {
            return "The message has a line break. Keep it to one sentence on one line; details belong in Docs/HANDOFF.md."
        }
        if message.count > maximumLength {
            return "The message is \(message.count) characters; the most is \(maximumLength). Say the one thing that changed; details belong in Docs/HANDOFF.md."
        }
        if by.isEmpty || by.contains(where: { $0.isNewline || $0 == ":" }) || by.count > 40 {
            return "The name \"\(by)\" cannot be used: give a short name with no colon or line break, with --by \"name\" or POLYMER_AGENT."
        }
        return nil
    }

    static func trimmed(_ s: String) -> String {
        var t = Substring(s)
        while let f = t.first, f.isWhitespace { t.removeFirst() }
        while let l = t.last, l.isWhitespace { t.removeLast() }
        return String(t)
    }

    static func json(_ e: Entry) -> JSON {
        ["time": .string(e.time), "by": .string(e.by), "message": .string(e.message)]
    }
}

/// `polymer log "message"`: adds one line to Docs/ACTIVITY.md.
func logCommand(root: String, message raw: String, by rawBy: String, time: String, json: Bool) {
    let message = Activity.trimmed(raw), by = Activity.trimmed(rawBy)
    if let p = Activity.problem(message: message, by: by) {
        print(p)
        Platform.process.exit(2)
    }
    let path = Path.join(root, Activity.file)
    var text = Activity.header
    if Platform.files.exists(path) {
        do { text = try Platform.files.readText(path) } catch {
            print("Could not read \(Activity.file): \(error). Nothing was logged.")
            Platform.process.exit(1)
        }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    }
    let entry = Activity.Entry(time: time, by: by, message: message)
    text += Activity.line(entry) + "\n"
    do { try Platform.files.write(text, to: path) } catch {
        print("Could not write \(Activity.file): \(error). Nothing was logged.")
        Platform.process.exit(1)
    }
    if json {
        var o = Activity.json(entry)
        if case .object(var d) = o { d["file"] = .string(Activity.file); o = .object(d) }
        print(o.pretty, terminator: "")
    } else {
        print("Logged in \(Activity.file): \(Activity.line(entry))")
    }
}

/// `polymer activity [N] [--all]`: the latest entries of Docs/ACTIVITY.md, oldest first.
func activityCommand(root: String, count: Int?, json: Bool) {
    let path = Path.join(root, Activity.file)
    var text = ""
    if Platform.files.exists(path) {
        do { text = try Platform.files.readText(path) } catch {
            print("Could not read \(Activity.file): \(error).")
            Platform.process.exit(1)
        }
    }
    let (all, unreadable) = Activity.entries(text)
    let shown = count.map { Array(all.suffix($0)) } ?? all
    if json {
        let o: JSON = ["total": .number(Double(all.count)), "unreadable": .number(Double(unreadable)),
                       "entries": .array(shown.map { Activity.json($0) })]
        print(o.pretty, terminator: "")
        return
    }
    if all.isEmpty {
        print("No activity yet. Agents add a line with `polymer log \"What I just did.\"`.")
    } else {
        for e in shown { print(e.by.isEmpty ? "\(e.time)  \(e.message)" : "\(e.time)  \(e.by): \(e.message)") }
        if shown.count < all.count {
            print("\nThe latest \(shown.count) of \(all.count). `polymer activity --all` shows every entry.")
        }
    }
    if unreadable > 0 {
        print("\n\(unreadable) list lines in \(Activity.file) are not entries and were skipped. An entry reads `- YYYY-MM-DD HH:MM, name: One sentence.`; add them with `polymer log`, not by hand.")
    }
}
