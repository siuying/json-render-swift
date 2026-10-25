import SwiftUI

/// Form | Document tabs, each a full workspace with its own controller.
struct RootView: View {
    let launchOptions: LaunchOptions
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.mode) {
            ForEach(GenerationKind.allCases) { kind in
                Tab(kind.title, systemImage: kind.systemImage, value: kind) {
                    WorkspaceView(kind: kind, launchOptions: launchOptions)
                        .environment(model.controller(for: kind))
                }
            }
        }
    }
}
