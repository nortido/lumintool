import AppKit
import Combine
import SwiftUI
import LuminToolCore

struct Monitor: Identifiable {
    let id: String
    let name: String
    @MainActor static func connected() -> [Monitor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(id) == 0, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return Monitor(id: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName)
        }
    }
}

struct Configuration: Codable {
    var server = "http://homeassistant.local:8123"
    var entity = ""
    var monitor = ""
    var enabled = true
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: Configuration
    @Published private(set) var sensors: [LightSensor] = []
    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var lux: Double?
    @Published private(set) var brightness: Double?
    @Published private(set) var haStatus = L("Enter a Home Assistant token")
    @Published private(set) var displayStatus = L("Checking the monitor…")
    @Published private(set) var hasToken = false
    private let brightnessService = SystemBrightness()
    private let ha = HomeAssistantConnection()
    private var engine = AdaptiveBrightness()
    private var controlTask: Task<Void, Never>?
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false

    init() {
        config = UserDefaults.standard.data(forKey: "configuration")
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        monitors = Monitor.connected()
        if config.monitor.isEmpty {
            config.monitor = monitors.count == 1 ? monitors[0].id : ""
        }
        loadCurve()
        ha.onSensors = { [weak self] in self?.sensors = $0 }
        ha.onSelection = { [weak self] entity in
            guard let self, self.config.entity != entity else { return }
            self.config.entity = entity
            self.saveConfiguration()
            self.loadCurve()
        }
        ha.onLux = { [weak self] value in
            self?.lux = value
            self?.engine.sensor(value)
        }
        ha.onStatus = { [weak self] in self?.haStatus = $0 }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.stop()
            }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.refreshMonitors()
            }
        }))
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMonitors() }
        }))
    }

    deinit {
        controlTask?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private var curveKey: String {
        let parts = [config.server, config.entity, config.monitor]
        return "curve." + Data((try! JSONEncoder().encode(parts))).base64EncodedString()
    }

    private func saveConfiguration() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "configuration") }
    }

    private func loadCurve() {
        let curve = UserDefaults.standard.data(forKey: curveKey)
            .flatMap { try? JSONDecoder().decode(BrightnessCurve.self, from: $0) } ?? BrightnessCurve()
        engine = AdaptiveBrightness(curve: curve)
        engine.sensor(lux)
    }

    private func saveCurve() {
        if let data = try? JSONEncoder().encode(engine.curve) { UserDefaults.standard.set(data, forKey: curveKey) }
    }

    func refreshMonitors() {
        monitors = Monitor.connected()
        start()
    }

    func stop() {
        generation += 1
        controlTask?.cancel()
        controlTask = nil
        ha.stop()
        engine.resetObservation()
    }

    func start() {
        stop()
        guard !sleeping else { return }
        saveConfiguration()
        do {
            let endpoint = try HomeAssistantEndpoint(config.server)
            if let token = try TokenStore.read(account: endpoint.base.absoluteString), !token.isEmpty {
                hasToken = true
                ha.start(endpoint: endpoint, token: token, selected: config.entity)
            } else {
                hasToken = false
                haStatus = L("Enter a Home Assistant token in Settings")
            }
        } catch { hasToken = false; haStatus = error.localizedDescription }
        let epoch = generation
        controlTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self, self.generation == epoch else { return }
                await self.controlStep(epoch: epoch)
                deadline += .milliseconds(100)
                if deadline < clock.now { deadline = clock.now }
                do { try await clock.sleep(until: deadline, tolerance: .milliseconds(2)) } catch { return }
            }
        }
    }

    private func controlStep(epoch: Int) async {
        guard monitors.contains(where: { $0.id == config.monitor }) else {
            displayStatus = L("Monitor disconnected or not selected")
            brightness = nil
            engine.resetObservation()
            return
        }
        do {
            let current = try await brightnessService.brightness(display: config.monitor)
            guard epoch == generation, !Task.isCancelled,
                  monitors.contains(where: { $0.id == config.monitor }) else { return }
            brightness = current
            displayStatus = config.enabled ? (lux == nil ? L("Waiting for the sensor; brightness kept") : L("Auto brightness on")) : L("Auto brightness paused")
            guard config.enabled, !config.entity.isEmpty else { engine.resetObservation(); return }
            switch engine.tick(brightness: current, now: ProcessInfo.processInfo.systemUptime) {
            case .hold:
                if engine.isSettling { displayStatus = L("Waiting for the monitor to apply brightness") }
            case .learned: saveCurve()
            case .set(let value):
                let applied = try await brightnessService.setBrightness(value, display: config.monitor)
                guard epoch == generation, !Task.isCancelled else { return }
                engine.acknowledge(brightness: applied, requested: value)
                brightness = applied
            }
        } catch {
            guard epoch == generation, !Task.isCancelled else { return }
            displayStatus = error.localizedDescription
            engine.resetObservation()
        }
    }

    func connect(server: String, token: String) throws {
        let endpoint = try HomeAssistantEndpoint(server)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { try TokenStore.save(token, account: endpoint.base.absoluteString) }
        guard try TokenStore.read(account: endpoint.base.absoluteString) != nil else {
            throw LuminToolError.message(L("Enter a long-lived Home Assistant token."))
        }
        stop()
        if config.server != endpoint.base.absoluteString {
            config.entity = ""
            sensors = []
        }
        config.server = endpoint.base.absoluteString
        loadCurve()
        start()
    }

    func chooseSensor(_ entity: String) {
        stop()
        config.entity = entity
        loadCurve()
        start()
    }

    func chooseMonitor(_ monitor: String) {
        stop()
        config.monitor = monitor
        loadCurve()
        start()
    }

    func toggleEnabled() {
        config.enabled.toggle()
        start()
    }

    func resetCalibration() {
        stop()
        engine = AdaptiveBrightness()
        saveCurve()
        start()
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var server = ""
    @State private var token = ""
    @State private var error = ""
    @State private var language = AppLanguage(appleLanguages: UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])
    @State private var languageChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LuminTool").font(.largeTitle.bold())
            Text("Monitor brightness from Home Assistant illuminance.").foregroundStyle(.secondary)
            Form {
                TextField("Home Assistant", text: $server)
                SecureField(model.hasToken ? L("New token (optional)") : L("Long-lived token"), text: $token)
                HStack {
                    Button("Connect") {
                        do { try model.connect(server: server, token: token); token = ""; error = "" }
                        catch { self.error = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                    Button("Create token") {
                        if let endpoint = try? HomeAssistantEndpoint(server) {
                            NSWorkspace.shared.open(endpoint.base.appendingPathComponent("profile/security"))
                        }
                    }
                }
                Picker("Sensor", selection: Binding(get: { model.config.entity }, set: model.chooseSensor)) {
                    Text("Auto").tag("")
                    if !model.config.entity.isEmpty && !model.sensors.contains(where: { $0.id == model.config.entity }) {
                        Text(model.config.entity).tag(model.config.entity)
                    }
                    ForEach(model.sensors) { sensor in Text("\(sensor.name) — \(sensor.id)").tag(sensor.id) }
                }
                Picker("Monitor", selection: Binding(get: { model.config.monitor }, set: model.chooseMonitor)) {
                    Text("Choose a monitor").tag("")
                    if !model.config.monitor.isEmpty && !model.monitors.contains(where: { $0.id == model.config.monitor }) {
                        Text("Monitor disconnected").tag(model.config.monitor)
                    }
                    ForEach(model.monitors) { monitor in Text(monitor.name).tag(monitor.id) }
                }
                Toggle("Auto brightness", isOn: Binding(get: { model.config.enabled }, set: { _ in model.toggleEnabled() }))
                Picker("Language", selection: $language) {
                    Text("System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "Русский").tag(AppLanguage.russian)
                }.onChange(of: language) { _, value in
                    if let languages = value.appleLanguages {
                        UserDefaults.standard.set(languages, forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    }
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("Restart LuminTool to change the language.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart") { restart() }
                    }
                }
            }.formStyle(.grouped).frame(height: languageChanged ? 345 : 305)
            if (try? HomeAssistantEndpoint(server))?.base.scheme == "http" {
                Text("HTTP does not encrypt the token. Use HTTPS for a secure connection.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.haStatus)
                Text(model.displayStatus)
                Text("\(model.lux.map { String(format: "%.1f lx", $0) } ?? "— lx") · \(model.brightness.map { String(format: "%.0f%%", $0 * 100) } ?? "—%")")
                    .font(.system(.body, design: .monospaced))
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.font(.callout)
            Text("Change brightness with the keyboard keys or the macOS slider. One second after your last change, LuminTool saves it for the current lux. The token is stored in Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 590)
        .onAppear { server = model.config.server }
    }

    private func restart() {
        model.stop()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) } else { model.start() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let illuminanceItem = NSMenuItem(title: L("Sensor unavailable"), action: nil, keyEquivalent: "")
    private let brightnessItem = NSMenuItem(title: L("Brightness unavailable"), action: nil, keyEquivalent: "")
    private let displayStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var subscriptions = Set<AnyCancellable>()
    private var iconLevel = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()
        bindStatusItems()
        model.start()
        if model.config.entity.isEmpty || !model.hasToken { showSettings() }
    }

    // A menu bar app has no visible main menu, but Cmd+V and friends only work through one
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func bindStatusItems() {
        model.$lux.sink { [weak self] value in
            self?.illuminanceItem.title = value.map { String(format: L("Illuminance: %.1f lx"), $0) } ?? L("Sensor unavailable")
        }.store(in: &subscriptions)
        model.$brightness.sink { [weak self] value in
            self?.brightnessItem.title = value.map { String(format: L("Brightness: %.0f%%"), $0 * 100) } ?? L("Brightness unavailable")
            self?.updateIcon(value)
        }.store(in: &subscriptions)
        model.$displayStatus.sink { [weak self] value in self?.displayStatusItem.title = value }
            .store(in: &subscriptions)
    }

    private func updateIcon(_ brightness: Double?) {
        let level = Int(((brightness ?? 0) * 100).rounded())
        guard level != iconLevel else { return }
        iconLevel = level
        statusItem.button?.image = Self.icon(level: Double(level) / 100)
    }

    private static func icon(level: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: 18.0 / 24)
            transform.concat()
            let center = NSPoint(x: 12, y: 8.75)
            func stroke(_ path: NSBezierPath, alpha: CGFloat = 1) {
                path.lineWidth = 2
                path.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: 10, startAngle: 180, endAngle: 0, clockwise: true)
            stroke(track, alpha: 0.3)
            if level > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: 10, startAngle: 180, endAngle: 180 - 180 * level, clockwise: true)
                stroke(arc)
            }
            for degrees in [40.0, 90, 140] {
                let angle = degrees * .pi / 180
                let ray = NSBezierPath()
                ray.move(to: NSPoint(x: center.x + 4.4 * cos(angle), y: center.y + 4.4 * sin(angle)))
                ray.line(to: NSPoint(x: center.x + 5.8 * cos(angle), y: center.y + 5.8 * sin(angle)))
                stroke(ray)
            }
            let sun = NSBezierPath()
            sun.appendArc(withCenter: center, radius: 2.9, startAngle: 0, endAngle: 180)
            sun.close()
            NSColor.black.setFill()
            sun.fill()
            let ground = NSBezierPath()
            ground.move(to: NSPoint(x: 1, y: 8.75))
            ground.line(to: NSPoint(x: 23, y: 8.75))
            ground.move(to: NSPoint(x: 7, y: 5.25))
            ground.line(to: NSPoint(x: 17, y: 5.25))
            stroke(ground)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("LuminTool auto brightness")
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in [illuminanceItem, brightnessItem, displayStatusItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let enabled = NSMenuItem(title: L("Auto brightness"), action: #selector(toggle), keyEquivalent: "")
        enabled.state = model.config.enabled ? .on : .off
        enabled.target = self
        menu.addItem(enabled)
        for (title, action) in [(L("Settings"), #selector(showSettings)), (L("Reset calibration"), #selector(reset)), (L("Quit LuminTool"), #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    @objc func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "LuminTool"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggle() { model.toggleEnabled() }
    @objc private func reset() {
        let alert = NSAlert()
        alert.messageText = L("Reset calibration for this sensor and monitor?")
        alert.informativeText = L("The current brightness becomes the starting point.")
        alert.addButton(withTitle: L("Reset"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { model.resetCalibration() }
    }
    @objc private func quit() { model.stop(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--probe") {
    Task { @MainActor in
        do {
            let brightnessService = SystemBrightness()
            let monitors = Monitor.connected()
            for monitor in monitors {
                print("Monitor: \(monitor.name), UUID: \(monitor.id)")
                let brightness = try await brightnessService.brightness(display: monitor.id)
                print("Brightness: \(brightness)")
            }
            if monitors.isEmpty { throw LuminToolError.message("No external monitor detected") }
            exit(0)
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    app.run()
} else {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
