// `polymer help [topic]`: every command and option, with an example each.
import PolymerBase
import PolymerPlatform

enum Help {
    /// Options that take no value.
    static let knownFlags: Set<String> = ["--json", "--a11y", "--list", "--verbose", "--write", "--all", "--software", "--help"]

    /// Each topic: its name, one line on what it is, and the full text.
    static let topics: [(name: String, summary: String, text: String)] = [
        ("check", "Runs the checks: the tests that must pass before every push.", """
            polymer check [name] [--list] [--verbose]

            Runs every check, or the ones whose name contains `name`. Each prints
            "pass" or "FAIL" with what went wrong and where. Run it from the
            repository root; it needs no window and no network.

              polymer check              every check
              polymer check ui.          the checks whose name contains "ui."
              polymer check --list       the names only
              polymer check --verbose    also print each check's notes

            """),
        ("check-tools", "Runs only the checks for the polymer command itself.", """
            polymer check-tools

            Runs the checks for the command (arguments, render, tree, describe,
            diff, bench, the samples): what `polymer check` adds after the
            framework's checks. Prints "pass" or "FAIL" and the totals; needs
            the repository root.

            """),
        ("render", "Draws a screen to a PNG file, after optional input steps.", """
            polymer render <screen> <out.png> [--scale N] [--customize file.json] [steps] [--json]

            Draws the screen offscreen (no window opens) and writes the image.
            --scale 2 draws at twice the pixels, as on a Retina or 200% display.
            --customize file.json draws with saved Customize changes (see
            `polymer help customize`).
            Steps (see `polymer help steps`) run first, in the order given, so
            the image shows the screen after them. --json prints the file, the
            screen, the scale and the size in pixels.

              polymer render counter out/counter.png
              polymer render counter out/after.png --click Add --scale 2
              polymer render controls out/menu.png --context-click Options

            """),
        ("customize", "Draws a screen with saved Customize changes from a JSON file.", """
            --customize <file.json>, with render and describe.

            The file is what `CustomizeModel.json` saves:
            {"version": 1, "elements": {"toolbar/play": {"hidden": true,
            "scale": 1.25, "width": 120, "height": 36}}}. Paths are element
            names from `polymer tree`; hidden, scale, style, width and height
            are optional. Widths and heights are points above 0. Save the
            screen with Customize, then pass that file to draw the same view.

              polymer render controls out/hidden.png --customize changes.json

            """),
        ("tree", "Prints what is on a screen: every element with its frame.", """
            polymer tree <screen> [--a11y] [--json] [steps]

            Prints the element tree: one line per element, indented by nesting,
            as `Role (x, y, widthxheight) detail`, in points from the top-left.
            Use the frames to aim --click-at and --drag. --a11y prints the
            accessibility tree instead (what a screen reader sees). --json
            prints either one as nested objects.

              polymer tree counter
              polymer tree counter --a11y
              polymer tree controls --json --key tab

            """),
        ("describe", "Says in plain words what a screen contains.", """
            polymer describe <screen> [--json] [steps]

            Reads the screen's accessibility tree and lists what is on it in
            plain sentences: texts, buttons, text fields and what they contain,
            open menus and sheets, what is disabled, what has focus, and the
            totals. --json gives the same as data, with the sentences in "text".

              polymer describe counter
              polymer describe controls --click "Show sheet"

            """),
        ("steps", "Input options: click, type, drag, press keys, scroll, right-click.", """
            Input steps, for render, tree and describe. They run in the order
            given, each after the screen has updated from the one before.

              --click "Add"             clicks the middle of the text that reads exactly "Add"
              --click-at 40,12          clicks at a point (x,y in points, from `polymer tree`)
              --context-click "Options" right-clicks that text: opens its context menu
              --drag 28,120,88,120      presses at the first point, moves to the second, lets go
              --type "Ada"              types into the focused text field (focus one first)
              --key tab                 presses a key: a character, or tab, space, return,
                                        escape, delete, up, down, left, right, home, end,
                                        pageup, pagedown; with shift+, ctrl+, alt+ or cmd+
              --hover "Add"             moves the pointer over that text
              --press "Add"             holds the pointer down on that text (shows the pressed look)
              --scroll 120              scrolls the middle of the screen down by 120 points

            A step that does nothing stops with a message that says why and how
            to fix it, except --drag, which only notes it on stderr.

              polymer render controls out/typed.png --key tab --type "Ada"
              polymer render controls out/renamed.png --context-click Options --click Rename

            """),
        ("screens", "The screens the command can draw, and how to add your own.", """
            Screens: albums, counter, list, library and glass (the samples in
            Sources/PolymerChecks/UIChecks.swift), and controls (a text field,
            a context menu, a drag handle and a sheet, in
            Sources/PolymerTools/ToolScreens.swift).

            There is no way yet to point the command at an app's own screens.
            Until there is, drive the app's views from a check with `ViewTree`,
            which has the same input calls as the steps; see Docs/AGENT_GUIDE.md.

            """),
        ("status", "Prints where Polymer stands, in plain words, for the owner.", """
            polymer status [--write] [--json]

            Prints the status page made from Docs/status.json: what is done, in
            progress, next, and waiting for the owner. --write saves it to
            Docs/STATUS.md (a check fails while the two differ). --json prints
            status.json itself. To change the status, edit Docs/status.json,
            then run `polymer status --write`.

            """),
        ("log", "Adds one plain sentence about what you just did to the activity log.", """
            polymer log "One plain sentence about what you just did." [--by name] [--json]

            Adds a line with the local date and time to Docs/ACTIVITY.md, so the
            owner can follow the work without reading code. Write for someone
            who does not program: what changed for them, not how. One line, at
            most 300 characters. The name is --by, else the POLYMER_AGENT
            environment variable, else "agent".

              polymer log "Added a right-click menu to album covers." --by "ui agent"

            """),
        ("activity", "Shows the latest lines of the activity log.", """
            polymer activity [N] [--all] [--json]

            Prints the latest 20 entries of Docs/ACTIVITY.md (or N, or --all),
            oldest first, as `date time  name: sentence`.

            """),
        ("zoom", "Crops and enlarges part of a PNG, to look at single pixels.", """
            polymer zoom <in.png> <out.png> x y width height factor

            Copies the rectangle (in pixels) and enlarges it `factor` times
            without smoothing, so each pixel shows as a square.

              polymer zoom out/counter.png out/zoom.png 10 10 40 20 8

            """),
        ("diff", "Compares two PNGs pixel by pixel and draws what differs.", """
            polymer diff <a.png> <b.png> [--out diff.png] [--threshold N] [--json]

            Prints how many pixels differ, their share, the mean channel
            difference and the largest one. --out writes a picture: the first
            image dimmed, with changed pixels in magenta (red where the change
            is 32 or more). --threshold is the mean difference above which the
            command exits 1 (0 by default: any difference fails).

              polymer diff out/before.png out/after.png --out out/diff.png

            """),
        ("bench", "Measures what a frame costs: layout and drawing times.", """
            polymer bench [--frames N] [--width W] [--height H] [--json]

            Builds a representative screen of rows and items, draws it
            --frames times (20 by default) at WxH points (720x480 by default),
            and prints the median, 95th percentile and longest layout and draw
            times in milliseconds.

              polymer bench --frames 50 --width 1280 --height 800

            """),
        ("demo", "Opens a screen in a real window (for the owner; never in checks).", """
            polymer demo [screen] [--software]

            Opens the screen in a window on this computer, drawn by the GPU
            (--software draws on the CPU instead). Agents do not run this:
            checks and agents work headlessly with render, tree and describe.

            """),
        ("json", "Which commands print machine-readable output with --json.", """
            --json prints JSON instead of text for: render (file and size),
            tree (element or accessibility tree), describe, status, log,
            activity, diff, bench and help. Objects have sorted keys and end
            with a newline.

            """),
    ]

    static let overview = """
        polymer: the command for building and checking Polymer software.

        Run it from the repository root. Nothing it does opens a window
        (except demo) or uses the network.

        """

    /// Prints the overview or one topic; stops with the list of topics when there is no such topic.
    static func show(topic: String?, json: Bool) {
        let names = topics.map { $0.name } + ["help"]
        if let topic {
            guard let t = topics.first(where: { $0.name == topic }) else {
                if topic == "help" {
                    show(topic: nil, json: json)
                    return
                }
                print("No help on \"\(topic)\". Topics: \(names.joined(separator: ", ")).")
                Platform.process.exit(2)
            }
            if json {
                let o: JSON = ["topic": .string(t.name), "summary": .string(t.summary), "text": .string(t.text)]
                print(o.pretty, terminator: "")
            } else {
                print(t.text, terminator: "")
            }
            return
        }
        if json {
            let o: JSON = ["topics": .array(topics.map { ["name": .string($0.name), "summary": .string($0.summary)] })]
            print(o.pretty, terminator: "")
            return
        }
        var out = overview + "Commands and topics (`polymer help <topic>` for each):\n\n"
        let width = topics.map { $0.name.count }.max() ?? 0
        for t in topics {
            out += "  " + t.name + String(repeating: " ", count: width - t.name.count + 2) + t.summary + "\n"
        }
        out += "\nTo start: `polymer render counter out/counter.png`, look at the image, then `polymer describe counter`.\n"
        print(out, terminator: "")
    }
}
