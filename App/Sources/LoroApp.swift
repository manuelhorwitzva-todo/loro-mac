import LoroKit
import SwiftUI

@main
struct LoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(state)
        } label: {
            MenuBarLabel()
                .environment(state)
        }
        .menuBarExtraStyle(.window)

        Window("Loro", id: "main") {
            MainWindow().environment(state)
        }
        .defaultSize(width: 860, height: 600)

        Settings {
            SettingsView().environment(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppState.shared.boot() }
    }

    /// La app no tiene Dock ni ventana principal: si el usuario la abre de nuevo desde
    /// Aplicaciones o Spotlight, lo que espera es ver Ajustes.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // La acción real de abrir Ajustes solo existe dentro de SwiftUI (openSettings);
        // avisamos a la vista de la barra, que siempre está viva, y ella la ejecuta.
        NotificationCenter.default.post(name: .loroOpenMain, object: nil)
        return true
    }
}

extension Notification.Name {
    static let loroOpenSettings = Notification.Name("cl.manulit0.loro.openSettings")
    static let loroOpenMain = Notification.Name("cl.manulit0.loro.openMain")
}

/// Ícono de la barra: un lorito, que se vuelve una onda mientras escucha.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        icon
            .onReceive(NotificationCenter.default.publisher(for: .loroOpenSettings)) { _ in
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .loroOpenMain)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    @ViewBuilder private var icon: some View {
        switch state.status {
        case .recording: Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
        case .transcribing: Image(systemName: "ellipsis.circle")
        case .preparing: Image(systemName: "arrow.down.circle.dotted")
        default: Image(systemName: "bird.fill")
        }
    }
}
