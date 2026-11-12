import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Mimesis project file (`Name.mimesis`): a package with the edits and the two videos.
    public static let mimesisProject = UTType(exportedAs: "com.ljworkshop.mimesis.project")
}

/// What the Mac's menu bar asks the comparison screen to do (File › Save, Open Recent…), and what the
/// screen tells the menu (the recent projects, what's possible now).
@MainActor @Observable
public final class MenuRequests {
    public static let shared = MenuRequests()

    public enum Request: Equatable {
        case new, open, openRecent(RecentProject.ID), save, saveAs, export, edit, swap, undo, redo
    }

    public var pending: Request?
    public var recents: [RecentProject] = []
    /// Where each recent project is (its full path), for the Open Recent menu.
    public var recentPaths: [RecentProject.ID: String] = [:]
    public var hasClips = false
    public var hasBoth = false
}

/// The Mac's File menu: New, Open, Open Recent, Save, Save As, Export.
public struct MimesisCommands: Commands {
    public init() {}

    public var body: some Commands {
        let menu = MenuRequests.shared
        CommandGroup(replacing: .newItem) {
            Button("New Comparison") { menu.pending = .new }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Project…") { menu.pending = .open }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(menu.recents) { recent in
                    Button(menu.recentPaths[recent.id] ?? recent.name) { menu.pending = .openRecent(recent.id) }
                }
                if menu.recents.isEmpty { Text("No Recent Projects") }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { menu.pending = .save }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!menu.hasClips)
            Button("Save Project As…") { menu.pending = .saveAs }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!menu.hasClips)
            Divider()
            Button("Export Video…") { menu.pending = .export }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!menu.hasBoth)
        }
        // Edit › Undo and Redo: the comparison's edits; while typing, the typing's own.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { Self.undo(redo: false) }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { Self.undo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Edit Clip…") { menu.pending = .edit }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!menu.hasClips)
            Button("Swap A and B") { menu.pending = .swap }
                .disabled(!menu.hasBoth)
        }
    }

    private static func undo(redo: Bool) {
        #if os(macOS)
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
            return
        }
        #endif
        MenuRequests.shared.pending = redo ? .redo : .undo
    }
}
