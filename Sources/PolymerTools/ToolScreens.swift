// Screens the `polymer` command adds to the sample screens, so every input
// step (--type, --drag, --context-click, sheets) has something to act on.
import PolymerBase
import PolymerUI
import PolymerChecks

/// The command's own screens, after the sample screens in `screenNames`.
let toolScreenNames = ["controls"]

/// One of the command's own screens as a live tree, or nil when `name` is not one.
@MainActor
func toolScreenTree(_ name: String, root: String, scale: Double) throws -> ViewTree? {
    var e = EnvironmentValues()
    e.displayScale = scale
    switch name {
    case "controls":
        let font = Font(try TextReference.font(root: root, "Geist-Regular.otf"), size: 13)
        return ViewTree(ControlsScreen(model: ControlsModel(), font: font), environment: e)
    default:
        return nil
    }
}

/// State for the controls screen.
@Observable
final class ControlsModel {
    var name = ""
    var dragged = 0.0
    var note = "Nothing chosen yet"
    var showsSheet = false
}

/// A text field, a view with a context menu, a drag handle and a sheet:
/// one of each kind of input, with the result shown as text.
struct ControlsScreen: View {
    let model: ControlsModel
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controls")
            TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0 }))
                .frame(width: 208)
            Text(model.name.isEmpty ? "Hello" : "Hello, \(model.name)")
            Text("Options")
                .padding(horizontal: 8, vertical: 4)
                .border(Color(white: 1, opacity: 0.14))
                .contextMenu {
                    Button("Copy") { model.note = "Chose Copy" }
                    Button("Rename") { model.note = "Chose Rename" }
                }
            HStack(spacing: 8) {
                Rectangle()
                    .foregroundStyle(Color(white: 0.22))
                    .frame(width: 24, height: 24)
                    .gesture(DragGesture().onEnded { model.dragged += $0.translation.width })
                Text("Dragged \(Int(model.dragged)) points")
            }
            Button("Show sheet") { model.showsSheet = true }
            Text(model.note).foregroundStyle(Color(white: 0.6))
        }
        .font(font)
        .padding(16)
        .frame(width: 240, alignment: .leading)
        .background(Color(white: 0.063))
        .sheet(isPresented: Binding(get: { model.showsSheet }, set: { model.showsSheet = $0 })) {
            ControlsSheet(font: font)
        }
    }
}

struct ControlsSheet: View {
    let font: Font
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A sheet")
            Button("Done") { dismiss() }
        }
        .font(font)
        .padding(16)
    }
}
