import AppKit
import Combine
import SwiftUI
import LuminToolCore
import ServiceManagement

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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: Configuration
    @Published private(set) var sensors: [LightSensor] = []
    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var lux: Double?
    @Published private(set) var brightness: Double?
    @Published private(set) var sourceStatus = L("Enter a Home Assistant token")
    @Published private(set) var displayStatus = L("Checking the monitor…")
    @Published private(set) var hasToken = false
    @Published private(set) var hasMQTTPassword = false
    @Published private(set) var hasESPHomePassword = false
    @Published private(set) var serialPorts: [String] = []
    @Published private(set) var language = AppModel.storedLanguage
    @Published private(set) var update = UpdatePhase.idle
    private let brightnessService = SystemBrightness()
    private let ha = HomeAssistantConnection()
    private let mqtt = MQTTConnection()
    private let serial = SerialConnection()
    private let esphome = ESPHomeConnection()
    private let updater = Updater()
    private var engine = AdaptiveBrightness()
    private var controlTask: Task<Void, Never>?
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var sourceRunning = false

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
        ha.onStatus = { [weak self] in self?.sourceStatus = $0 }
        mqtt.onLux = { [weak self] value in
            self?.lux = value
            self?.engine.sensor(value)
        }
        mqtt.onStatus = { [weak self] in self?.sourceStatus = $0 }
        serial.onLux = { [weak self] value in
            self?.lux = value
            self?.engine.sensor(value)
        }
        serial.onStatus = { [weak self] in self?.sourceStatus = $0 }
        esphome.onSensors = { [weak self] in self?.sensors = $0 }
        esphome.onSelection = { [weak self] key in
            guard let self, self.config.esphome.sensor != key else { return }
            self.config.esphome.sensor = key
            self.saveConfiguration()
            self.loadCurve()
        }
        esphome.onLux = { [weak self] value in
            self?.lux = value
            self?.engine.sensor(value)
        }
        esphome.onStatus = { [weak self] in self?.sourceStatus = $0 }
        updater.onChange = { [weak self] in self?.update = $0 }
        refreshSerialPorts()
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

    private func saveConfiguration() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "configuration") }
    }

    private func loadCurve() {
        let curve = UserDefaults.standard.data(forKey: config.curveKey)
            .flatMap { try? JSONDecoder().decode(BrightnessCurve.self, from: $0) } ?? BrightnessCurve()
        engine = AdaptiveBrightness(curve: curve)
        engine.sensor(lux)
    }

    private func saveCurve() {
        if let data = try? JSONEncoder().encode(engine.curve) { UserDefaults.standard.set(data, forKey: config.curveKey) }
    }

    static var storedLanguage: AppLanguage {
        AppLanguage(appleLanguages: UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])
    }

    static func localization(for language: AppLanguage) -> String {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return language.localization(systemPreferred: global as? [String] ?? Locale.preferredLanguages)
    }

    static func applyLocalization(_ language: AppLanguage) {
        Localization.bundle = Bundle.main.path(forResource: localization(for: language), ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    private static let translations = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "ru")
        .flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] }.map { [$0] } ?? []

    func chooseLanguage(_ value: AppLanguage) {
        if let languages = value.appleLanguages {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        Self.applyLocalization(value)
        if let key = LocalizedKey.find(sourceStatus, in: Self.translations) { sourceStatus = L(key) }
        if let key = LocalizedKey.find(displayStatus, in: Self.translations) { displayStatus = L(key) }
        language = value
    }

    func refreshMonitors() {
        monitors = Monitor.connected()
        // Screen changes fire on every monitor sleep and wake; reconnecting the source there drops a value MQTT may not resend
        guard sourceRunning else { start(); return }
        stopControl()
        startControl()
    }

    func stop() {
        stopControl()
        sourceRunning = false
        ha.stop()
        mqtt.stop()
        serial.stop()
        esphome.stop()
    }

    private func stopControl() {
        generation += 1
        controlTask?.cancel()
        controlTask = nil
        engine.resetObservation()
    }

    func start() {
        stop()
        guard !sleeping else { return }
        saveConfiguration()
        switch config.source {
        case .homeAssistant:
            do {
                let endpoint = try HomeAssistantEndpoint(config.server)
                if let token = try TokenStore.read(account: endpoint.base.absoluteString), !token.isEmpty {
                    hasToken = true
                    ha.start(endpoint: endpoint, token: token, selected: config.entity)
                } else {
                    hasToken = false
                    sourceStatus = L("Enter a Home Assistant token in Settings")
                }
            } catch { hasToken = false; sourceStatus = error.localizedDescription }
        case .mqtt:
            hasToken = false
            hasMQTTPassword = false
            guard config.hasSensor else { sourceStatus = L("Enter an MQTT broker and topic in Settings"); break }
            do {
                let endpoint = try MQTTEndpoint(config.mqtt.broker)
                let topic = try MQTTTopic.validated(config.mqtt.topic)
                let username = config.mqtt.username
                let password = try username.isEmpty ? nil : TokenStore.read(account: "\(config.mqtt.broker)|\(username)", service: TokenStore.mqttService)
                hasMQTTPassword = password?.isEmpty == false
                mqtt.start(endpoint: endpoint, username: username, password: password ?? "", topic: topic, keyPath: config.mqtt.keyPath)
            } catch { sourceStatus = error.localizedDescription }
        case .serial:
            hasToken = false
            guard config.hasSensor else { sourceStatus = L("Choose a USB port in Settings"); break }
            serial.start(path: config.serial.port, baud: config.serial.baud)
        case .esphome:
            hasToken = false
            hasESPHomePassword = false
            guard !config.esphome.address.isEmpty else { sourceStatus = L("Enter an ESPHome address in Settings"); break }
            do {
                let endpoint = try ESPHomeEndpoint(config.esphome.address)
                let username = config.esphome.username
                let password = try username.isEmpty ? nil : TokenStore.read(account: "\(endpoint.address)|\(username)", service: TokenStore.esphomeService)
                hasESPHomePassword = password?.isEmpty == false
                esphome.start(endpoint: endpoint, username: username, password: password ?? "", selected: config.esphome.sensor)
            } catch { sourceStatus = error.localizedDescription }
        }
        sourceRunning = true
        startControl()
    }

    private func startControl() {
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
            guard config.enabled, config.hasSensor else { engine.resetObservation(); return }
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

    func connectMQTT(broker: String, username: String, password: String, topic: String, keyPath: String) throws {
        let endpoint = try MQTTEndpoint(broker)
        let topic = try MQTTTopic.validated(topic)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty || password.isEmpty else { throw LuminToolError.message(L("Enter a login for the password.")) }
        if !password.isEmpty {
            try TokenStore.save(password, account: "\(endpoint.address)|\(username)", service: TokenStore.mqttService)
        }
        stop()
        config.mqtt.broker = endpoint.address
        config.mqtt.username = username
        config.mqtt.topic = topic
        config.mqtt.keyPath = keyPath.trimmingCharacters(in: .whitespaces)
        loadCurve()
        start()
    }

    func chooseSource(_ kind: SourceKind) {
        guard kind != config.source else { return }
        stop()
        sensors = []
        config.source = kind
        loadCurve()
        start()
    }

    func refreshSerialPorts() {
        serialPorts = SerialPorts.candidates((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
    }

    func connectESPHome(address: String, username: String, password: String) throws {
        let endpoint = try ESPHomeEndpoint(address)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty || password.isEmpty else { throw LuminToolError.message(L("Enter a login for the password.")) }
        if !password.isEmpty {
            try TokenStore.save(password, account: "\(endpoint.address)|\(username)", service: TokenStore.esphomeService)
        }
        stop()
        if config.esphome.address != endpoint.address {
            config.esphome.sensor = ""
            sensors = []
        }
        config.esphome.address = endpoint.address
        config.esphome.username = username
        loadCurve()
        start()
    }

    func chooseSerialPort(_ path: String) {
        stop()
        config.serial.port = path
        loadCurve()
        start()
    }

    func chooseSerialBaud(_ baud: Int) {
        stop()
        config.serial.baud = baud
        loadCurve()
        start()
    }

    func chooseSensor(_ entity: String) {
        stop()
        config.entity = entity
        loadCurve()
        start()
    }

    func chooseESPHomeSensor(_ key: String) {
        stop()
        config.esphome.sensor = key
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

    func startUpdateChecks() {
        updater.startAutomaticChecks(enabled: { [weak self] in self?.config.checkUpdates ?? false })
    }

    func checkForUpdates() { updater.check(manual: true) }

    func installUpdate() { updater.install(beforeQuit: { [weak self] in self?.stop() }) }

    func chooseCheckUpdates(_ on: Bool) {
        config.checkUpdates = on
        saveConfiguration()
        if on { updater.checkIfDue() }
    }

    func openReleasePage() { NSWorkspace.shared.open(updater.source.page) }

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
    @State private var broker = ""
    @State private var mqttUser = ""
    @State private var mqttPassword = ""
    @State private var topic = ""
    @State private var keyPath = ""
    @State private var esphomeAddress = ""
    @State private var esphomeUser = ""
    @State private var esphomePassword = ""
    @State private var error = ""
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError = ""

    @State private var advanced = false

    private var brightnessNote: String? {
        [L("Auto brightness on"), L("Auto brightness paused")].contains(model.displayStatus) ? nil : model.displayStatus
    }

    private var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var warning: String? {
        switch model.config.source {
        case .homeAssistant:
            return (try? HomeAssistantEndpoint(server))?.base.scheme == "http"
                ? L("HTTP does not encrypt the token. Use HTTPS for a secure connection.") : nil
        case .mqtt:
            return !mqttUser.isEmpty && (try? MQTTEndpoint(broker))?.tls == false
                ? L("The password is sent unencrypted. Use mqtts:// for a secure connection.") : nil
        case .esphome:
            return !esphomeUser.isEmpty && (try? ESPHomeEndpoint(esphomeAddress))?.base.scheme == "http"
                ? L("The password may be sent unencrypted over http.") : nil
        case .serial:
            return nil
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: Binding(get: { model.config.source }, set: { error = ""; model.chooseSource($0) })) {
                    Text(verbatim: "Home Assistant").tag(SourceKind.homeAssistant)
                    Text(verbatim: "MQTT").tag(SourceKind.mqtt)
                    Text(verbatim: "USB").tag(SourceKind.serial)
                    Text(verbatim: "ESPHome").tag(SourceKind.esphome)
                }
                switch model.config.source {
                case .homeAssistant: homeAssistantFields
                case .mqtt: mqttFields
                case .esphome: esphomeFields
                case .serial: serialFields
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(model.lux == nil ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(verbatim: model.sourceStatus).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                LabeledContent("Illuminance") {
                    Text(verbatim: model.lux.map { String(format: "%.1f lx", $0) } ?? "—").monospacedDigit()
                }
            } header: {
                Text("Light sensor")
            } footer: {
                if warning != nil || !error.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        if !error.isEmpty { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    }
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                }
            }
            Section {
                Picker("Monitor", selection: Binding(get: { model.config.monitor }, set: model.chooseMonitor)) {
                    Text("Choose a monitor").tag("")
                    if !model.config.monitor.isEmpty && !model.monitors.contains(where: { $0.id == model.config.monitor }) {
                        Text("Monitor disconnected").tag(model.config.monitor)
                    }
                    ForEach(model.monitors) { monitor in Text(monitor.name).tag(monitor.id) }
                }
                Toggle("Auto brightness", isOn: Binding(get: { model.config.enabled }, set: { _ in model.toggleEnabled() }))
                LabeledContent("Current brightness") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: model.brightness.map { String(format: "%.0f%%", $0 * 100) } ?? "—").monospacedDigit()
                        if let brightnessNote { Text(verbatim: brightnessNote).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } header: {
                Text("Brightness")
            } footer: {
                Text("Set the brightness you like, and LuminTool remembers it for this light level.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setOpenAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow LuminTool in Login Items.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Picker("Language", selection: Binding(get: { model.language }, set: model.chooseLanguage)) {
                    Text("System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "Русский").tag(AppLanguage.russian)
                }
                Toggle("Check for updates automatically", isOn: Binding(get: { model.config.checkUpdates }, set: model.chooseCheckUpdates))
                updateRow
            } header: {
                Text("General")
            } footer: {
                VStack(spacing: 12) {
                    if !loginError.isEmpty {
                        Label(loginError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    }
                    if let version {
                        Text(verbatim: "LuminTool \(version)").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, Locale(identifier: AppModel.localization(for: model.language)))
        .frame(width: 416)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loginStatus = SMAppService.mainApp.status
            server = model.config.server
            broker = model.config.mqtt.broker
            mqttUser = model.config.mqtt.username
            topic = model.config.mqtt.topic
            keyPath = model.config.mqtt.keyPath
            advanced = !keyPath.isEmpty
            esphomeAddress = model.config.esphome.address
            esphomeUser = model.config.esphome.username
            model.refreshSerialPorts()
        }
    }

    @ViewBuilder private var updateRow: some View {
        if case .failed(let problem) = model.update, problem == .install || problem == .blocked {
            VStack(alignment: .leading, spacing: 8) {
                updateText
                Button("Open release page") { model.openReleasePage() }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack {
                updateText
                Spacer()
                updateControl
            }
        }
    }

    @ViewBuilder private var updateText: some View {
        switch model.update {
        case .idle: Text("Updates")
        case .checking: Text("Checking for updates…")
        case .upToDate: Text("LuminTool is up to date")
        case .available(let offer): Text(verbatim: String(format: L("Version %@ is available"), offer.version))
        case .notInstallable(let version): Text(verbatim: String(format: L("Version %@ is available"), version))
        case .downloading: Text("Downloading the update…")
        case .installing: Text("Installing the update…")
        case .installed(let version):
            Text(verbatim: String(format: L("Version %@ is installed. Quit LuminTool and open it again."), version))
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let problem):
            Label(problem.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var updateControl: some View {
        switch model.update {
        case .checking, .downloading, .installing: ProgressView().controlSize(.small)
        case .available: Button("Update") { model.installUpdate() }
        case .notInstallable: Button("Open release page") { model.openReleasePage() }
        case .installed: Button("Quit") { model.stop(); NSApp.terminate(nil) }
        default: Button("Check now") { model.checkForUpdates() }
        }
    }

    @ViewBuilder private var homeAssistantFields: some View {
        TextField("Address", text: $server, prompt: Text(verbatim: "http://homeassistant.local:8123"))
        SecureField("Token", text: $token, prompt: Text(model.hasToken ? "Saved" : "Long-lived token"))
        HStack {
            Spacer()
            Button("Create token") {
                if let endpoint = try? HomeAssistantEndpoint(server) {
                    NSWorkspace.shared.open(endpoint.base.appendingPathComponent("profile/security"))
                }
            }
            Button("Connect") {
                do { try model.connect(server: server, token: token); token = ""; error = "" }
                catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction)
        }
        Picker("Sensor", selection: Binding(get: { model.config.entity }, set: model.chooseSensor)) {
            Text("Auto").tag("")
            if !model.config.entity.isEmpty && !model.sensors.contains(where: { $0.id == model.config.entity }) {
                Text(model.config.entity).tag(model.config.entity)
            }
            ForEach(model.sensors) { sensor in Text("\(sensor.name) — \(sensor.id)").tag(sensor.id) }
        }
    }

    @ViewBuilder private var mqttFields: some View {
        TextField("Broker", text: $broker, prompt: Text(verbatim: "mqtt://homeassistant.local"))
        TextField("Login", text: $mqttUser, prompt: Text("Optional"))
        SecureField("Password", text: $mqttPassword, prompt: Text(model.hasMQTTPassword ? "Saved" : "Optional"))
        TextField("Topic", text: $topic, prompt: Text(verbatim: "zigbee2mqtt/sensor"))
        Button { advanced.toggle() } label: {
            HStack {
                Text("Advanced")
                Spacer()
                Image(systemName: advanced ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if advanced {
            TextField("JSON key", text: $keyPath, prompt: Text("Auto"))
        }
        HStack {
            Spacer()
            Button("Connect") {
                do {
                    try model.connectMQTT(broker: broker, username: mqttUser, password: mqttPassword, topic: topic, keyPath: keyPath)
                    mqttPassword = ""
                    error = ""
                } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var esphomeFields: some View {
        TextField("Address", text: $esphomeAddress, prompt: Text(verbatim: "sensor.local"))
        TextField("Login", text: $esphomeUser, prompt: Text("Optional"))
        SecureField("Password", text: $esphomePassword, prompt: Text(model.hasESPHomePassword ? "Saved" : "Optional"))
        HStack {
            Spacer()
            Button("Connect") {
                do {
                    try model.connectESPHome(address: esphomeAddress, username: esphomeUser, password: esphomePassword)
                    esphomePassword = ""
                    error = ""
                } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction)
        }
        Picker("Sensor", selection: Binding(get: { model.config.esphome.sensor }, set: model.chooseESPHomeSensor)) {
            Text("Auto").tag("")
            if !model.config.esphome.sensor.isEmpty && !model.sensors.contains(where: { $0.id == model.config.esphome.sensor }) {
                Text(verbatim: model.config.esphome.sensor).tag(model.config.esphome.sensor)
            }
            ForEach(model.sensors) { sensor in Text(verbatim: sensor.name).tag(sensor.id) }
        }
    }

    @ViewBuilder private var serialFields: some View {
        HStack {
            Picker("Port", selection: Binding(get: { model.config.serial.port }, set: model.chooseSerialPort)) {
                Text("Choose a port").tag("")
                if !model.config.serial.port.isEmpty && !model.serialPorts.contains(model.config.serial.port) {
                    Text(verbatim: model.config.serial.port).tag(model.config.serial.port)
                }
                ForEach(model.serialPorts, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Button("Refresh") { model.refreshSerialPorts() }
        }
        Picker("Speed", selection: Binding(get: { model.config.serial.baud }, set: model.chooseSerialBaud)) {
            ForEach([9600, 19200, 38400, 57600, 115200], id: \.self) { Text(verbatim: String($0)).tag($0) }
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
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
        Updater.repairLoginItemAfterUpdate()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installEditMenu()
        bindStatusItems()
        model.start()
        model.startUpdateChecks()
        if !model.config.hasSensor || (model.config.source == .homeAssistant && !model.hasToken) { showSettings() }
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

    private func showIlluminance(_ value: Double?) {
        illuminanceItem.title = value.map { String(format: L("Illuminance: %.1f lx"), $0) } ?? L("Sensor unavailable")
    }

    private func showBrightness(_ value: Double?) {
        brightnessItem.title = value.map { String(format: L("Brightness: %.0f%%"), $0 * 100) } ?? L("Brightness unavailable")
    }

    private func bindStatusItems() {
        model.$lux.sink { [weak self] value in self?.showIlluminance(value) }.store(in: &subscriptions)
        model.$brightness.sink { [weak self] value in
            self?.showBrightness(value)
            self?.updateIcon(value)
        }.store(in: &subscriptions)
        model.$language.sink { [weak self] _ in
            guard let self else { return }
            self.showIlluminance(self.model.lux)
            self.showBrightness(self.model.brightness)
        }.store(in: &subscriptions)
        model.$displayStatus.sink { [weak self] value in
            self?.displayStatusItem.title = value
            self?.displayStatusItem.isHidden = [L("Auto brightness on"), L("Auto brightness paused")].contains(value)
        }.store(in: &subscriptions)
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
        switch model.update {
        case .available(let offer): addUpdateItem(to: menu, title: String(format: L("Update to %@"), offer.version), action: #selector(installUpdate))
        case .notInstallable(let version): addUpdateItem(to: menu, title: String(format: L("Update to %@"), version), action: #selector(openReleasePage))
        case .downloading: addUpdateItem(to: menu, title: L("Downloading the update…"), action: nil)
        case .installing: addUpdateItem(to: menu, title: L("Installing the update…"), action: nil)
        case .installed(let version):
            addUpdateItem(to: menu, title: String(format: L("Version %@ is installed. Quit LuminTool and open it again."), version), action: nil)
        case .failed(let problem) where problem != .unavailable && problem != .rateLimited:
            addUpdateItem(to: menu, title: problem.message, action: nil)
            addUpdateItem(to: menu, title: L("Open release page"), action: #selector(openReleasePage))
        default: break
        }
        for (title, action) in [(L("Settings"), #selector(showSettings)), (L("Reset calibration"), #selector(reset)), (L("Quit"), #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    private func addUpdateItem(to menu: NSMenu, title: String, action: Selector?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        menu.addItem(item)
    }

    @objc private func installUpdate() { model.installUpdate() }
    @objc private func openReleasePage() { model.openReleasePage() }

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
        window?.makeFirstResponder(nil)
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
        AppModel.applyLocalization(AppModel.storedLanguage)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
