import LoroKit
import AppKit
import SwiftUI

/// Pastilla flotante abajo al centro de la pantalla que muestra el estado mientras grabas.
/// Es un NSPanel no-activante: aparece sobre cualquier app sin robarle el foco (si le robara
/// el foco, el ⌘V iría a parar al HUD y no a donde estabas escribiendo).
/// Se puede arrastrar a donde quieras; la posición se recuerda (relativa a la pantalla, así
/// sirve igual en el notebook y en un monitor externo). Doble clic la devuelve abajo al centro.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// true mientras nosotros mismos movemos el panel, para no confundirlo con un arrastre.
    private var isPositioning = false
    private static let anchorKey = "hudAnchor"
    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        hideTask?.cancel()
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    func flash(_ message: String) {
        show()
        hide(after: .seconds(2.5))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Recibe el mouse solo para poder arrastrarlo. Un panel borderless no puede volverse
        // ventana key, así que arrastrarlo no le roba el foco a la app donde estás escribiendo.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        let host = DraggableHostingView(rootView: AnyView(HUDView().environment(AppState.shared)))
        host.sizingOptions = [.preferredContentSize]
        host.onDoubleClick = { [weak self] in self?.resetPosition() }
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAnchor() }
        }
        return panel
    }

    /// Guarda dónde dejó el usuario el HUD, como fracción del área visible de su pantalla:
    /// centro horizontal y borde inferior (el HUD crece hacia arriba desde ahí).
    private func saveAnchor() {
        guard !isPositioning, let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let fx = (panel.frame.midX - f.minX) / f.width
        let fy = (panel.frame.minY - f.minY) / f.height
        UserDefaults.standard.set([fx, fy], forKey: Self.anchorKey)
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        position()
    }

    /// SwiftUI todavía no hizo layout cuando llega el onChange; esperamos un tick.
    func repositionAfterLayout() {
        Task { @MainActor in
            await Task.yield()
            position()
        }
    }

    /// Abajo al centro, o donde el usuario lo dejó. Se llama de nuevo cuando el HUD crece con
    /// el texto en vivo, anclando el borde inferior para que crezca hacia arriba.
    func position() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        var x = f.midX - size.width / 2
        var y = f.minY + 28
        if let anchor = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], anchor.count == 2 {
            x = f.minX + anchor[0] * f.width - size.width / 2
            y = f.minY + anchor[1] * f.height
        }
        // Siempre entero dentro de la pantalla, aunque crezca con el texto.
        x = min(max(x, f.minX), f.maxX - size.width)
        y = min(max(y, f.minY), f.maxY - size.height)
        isPositioning = true
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        isPositioning = false
    }
}

/// NSHostingView que deja arrastrar la ventana desde cualquier punto y avisa del doble clic.
final class DraggableHostingView: NSHostingView<AnyView> {
    var onDoubleClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }
}

struct HUDView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusColumn
                .frame(width: state.pendingText != nil ? 230 : 150, alignment: .leading)
            if !state.liveText.isEmpty {
                Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1).padding(.vertical, 4)
                TypewriterText(committed: state.liveCommitted, volatile: state.liveVolatile)
                    .font(.system(size: 13))
                    // El texto vive en ~317 px de ancho (≈50 caracteres por línea). Si algo no cabe,
                    // se corta el PRINCIPIO: lo último que dijiste tiene que verse siempre.
                    .lineLimit(12)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Sin animación aquí: SwiftUI fundiría el texto completo en cada cambio.
                    .animation(nil, value: state.liveCommitted)
                    .animation(nil, value: state.liveVolatile)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: state.liveText.isEmpty ? 260 : 520)
        .frame(minHeight: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .animation(.easeOut(duration: 0.15), value: state.liveText.isEmpty)
        .onChange(of: state.liveText) { _, _ in state.hud.repositionAfterLayout() }
        .onChange(of: state.status) { _, _ in state.hud.repositionAfterLayout() }
        .onChange(of: state.pendingText) { _, _ in state.hud.repositionAfterLayout() }
    }

    /// 420 caracteres ≈ 8 líneas en el ancho del HUD. Antes eran 700, que son ~14 líneas:
    /// con `lineLimit(12)` las últimas dos quedaban cortadas y el texto "dejaba de crecer".
    static let maxLiveChars = 420

    static func tailSplit(committed: String, volatile: String, maxChars: Int = maxLiveChars) -> (String, String) {
        let total = committed.count + volatile.count
        guard total > maxChars else { return (committed, volatile) }
        if volatile.count >= maxChars { return ("", tail(volatile, maxChars: maxChars)) }
        return (tail(committed, maxChars: maxChars - volatile.count), volatile)
    }

    /// Si el dictado es muy largo, mostramos la cola: lo que acabas de decir es lo que importa.
    static func tail(_ text: String, maxChars: Int = maxLiveChars) -> String {
        guard text.count > maxChars else { return text }
        let cut = text.suffix(maxChars)
        // Empezamos en el primer espacio para no partir una palabra.
        if let sp = cut.firstIndex(of: " ") { return "…" + cut[cut.index(after: sp)...] }
        return "…" + cut
    }

    /// Ícono + estado + barras de nivel, siempre a la izquierda.
    private var statusColumn: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 30, height: 30)
                icon.foregroundStyle(color).font(.system(size: 14, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.pendingText != nil ? "Listo · Enter para pegar" : (state.micStarting ? "Conectando micrófono…" : state.status.label)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if state.status == .recording { LevelBars(level: state.level, tint: color) }
                else if state.liveText.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    private var color: Color {
        if state.pendingText != nil { return .green }
        switch state.status {
        case .recording: return .green
        case .error: return .red
        case .transcribing: return .teal
        default: return .secondary
        }
    }

    private var icon: Image {
        if state.pendingText != nil { return Image(systemName: "return") }
        switch state.status {
        case .recording: return Image(systemName: "mic.fill")
        case .error: return Image(systemName: "exclamationmark.triangle.fill")
        case .transcribing: return Image(systemName: "sparkles")
        default: return Image(systemName: "bird.fill")
        }
    }

    private var subtitle: String {
        if state.pendingText != nil { return "Esc: solo portapapeles (⌘V)" }
        if state.micStarting { return "Habla cuando suene" }
        switch state.status {
        case .transcribing: return state.settings.engine.displayName
        default:
            switch state.settings.hotkeyMode {
            case .pushToTalk: return "Suelta la tecla para transcribir · Esc cancela"
            case .toggle: return "Toca la tecla de nuevo para transcribir · Esc cancela"
            case .hybrid: return "Suelta o toca de nuevo para transcribir · Esc cancela"
            }
        }
    }
}

/// Barras de nivel: 14 barritas cuya altura sigue el RMS del micrófono.
struct LevelBars: View {
    let level: Float
    let tint: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<14, id: \.self) { i in
                let threshold = Float(i) / 14
                let boosted = min(level * 8, 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(boosted > threshold ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 8)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// Efecto máquina de escribir: el texto objetivo cambia a saltos (cada preview), pero en
/// pantalla las letras nuevas aparecen una a una. Si la cola volátil cambia, retrocede hasta
/// el prefijo común y vuelve a escribir desde ahí, como si corrigiera.
struct TypewriterText: View {
    let committed: String
    let volatile: String
    @State private var shown = ""
    @State private var committedLen = 0

    private var target: String {
        let (c, v) = HUDView.tailSplit(committed: committed, volatile: volatile)
        return c.isEmpty ? v : (v.isEmpty ? c : c + " " + v)
    }
    private var targetCommittedLen: Int {
        HUDView.tailSplit(committed: committed, volatile: volatile).0.count
    }

    var body: some View {
        let split = min(committedLen, shown.count)
        let head = String(shown.prefix(split))
        let tail = String(shown.dropFirst(split))
        return (Text(head).foregroundStyle(.primary.opacity(0.9)) + Text(tail).foregroundStyle(.secondary))
            .task(id: target) { await type() }
    }

    private func type() async {
        let goal = target
        let goalCommitted = targetCommittedLen
        // Cuando ya se muestra la cola ("…"), la ventana se corre en cada actualización y el
        // prefijo común es casi nulo: reescribir todo tardaría más que el intervalo del preview.
        // Saltamos directo al texto nuevo y solo animamos si creció por el final.
        if shown.hasPrefix("…"), goal.hasPrefix("…"), !goal.hasPrefix(shown) {
            shown = goal; committedLen = min(goalCommitted, shown.count); return
        }
        // Retrocedemos hasta donde coinciden; lo ya escrito y correcto no se borra.
        let common = zip(shown, goal).prefix { $0 == $1 }.count
        if common < shown.count { shown = String(shown.prefix(common)) }
        committedLen = min(goalCommitted, shown.count)
        var i = shown.count
        let chars = Array(goal)
        while i < chars.count, !Task.isCancelled {
            // Si vamos muy atrás, escribimos más rápido para alcanzar al habla.
            let behind = chars.count - i
            let step = behind > 40 ? 3 : (behind > 15 ? 2 : 1)
            shown.append(contentsOf: chars[i..<min(i + step, chars.count)])
            i += step
            committedLen = min(goalCommitted, shown.count)
            try? await Task.sleep(for: .milliseconds(behind > 40 ? 8 : 16))
        }
        committedLen = min(goalCommitted, shown.count)
    }
}
