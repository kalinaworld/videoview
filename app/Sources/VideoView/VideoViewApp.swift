import SwiftUI

@main
struct VideoViewApp: App {
    @State private var lib = Library()

    var body: some Scene {
        WindowGroup("Video View") {
            ContentView()
                .environment(lib)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder…") { lib.promptNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Go to Folder…") { lib.goToFolder() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Add Folder to Favorites…") { lib.pickFolder() }
                    .keyboardShortcut("o")
                Button("Rebuild Thumbnail Cache") { lib.rebuildCache() }
            }
        }
    }
}
