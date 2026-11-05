import Foundation

public enum SourceKind: String, Codable, CaseIterable {
    case homeAssistant, mqtt, serial, esphome
}

public struct MQTTSettings: Codable {
    public var broker = ""
    public var username = ""
    public var topic = ""
    public var keyPath = ""
    public init() {}
}

public struct SerialSettings: Codable {
    public var port = ""
    public var baud = 115200
    public init() {}
}

public struct ESPHomeSettings: Codable {
    public var address = ""
    public var username = ""
    public var sensor = ""
    public init() {}
}

public struct Configuration: Codable {
    public var server = "http://homeassistant.local:8123"
    public var entity = ""
    public var monitor = ""
    public var enabled = true
    public var source = SourceKind.homeAssistant
    public var mqtt = MQTTSettings()
    public var serial = SerialSettings()
    public var esphome = ESPHomeSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Configuration()
        server = (try? values.decodeIfPresent(String.self, forKey: .server)) ?? defaults.server
        entity = (try? values.decodeIfPresent(String.self, forKey: .entity)) ?? defaults.entity
        monitor = (try? values.decodeIfPresent(String.self, forKey: .monitor)) ?? defaults.monitor
        enabled = (try? values.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        source = (try? values.decodeIfPresent(SourceKind.self, forKey: .source)) ?? defaults.source
        mqtt = (try? values.decodeIfPresent(MQTTSettings.self, forKey: .mqtt)) ?? defaults.mqtt
        serial = (try? values.decodeIfPresent(SerialSettings.self, forKey: .serial)) ?? defaults.serial
        esphome = (try? values.decodeIfPresent(ESPHomeSettings.self, forKey: .esphome)) ?? defaults.esphome
    }

    public var hasSensor: Bool {
        switch source {
        case .homeAssistant: return !entity.isEmpty
        case .mqtt: return !mqtt.broker.isEmpty && !mqtt.topic.isEmpty
        case .serial: return !serial.port.isEmpty
        case .esphome: return !esphome.address.isEmpty && !esphome.sensor.isEmpty
        }
    }

    public var curveKey: String {
        let prefix: String
        let parts: [String]
        switch source {
        case .homeAssistant: prefix = "curve."; parts = [server, entity, monitor]
        case .mqtt: prefix = "curve.mqtt."; parts = [mqtt.broker, mqtt.topic, mqtt.keyPath, monitor]
        case .serial: prefix = "curve.serial."; parts = [serial.port, monitor]
        case .esphome: prefix = "curve.esphome."; parts = [esphome.address, esphome.sensor, monitor]
        }
        return prefix + Data((try! JSONEncoder().encode(parts))).base64EncodedString()
    }
}
