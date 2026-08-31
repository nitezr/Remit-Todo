import SwiftUI

@main
struct RemitApp: App {
    @StateObject private var remindersService = RemindersService()
    @StateObject private var metadataStore = MetadataStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(remindersService)
                .environmentObject(metadataStore)
                .task {
                    if !remindersService.authorizationGranted {
                        await remindersService.requestAccess()
                    } else {
                        await remindersService.refreshAll()
                    }
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
