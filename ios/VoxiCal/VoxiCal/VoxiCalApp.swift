import SwiftUI

@main
struct VoxiCalApp: App {

    // Single source of truth for the entire app.
    // @State here keeps it alive for the full app lifetime — not recreated on re-renders.
    @State private var viewModel = CalendarViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Inject the viewModel so every subview can reach it via @Environment
                .environment(viewModel)
                // setup() runs once when the root view first appears:
                //   1. Checks Foundation Models availability
                //   2. Requests calendar permission
                //   3. Builds the LanguageModelSession
                //   4. Appends the welcome message
                .task { await viewModel.setup() }
        }
    }
}
