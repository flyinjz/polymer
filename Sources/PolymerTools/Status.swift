// `polymer status`: where Polymer stands, in plain words, for the owner.
// Docs/status.json is the source; Docs/STATUS.md is made from it by
// `polymer status --write`, and a check keeps the two the same.
import PolymerBase
import PolymerPlatform

enum Status {
    static let source = "Docs/status.json"
    static let page = "Docs/STATUS.md"

    /// The sections of the page, in order: the key in status.json and the heading.
    static let sections: [(key: String, heading: String)] = [
        ("done", "Done"), ("inProgress", "In progress"), ("next", "Next"), ("waitingForOwner", "Waiting for the owner"),
    ]

    /// What is wrong with status.json, with the fix; empty when nothing is.
    static func problems(_ j: JSON) -> [String] {
        guard j.object != nil else { return ["\(source) must be one JSON object with updated, summary, done, inProgress, next and waitingForOwner."] }
        var out: [String] = []
        if j["updated"]?.string == nil { out.append("\"updated\" must be the date of the last change, as \"YYYY-MM-DD\".") }
        if j["summary"]?.string == nil { out.append("\"summary\" must be one or two plain sentences on where things stand.") }
        for s in sections {
            guard let items = j[s.key]?.array else {
                out.append("\"\(s.key)\" must be a list (it may be empty) of {\"title\": \"...\", \"detail\": \"...\"}.")
                continue
            }
            for (i, item) in items.enumerated() {
                guard let t = item["title"]?.string, !t.isEmpty else {
                    out.append("\"\(s.key)\" item \(i + 1) needs a \"title\": a few plain words.")
                    continue
                }
                if let d = item["detail"], d.string == nil { out.append("\"\(s.key)\" item \(i + 1) (\(t)): \"detail\" must be text.") }
            }
        }
        return out
    }

    /// The page, made from status.json (which `problems` found nothing wrong with).
    static func render(_ j: JSON) -> String {
        var out = "# Status\n\n"
        out += "Updated \(j["updated"]?.string ?? ""). \(j["summary"]?.string ?? "")\n\n"
        out += "This page is made from `\(source)` by `polymer status --write`; change that file, not this one.\n"
        for s in sections {
            out += "\n## \(s.heading)\n\n"
            let items = j[s.key]?.array ?? []
            if items.isEmpty { out += "- Nothing at the moment.\n" }
            for item in items {
                let title = item["title"]?.string ?? ""
                let detail = item["detail"]?.string ?? ""
                out += detail.isEmpty ? "- **\(title)**\n" : "- **\(title)**: \(detail)\n"
            }
        }
        return out
    }

    /// Reads and checks status.json; stops with the problems when it cannot be used.
    static func load(root: String) -> JSON {
        let path = Path.join(root, source)
        guard Platform.files.exists(path) else {
            print("\(source) is missing. It holds where the work stands; see Docs/AGENT_GUIDE.md, \"Status and activity\".")
            Platform.process.exit(1)
        }
        let j: JSON
        do { j = try JSON.parse(try Platform.files.readText(path)) } catch {
            print("\(source) is not valid JSON: \(error).")
            Platform.process.exit(1)
        }
        let p = problems(j)
        guard p.isEmpty else {
            print("\(source) needs fixing:")
            for x in p { print("  \(x)") }
            Platform.process.exit(1)
        }
        return j
    }
}

/// `polymer status [--write] [--json]`.
func statusCommand(root: String, write: Bool, json: Bool) {
    let j = Status.load(root: root)
    let text = Status.render(j)
    if write {
        do { try Platform.files.write(text, to: Path.join(root, Status.page)) } catch {
            print("Could not write \(Status.page): \(error).")
            Platform.process.exit(1)
        }
        if !json { print("Wrote \(Status.page) from \(Status.source).") }
    }
    if json {
        print(j.pretty, terminator: "")
    } else if !write {
        print(text, terminator: "")
    }
}
