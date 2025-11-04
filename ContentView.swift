//
//  ContentView.swift
//  Alarma
//
//  Created by Carlos Munevar on 28/10/25.
//

import SwiftUI
import CoreLocation
import Combine
import MapKit
import UserNotifications
import Network
import UIKit
import ObjectiveC

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Tuya Client (placeholder)
    struct TuyaCommand: Encodable {
        let code: String
        let value: AnyEncodable
    }

    struct AnyEncodable: Encodable {
        private let _encode: (Encoder) throws -> Void
        init<T: Encodable>(_ wrapped: T) { self._encode = wrapped.encode }
        func encode(to encoder: Encoder) throws { try _encode(encoder) }
    }

    final class TuyaClientService {
        // Configure an optional backend endpoint if you have a server that talks to Tuya Cloud.
        // If not, this will just log locally.
        var backendURL: URL?
        var deviceID: String

        init(deviceID: String, backendURL: URL? = nil) {
            self.deviceID = deviceID
            self.backendURL = backendURL
        }

        @MainActor
        func sendCommand(code: String, value: Any) async {
            print("📡 Tuya send_command \(code) → \(value)")
            guard let backendURL else { return }
            var request = URLRequest(url: backendURL.appendingPathComponent("send_command"))
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "device_id": deviceID,
                "code": code,
                "value": value
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    print("Tuya backend status: \(http.statusCode)")
                }
                if let json = try? JSONSerialization.jsonObject(with: data) {
                    print("Tuya backend response: \(json)")
                }
            } catch {
                print("[Tuya] request failed: \(error)")
            }
        }

        @MainActor
        func sendCommands(_ commands: [[String: Any]]) async {
            print("📡 Tuya enviando \(commands.count) comandos")
            guard let backendURL else { return }
            var request = URLRequest(url: backendURL.appendingPathComponent("send_commands"))
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "device_id": deviceID,
                "commands": commands
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    print("Tuya backend status: \(http.statusCode)")
                }
                if let json = try? JSONSerialization.jsonObject(with: data) {
                    print("Tuya backend response: \(json)")
                }
            } catch {
                print("[Tuya] request failed: \(error)")
            }
        }

        @MainActor
        func activateAlarm() async {
            await sendCommands([
                ["code": "switch_alarm_sound", "value": true],
                ["code": "switch_alarm_light", "value": true]
            ])
        }

        @MainActor
        func deactivateAlarm() async {
            await sendCommands([
                ["code": "switch_alarm_sound", "value": false],
                ["code": "switch_alarm_light", "value": false]
            ])
        }
    }

    enum MQTTTransport: String, CaseIterable, Identifiable {
        case tcp
        var id: String { rawValue }
    }

    // MARK: - Cliente MQTT TCP + TLS
    @MainActor
    final class SimpleMQTTOverTCP {
        private var connection: NWConnection?
        private var host: NWEndpoint.Host
        private var port: NWEndpoint.Port
        private var useTLS: Bool
        private var isConnected = false
        private var hostName: String
        private var clientID: String
        private var username: String?
        private var password: String?
        private var receiveBuffer = Data()
        private var packetIdentifier: UInt16 = 1
        private var isConnecting = false
        private var pendingMessages: [(topic: String, message: String, qos: UInt8)] = []

        private let maximumPacketSize = 256 * 1024
        private let maximumBufferedBytes = 512 * 1024

        var onMessage: ((String, String) -> Void)?
        var onConnected: (() -> Void)?
        var onConnectionStateChange: ((Bool) -> Void)?

        init(host: String, port: UInt16, useTLS: Bool, clientID: String, username: String? = nil, password: String? = nil) {
            self.host = NWEndpoint.Host(host)
            self.hostName = host
            self.port = NWEndpoint.Port(rawValue: port) ?? 8883
            self.useTLS = useTLS
            self.clientID = clientID
            self.username = username
            self.password = password
        }

        func connect() {
            if isConnected {
                print("[MQTT-TCP] connect() ignored: already connected")
                return
            }
            if isConnecting {
                print("[MQTT-TCP] connect() ignored: handshake in progress")
                return
            }
            isConnecting = true

            connection?.cancel()
            connection = nil
            let parameters = NWParameters.tcp
            if useTLS {
                let tlsOptions = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, hostName)
                parameters.defaultProtocolStack.applicationProtocols.insert(tlsOptions, at: 0)
            }

            connection = NWConnection(host: host, port: port, using: parameters)

            connection?.stateUpdateHandler = { [weak self] state in
                guard let strongSelf = self else { return }
                Task { @MainActor [weak strongSelf] in
                    guard let self = strongSelf else { return }
                    switch state {
                    case .ready:
                        print("[MQTT-TCP] connection ready")
                        self.sendConnectPacket()
                        self.receiveLoop()
                    case .failed(let error):
                        print("[MQTT-TCP] failed: \(error)")
                        self.isConnected = false
                        self.isConnecting = false
                        self.receiveBuffer.removeAll()
                        self.connection = nil
                        self.onConnectionStateChange?(false)
                    case .waiting(let error):
                        print("[MQTT-TCP] waiting: \(error)")
                    case .cancelled:
                        print("[MQTT-TCP] connection cancelled")
                        self.isConnected = false
                        self.isConnecting = false
                        self.receiveBuffer.removeAll()
                        self.connection = nil
                        self.onConnectionStateChange?(false)
                    default:
                        break
                    }
                }
            }

            connection?.start(queue: .main)
            receiveBuffer.removeAll()
            packetIdentifier = 1
        }

        func disconnect() {
            connection?.cancel()
            connection = nil
            isConnected = false
            isConnecting = false
            receiveBuffer.removeAll()
            packetIdentifier = 1
            pendingMessages.removeAll()
            onConnectionStateChange?(false)
        }

        private func receiveLoop() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let strongSelf = self else { return }
                Task { @MainActor [weak strongSelf] in
                    guard let self = strongSelf else { return }
                    if let error = error {
                        print("[MQTT-TCP] receive error: \(error)")
                        self.isConnected = false
                        self.receiveBuffer.removeAll()
                        self.onConnectionStateChange?(false)
                        return
                    }
                    if let data = data, !data.isEmpty {
                        self.handleIncoming(data)
                    }
                    if !isComplete {
                        self.receiveLoop()
                    }
                }
            }
        }

        private func handleIncoming(_ data: Data) {
            receiveBuffer.append(data)
            if receiveBuffer.count > maximumBufferedBytes {
                print("[MQTT-TCP] receive buffer overflow; dropping \(receiveBuffer.count) bytes")
                receiveBuffer.removeAll()
                return
            }
            processReceiveBuffer()
        }

        private func processReceiveBuffer() {
            while let (packet, headerLength, remainingLength) = nextPacket() {
                processPacket(packet, headerLength: headerLength, remainingLength: remainingLength)
            }
        }

        private func nextPacket() -> (packet: Data, headerLength: Int, remainingLength: Int)? {
            guard receiveBuffer.count >= 2 else { return nil }

            var multiplier = 1
            var value = 0
            var index = 1
            var encodedByte: UInt8 = 0

            repeat {
                if index >= receiveBuffer.count { return nil }
                encodedByte = receiveBuffer[index]
                value += Int(encodedByte & 0x7F) * multiplier
                if value > maximumPacketSize {
                    print("[MQTT-TCP] nextPacket(): remaining length too large (\(value)); clearing buffer")
                    receiveBuffer.removeAll()
                    return nil
                }
                multiplier *= 128
                index += 1
                if index > 5 { return nil }
            } while (encodedByte & 0x80) != 0

            let headerLength = index
            let totalLength = headerLength + value
            guard totalLength >= headerLength else {
                receiveBuffer.removeAll()
                return nil
            }
            guard receiveBuffer.count >= totalLength else { return nil }

            let packet = receiveBuffer.prefix(totalLength)
            if receiveBuffer.count >= totalLength {
                receiveBuffer.removeSubrange(0..<totalLength)
            } else {
                receiveBuffer.removeAll()
                return nil
            }

            return (Data(packet), headerLength, value)
        }

        private func processPacket(_ packet: Data, headerLength: Int, remainingLength: Int) {
            guard let firstByte = packet.first else { return }
            let packetType = firstByte & 0xF0

            switch packetType {
            case 0x20: // CONNACK
                isConnected = true
                isConnecting = false
                print("[MQTT-TCP] CONNACK received ✅")
                onConnectionStateChange?(true)
                onConnected?()
                flushPendingMessages()
            case 0x30, 0x31, 0x32, 0x33: // PUBLISH (varies with flags)
                handlePublishPacket(packet, headerLength: headerLength)
            case 0x90: // SUBACK
                print("[MQTT-TCP] SUBACK received")
            case 0xD0: // PINGRESP
                print("[MQTT-TCP] PINGRESP received")
            default:
                print("[MQTT-TCP] Unhandled packet type: 0x\(String(packetType, radix: 16))")
            }
        }

        private func handlePublishPacket(_ packet: Data, headerLength: Int) {
            let qos = (packet[0] & 0x06) >> 1
            var index = headerLength

            guard index + 1 < packet.count else { return }
            let topicLength = Int(packet[index]) << 8 | Int(packet[index + 1])
            index += 2
            guard index + topicLength <= packet.count else { return }
            let topicData = packet.subdata(in: index..<(index + topicLength))
            index += topicLength

            var messageIdentifier: UInt16?
            if qos > 0 {
                guard index + 1 < packet.count else { return }
                messageIdentifier = UInt16(packet[index]) << 8 | UInt16(packet[index + 1])
                index += 2
            }

            guard index <= packet.count else { return }
            let payloadData = packet.subdata(in: index..<packet.count)

            guard let topic = String(data: topicData, encoding: .utf8) else { return }
            let message = String(data: payloadData, encoding: .utf8) ?? ""

            print("[MQTT-TCP] PUBLISH received topic=\(topic) msg=\(message)")
            onMessage?(topic, message)

            if qos == 1, let messageIdentifier {
                sendPubAck(messageID: messageIdentifier)
            }
        }

        private func send(_ data: Data) {
            connection?.send(content: data, completion: .contentProcessed({ _ in }))
        }

        private func sendConnectPacket() {
            let protocolName: [UInt8] = [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54]
            let protocolLevel: UInt8 = 0x04
            var connectFlags: UInt8 = 0x02
            if username != nil { connectFlags |= 0x80 }
            if password != nil { connectFlags |= 0x40 }
            let keepAlive: UInt16 = 60

            let clientIDData = clientID.data(using: .utf8) ?? Data()
            var variableHeader = Data(protocolName)
            variableHeader.append(protocolLevel)
            variableHeader.append(connectFlags)
            variableHeader.append(contentsOf: [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)])

            var payload = Data()
            payload.append(contentsOf: [UInt8(clientIDData.count >> 8), UInt8(clientIDData.count & 0xFF)])
            payload.append(clientIDData)
            if let username = username, let uData = username.data(using: .utf8) {
                payload.append(contentsOf: [UInt8(uData.count >> 8), UInt8(uData.count & 0xFF)])
                payload.append(uData)
            }
            if let password = password, let pData = password.data(using: .utf8) {
                payload.append(contentsOf: [UInt8(pData.count >> 8), UInt8(pData.count & 0xFF)])
                payload.append(pData)
            }

            let remainingLength = variableHeader.count + payload.count
            var header = Data([0x10])
            header.append(encodeRemainingLength(remainingLength))

            var packet = Data()
            packet.append(header)
            packet.append(variableHeader)
            packet.append(payload)

            send(packet)
            print("[MQTT-TCP] CONNECT sent to \(host):\(port)")
        }

        private func encodeRemainingLength(_ length: Int) -> Data {
            var x = length
            var encoded = Data()
            repeat {
                var digit = UInt8(x % 128)
                x = x / 128
                if x > 0 { digit = digit | 0x80 }
                encoded.append(digit)
            } while x > 0
            return encoded
        }

        func publish(topic: String, message: String, qos: UInt8 = 0) {
            let entry = (topic: topic, message: message, qos: qos)

            guard isConnected else {
                if pendingMessages.count > 100 {
                    pendingMessages.removeFirst(pendingMessages.count - 100)
                }
                pendingMessages.append(entry)
                if !isConnecting {
                    print("[MQTT-TCP] Not connected; starting reconnect to publish message")
                    connect()
                } else {
                    print("[MQTT-TCP] Queued message while reconnecting")
                }
                return
            }
            sendPublish(entry)
        }

        private func sendPublish(_ entry: (topic: String, message: String, qos: UInt8)) {
            let topic = entry.topic
            let message = entry.message
            let qos = entry.qos

            let topicData = topic.data(using: .utf8) ?? Data()
            let messageData = message.data(using: .utf8) ?? Data()

            var variableHeader = Data()
            variableHeader.append(contentsOf: [UInt8(topicData.count >> 8), UInt8(topicData.count & 0xFF)])
            variableHeader.append(topicData)

            var fixedHeader = Data([0x30 | (qos << 1)])
            let remainingLength = variableHeader.count + messageData.count
            fixedHeader.append(encodeRemainingLength(remainingLength))

            var packet = Data()
            packet.append(fixedHeader)
            packet.append(variableHeader)
            packet.append(messageData)

            send(packet)
            print("[MQTT-TCP] PUBLISH sent topic=\(topic) msg=\(message)")
        }

        private func flushPendingMessages() {
            guard isConnected else { return }
            guard !pendingMessages.isEmpty else { return }
            let queued = pendingMessages
            pendingMessages.removeAll()
            for entry in queued {
                sendPublish(entry)
            }
        }

        func subscribe(topic: String, qos: UInt8 = 0) {
            guard isConnected else {
                print("[MQTT-TCP] Cannot SUBSCRIBE while disconnected; will retry after connect")
                return
            }

            let topicData = topic.data(using: .utf8) ?? Data()
            let identifier = nextPacketIdentifier()

            var variableHeader = Data()
            variableHeader.append(contentsOf: [UInt8(identifier >> 8), UInt8(identifier & 0xFF)])

            var payload = Data()
            payload.append(contentsOf: [UInt8(topicData.count >> 8), UInt8(topicData.count & 0xFF)])
            payload.append(topicData)
            payload.append(qos)

            let remainingLength = variableHeader.count + payload.count
            var packet = Data([0x82])
            packet.append(encodeRemainingLength(remainingLength))
            packet.append(variableHeader)
            packet.append(payload)

            send(packet)
            print("[MQTT-TCP] SUBSCRIBE sent topic=\(topic) qos=\(qos)")
        }

        private func nextPacketIdentifier() -> UInt16 {
            let identifier = packetIdentifier
            packetIdentifier = packetIdentifier == UInt16.max ? 1 : packetIdentifier + 1
            return identifier
        }

        private func sendPubAck(messageID: UInt16) {
            var packet = Data([0x40, 0x02])
            packet.append(UInt8(messageID >> 8))
            packet.append(UInt8(messageID & 0xFF))
            send(packet)
            print("[MQTT-TCP] PUBACK sent id=\(messageID)")
        }
    }

    // MARK: - Propiedades
    private let manager = CLLocationManager()
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var lastLocation: CLLocation?
    @Published var errorMessage: String?
    private var regionStates: [UUID: CLRegionState] = [:]

    @Published var tcpHost: String = "broker.qubitro.com"
    @Published var tcpPort: Int = 8883
    @Published var tcpUseTLS: Bool = true
    @Published var mqttClientID: String = "Alarma-iOS-\(UUID().uuidString)"
    @Published var mqttUsername: String = "nbasmbdasbdjhqwDJH"  // AJUSTA NOMBRE DE USUARIO MQTT
    @Published var mqttPassword: String = "HBASDHJSAJDBASBDMSABDJQWDJKQWB" // Ajusta clave mqtt
    @Published var mqttConnected: Bool = false
    @Published var mqttLastMessage: String?
    @Published var mqttRemoteStates: [String: Bool] = [:]

    // MARK: - Tuya
    @Published var tuyaDeviceID: String = ProcessInfo.processInfo.environment["TUYA_DEVICE_ID"] ?? "eb474eb19fe37d50aew661"
    @Published var tuyaBackendURLString: String? = nil // e.g., "https://your-backend.example.com"
    private lazy var tuyaClient = TuyaClientService(deviceID: tuyaDeviceID,
                                                    backendURL: tuyaBackendURLString.flatMap { URL(string: $0) })

    private lazy var mqttTCPClient: SimpleMQTTOverTCP = makeMQTTClient(host: tcpHost,
                                                                       port: UInt16(tcpPort),
                                                                       useTLS: tcpUseTLS)
    private let maxMonitoredRegions = 20

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        UNUserNotificationCenter.current().delegate = self
        requestNotificationAuthorization()
        requestAlwaysAuthorization()
        startMonitoringFixedPlaces()
        mqttTCPClient.connect() // 🚀 conexión inicial segura con Qubitro

        // Tuya client is ready (uses optional backend). Calls happen on geofence changes.
    }

    func updateMQTTTCP(host: String, port: Int, useTLS: Bool) {
        tcpHost = host
        tcpPort = port
        tcpUseTLS = useTLS
        mqttTCPClient.disconnect()
        mqttLastMessage = nil
        mqttRemoteStates.removeAll()
        mqttConnected = false
        mqttTCPClient = makeMQTTClient(host: host, port: UInt16(port), useTLS: useTLS)
        mqttTCPClient.connect()
    }

    private func publishMQTT(place: String, inside: Bool) {
        let topic = "alarma/\(place.lowercased())"
        let message = "\(place.lowercased())=\(inside ? 1 : 0)"
        mqttTCPClient.publish(topic: topic, message: message)
    }

    // MARK: - Geocercas
    struct FixedPlace: Identifiable, Equatable {
        let id: UUID
        var name: String
        var coordinate: CLLocationCoordinate2D
        var radius: CLLocationDistance

        init(id: UUID = UUID(), name: String, coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) {
            self.id = id
            self.name = name
            self.coordinate = coordinate
            self.radius = radius
        }

        static func == (lhs: FixedPlace, rhs: FixedPlace) -> Bool {
            lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.radius == rhs.radius
        }
    }

    @Published var fixedPlaces: [FixedPlace] = [
        FixedPlace(name: "Negocio", coordinate: CLLocationCoordinate2D(latitude: 5.542903, longitude: -73.453934), radius: 5),
        FixedPlace(name: "Casa", coordinate: CLLocationCoordinate2D(latitude: 5.539757, longitude: -73.456240), radius: 5)
    ]

    // MARK: - Notificaciones y ubicación
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "Error en notificaciones: \(error.localizedDescription)"
                }
            }
        }
    }

    func requestAlwaysAuthorization() { manager.requestAlwaysAuthorization() }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func startMonitoringFixedPlaces() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            errorMessage = "El dispositivo no soporta geocercas."
            return
        }
        guard fixedPlaces.count <= maxMonitoredRegions else {
            errorMessage = "Puedes monitorear hasta \(maxMonitoredRegions) zonas."
            return
        }
        syncRegionStates()
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        for place in fixedPlaces {
            registerMonitoring(for: place)
        }
        manager.startUpdatingLocation()
    }

    func requestOneShotLocation() {
        manager.requestLocation()
    }

    func addPlace(at coordinate: CLLocationCoordinate2D) {
        guard fixedPlaces.count < maxMonitoredRegions else {
            errorMessage = "Puedes monitorear hasta \(maxMonitoredRegions) zonas."
            return
        }

        let baseName = "Lugar"
        var index = fixedPlaces.count + 1
        var candidate = "\(baseName) \(index)"
        let nameSet = Set(fixedPlaces.map(\.name))
        while nameSet.contains(candidate) {
            index += 1
            candidate = "\(baseName) \(index)"
        }

        let newPlace = FixedPlace(name: candidate, coordinate: coordinate, radius: 5)
        var updated = fixedPlaces
        updated.append(newPlace)
        regionStates[newPlace.id] = .unknown
        fixedPlaces = updated
        registerMonitoring(for: newPlace)
    }

    func updatePlace(id: UUID, coordinate: CLLocationCoordinate2D) {
        guard let idx = fixedPlaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = fixedPlaces
        updated[idx].coordinate = coordinate
        regionStates[id] = .unknown
        fixedPlaces = updated
        refreshMonitoring(for: updated[idx])
    }

    func removePlaces(at offsets: IndexSet) {
        var updated = fixedPlaces
        let ids = offsets.compactMap { updated[$0].id }
        updated.remove(atOffsets: offsets)
        for id in ids {
            regionStates.removeValue(forKey: id)
            stopMonitoring(for: id)
        }
        fixedPlaces = updated
    }

    func removePlace(with id: UUID) {
        guard let index = fixedPlaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = fixedPlaces
        updated.remove(at: index)
        regionStates.removeValue(forKey: id)
        stopMonitoring(for: id)
        fixedPlaces = updated
    }

    func updateName(for id: UUID, name: String) {
        guard let idx = fixedPlaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = fixedPlaces
        updated[idx].name = name
        regionStates[id] = .unknown
        fixedPlaces = updated
    }

    func updateRadius(for id: UUID, radius: CLLocationDistance) {
        guard let idx = fixedPlaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = fixedPlaces
        updated[idx].radius = radius
        regionStates[id] = .unknown
        fixedPlaces = updated
        refreshMonitoring(for: updated[idx])
    }

    // MARK: - CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            startMonitoringFixedPlaces()
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last

        // Fallback: if user is clearly outside by distance, force an OUTSIDE state
        guard let current = lastLocation else { return }
        for place in fixedPlaces {
            let center = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
            let distance = current.distance(from: center)
            // Use a reliability threshold: at least 50m or the place radius, whichever is larger
            let reliabilityThreshold = max(place.radius, 50)
            if distance > reliabilityThreshold {
                if regionStates[place.id] == .inside {
                    handleRegionStateChange(for: place, state: .outside)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let place = place(for: region) else { return }
        handleRegionStateChange(for: place, state: .inside)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let place = place(for: region) else { return }
        handleRegionStateChange(for: place, state: .outside)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let place = place(for: region) else { return }
        handleRegionStateChange(for: place, state: state)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }

    // MARK: - Helpers
    private func syncRegionStates() {
        let ids = Set(fixedPlaces.map(\.id))
        regionStates = regionStates.reduce(into: [UUID: CLRegionState]()) { partialResult, element in
            if ids.contains(element.key) {
                partialResult[element.key] = element.value
            }
        }
        for id in ids where regionStates[id] == nil {
            regionStates[id] = .unknown
        }
    }

    private func place(for region: CLRegion) -> FixedPlace? {
        if let uuid = UUID(uuidString: region.identifier),
           let place = fixedPlaces.first(where: { $0.id == uuid }) {
            return place
        }
        return fixedPlaces.first(where: { $0.name == region.identifier })
    }

    private func handleRegionStateChange(for place: FixedPlace, state: CLRegionState) {
        guard state != .unknown else { return }
        guard regionStates[place.id] != state else { return }
        regionStates[place.id] = state

        switch state {
        case .inside:
            sendNotification(title: "Llegaste a \(place.name)", body: "Estás dentro del área.")
            publishMQTT(place: place.name, inside: true)
            Task { @MainActor in
                await tuyaClient.activateAlarm()
            }
        case .outside:
            sendNotification(title: "Saliste de \(place.name)", body: "Abandonaste la zona.")
            publishMQTT(place: place.name, inside: false)
            Task { @MainActor in
                await tuyaClient.deactivateAlarm()
            }
        default:
            break
        }
    }

    private func registerMonitoring(for place: FixedPlace) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: place.coordinate,
                                      radius: place.radius,
                                      identifier: place.id.uuidString)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    private func refreshMonitoring(for place: FixedPlace) {
        stopMonitoring(for: place.id)
        registerMonitoring(for: place)
    }

    private func stopMonitoring(for id: UUID) {
        let targets = manager.monitoredRegions.filter { $0.identifier == id.uuidString }
        for region in targets {
            manager.stopMonitoring(for: region)
        }
    }

    private func makeMQTTClient(host: String, port: UInt16, useTLS: Bool) -> SimpleMQTTOverTCP {
        let client = SimpleMQTTOverTCP(host: host,
                                       port: port,
                                       useTLS: useTLS,
                                       clientID: mqttClientID,
                                       username: mqttUsername,
                                       password: mqttPassword)
        client.onConnectionStateChange = { [weak self] connected in
            guard let self = self else { return }
            self.mqttConnected = connected
        }
        client.onConnected = { [weak self] in
            self?.subscribeToDefaultTopics()
        }
        client.onMessage = { [weak self] topic, payload in
            self?.handleIncomingMQTT(topic: topic, payload: payload)
        }
        return client
    }

    private func subscribeToDefaultTopics() {
        mqttTCPClient.subscribe(topic: "alarma/#")
    }

    private func handleIncomingMQTT(topic: String, payload: String) {
        mqttLastMessage = "\(topic) → \(payload)"

        if let equalIndex = payload.firstIndex(of: "=") {
            let keyPart = payload[..<equalIndex]
            let valuePart = payload[payload.index(after: equalIndex)...]
            let normalizedKey = keyPart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let trimmedValue = valuePart.trimmingCharacters(in: .whitespacesAndNewlines)

            if let intValue = Int(trimmedValue) {
                mqttRemoteStates[normalizedKey] = intValue != 0
                return
            }

            let lowercased = trimmedValue.lowercased()
            if lowercased == "true" || lowercased == "false" {
                mqttRemoteStates[normalizedKey] = lowercased == "true"
                return
            }
        }

        if let lastComponent = topic.split(separator: "/").last {
            let key = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedValue = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(normalizedValue) {
                mqttRemoteStates[key] = intValue != 0
            } else if normalizedValue.lowercased() == "true" || normalizedValue.lowercased() == "false" {
                mqttRemoteStates[key] = normalizedValue.lowercased() == "true"
            }
        }
    }

    func activateAlarmNow() {
        Task { @MainActor in
            await tuyaClient.activateAlarm()
        }
    }

    func deactivateAlarmNow() {
        Task { @MainActor in
            await tuyaClient.deactivateAlarm()
        }
    }
}

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 5.542903, longitude: -73.453934),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
    @State private var hasCenteredOnUser = false
    @State private var editingPlace: EditingPlace?
    @State private var pendingDeletion: LocationManager.FixedPlace?
    @State private var awaitingUserRecentering = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                MapWithPins(region: $region,
                            places: locationManager.fixedPlaces,
                            onAdd: { coordinate in
                                locationManager.addPlace(at: coordinate)
                            },
                            onDragEnded: { id, coordinate in locationManager.updatePlace(id: id, coordinate: coordinate) },
                            onRemove: { id in handleDeletion(forID: id) },
                            onEdit: { id in openEditor(for: id) })
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))

                Button(action: centerOnUser) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(.blue.opacity(0.85))
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .padding(16)
            }
            .frame(height: 300)

            if let loc = locationManager.lastLocation {
                Text("Latitud: \(loc.coordinate.latitude)\nLongitud: \(loc.coordinate.longitude)")
                    .multilineTextAlignment(.center)
            } else {
                Text("Ubicación no disponible").foregroundColor(.secondary)
            }

            Button("Actualizar ubicación") { locationManager.requestAlwaysAuthorization() }
                .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                Circle()
                    .fill(locationManager.mqttConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(locationManager.mqttConnected ? "MQTT conectado" : "MQTT desconectado")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            if let lastMessage = locationManager.mqttLastMessage {
                Text("Último mensaje: \(lastMessage)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List {
                Section(header: Text("Zonas monitoreadas")) {
                    ForEach(locationManager.fixedPlaces) { place in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Nombre", text: nameBinding(for: place))
                                Button {
                                    handleDeletion(for: place)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Eliminar \(place.name)")
                            }
                            Stepper(value: radiusBinding(for: place), in: 50...200, step: 5) {
                                Text("Radio: \(Int(currentRadius(for: place))) m")
                            }
                            Text("Lat: \(coordinate(for: place).latitude), Lon: \(coordinate(for: place).longitude)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            if let remoteState = locationManager.mqttRemoteStates[place.name.lowercased()] {
                                Text(remoteState ? "MQTT detecta dentro" : "MQTT detecta fuera")
                                    .font(.footnote)
                                    .foregroundColor(remoteState ? .green : .orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            guard index < locationManager.fixedPlaces.count else { continue }
                            handleDeletion(for: locationManager.fixedPlaces[index])
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(item: $editingPlace) { item in
            PlaceEditorSheet(place: item,
                             onCancel: { editingPlace = nil },
                             onSave: { updated in
                                 locationManager.updateName(for: updated.id, name: updated.name)
                                 locationManager.updateRadius(for: updated.id, radius: updated.radius)
                                 editingPlace = nil
                             },
                             onDelete: { id in
                                 handleDeletion(forID: id)
                                 editingPlace = nil
                             })
        }
        .sheet(item: $pendingDeletion) { place in
            PasscodePrompt(placeName: place.name,
                           onCancel: { pendingDeletion = nil },
                           onValidate: { code in
                               guard code == "123" else { return false }
                               locationManager.removePlace(with: place.id)
                               pendingDeletion = nil
                               return true
                           })
        }
        .onAppear {
            locationManager.requestAlwaysAuthorization()
            locationManager.requestNotificationAuthorization()
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - ContentView helpers
private extension ContentView {
    struct EditingPlace: Identifiable {
        let id: UUID
        var name: String
        var radius: CLLocationDistance
    }

    func centerOnUser() {
        if let coordinate = locationManager.lastLocation?.coordinate {
            let newRegion = MKCoordinateRegion(center: coordinate, span: region.span)
            region = newRegion
            hasCenteredOnUser = false
            awaitingUserRecentering = false
        } else {
            awaitingUserRecentering = false
            locationManager.requestOneShotLocation()
        }
    }

    func openEditor(for id: UUID) {
        guard let place = locationManager.fixedPlaces.first(where: { $0.id == id }) else { return }
        editingPlace = EditingPlace(id: place.id, name: place.name, radius: place.radius)
    }

    func handleDeletion(for place: LocationManager.FixedPlace) {
        if requiresPasscode(placeName: place.name) {
            pendingDeletion = place
        } else {
            locationManager.removePlace(with: place.id)
        }
    }

    func handleDeletion(forID id: UUID) {
        guard let place = locationManager.fixedPlaces.first(where: { $0.id == id }) else { return }
        handleDeletion(for: place)
    }

    func requiresPasscode(placeName: String) -> Bool {
        let normalized = placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "casa" || normalized == "negocio"
    }

    func resolvedPlace(for place: LocationManager.FixedPlace) -> LocationManager.FixedPlace {
        locationManager.fixedPlaces.first(where: { $0.id == place.id }) ?? place
    }

    func nameBinding(for place: LocationManager.FixedPlace) -> Binding<String> {
        Binding(
            get: { resolvedPlace(for: place).name },
            set: { locationManager.updateName(for: place.id, name: $0) }
        )
    }

    func radiusBinding(for place: LocationManager.FixedPlace) -> Binding<CLLocationDistance> {
        Binding(
            get: { resolvedPlace(for: place).radius },
            set: { locationManager.updateRadius(for: place.id, radius: $0) }
        )
    }

    func currentRadius(for place: LocationManager.FixedPlace) -> CLLocationDistance {
        resolvedPlace(for: place).radius
    }

    func coordinate(for place: LocationManager.FixedPlace) -> CLLocationCoordinate2D {
        resolvedPlace(for: place).coordinate
    }
}

// MARK: - Place editor sheet
private struct PlaceEditorSheet: View {
    @State private var draft: ContentView.EditingPlace
    let onCancel: () -> Void
    let onSave: (ContentView.EditingPlace) -> Void
    let onDelete: (UUID) -> Void

    init(place: ContentView.EditingPlace,
         onCancel: @escaping () -> Void,
         onSave: @escaping (ContentView.EditingPlace) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _draft = State(initialValue: place)
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Nombre") {
                    TextField("Etiqueta", text: $draft.name)
                }

                Section("Radio") {
                    Stepper(value: $draft.radius, in: 50...200, step: 5) {
                        Text("Radio: \(Int(draft.radius)) m")
                    }
                    Slider(value: Binding(get: { draft.radius }, set: { draft.radius = $0 }),
                           in: 50...200,
                           step: 5)
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(draft.id)
                    } label: {
                        Label("Eliminar zona", systemImage: "trash")
                    }
                }
            }
            .navigationBarTitle("Editar zona", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Guardar") {
                        onSave(draft)
                    }
                }
            }
        }
    }
}

// MARK: - Passcode prompt
private struct PasscodePrompt: View, Identifiable {
    let id = UUID()
    let placeName: String
    let onCancel: () -> Void
    let onValidate: (String) -> Bool

    @State private var code: String = ""
    @State private var validationFailed = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Confirmar eliminación")) {
                    SecureField("Clave", text: $code)
                        .keyboardType(.numberPad)
                    if validationFailed {
                        Text("Clave incorrecta").font(.footnote).foregroundColor(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if onValidate(code) {
                            validationFailed = false
                            code = ""
                        } else {
                            validationFailed = true
                        }
                    } label: {
                        Label("Eliminar \(placeName)", systemImage: "trash")
                    }
                }
            }
            .navigationBarTitle("Clave de seguridad", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancelar") {
                        code = ""
                        validationFailed = false
                        onCancel()
                    }
                }
            }
        }
    }
}

// MARK: - Map UIKit bridge
private struct MapWithPins: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var places: [LocationManager.FixedPlace]
    var onAdd: (CLLocationCoordinate2D) -> Void
    var onDragEnded: (UUID, CLLocationCoordinate2D) -> Void
    var onRemove: (UUID) -> Void
    var onEdit: (UUID) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.setRegion(region, animated: false)
        context.coordinator.mapView = mapView

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.updateParent(self)
        context.coordinator.queueRegionIfNeeded(region)
        context.coordinator.applyQueuedRegion(to: mapView)
        context.coordinator.updateAnnotations(on: mapView, with: places)
        context.coordinator.updateOverlays(on: mapView, with: places)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        private var parent: MapWithPins
        private var draggingAnnotations: Set<UUID> = []
        private var isProgrammaticRegionChange = false
        private var pendingRegion: MKCoordinateRegion?
        private var lastBindingRegion: MKCoordinateRegion?
        private var overlayCache: [UUID: MKCircle] = [:]
        private var lastOverlayRefresh: [UUID: (coordinate: CLLocationCoordinate2D, timestamp: CFAbsoluteTime)] = [:]
        private var dragStartingCoordinate: [UUID: CLLocationCoordinate2D] = [:]
        weak var mapView: MKMapView?

        init(parent: MapWithPins) {
            self.parent = parent
        }

        func updateParent(_ parent: MapWithPins) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)

            if mapView.hitTest(point, with: nil) is MKAnnotationView {
                return
            }

            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            DispatchQueue.main.async { [parent] in
                parent.onAdd(coordinate)
            }
        }

        func updateAnnotations(on mapView: MKMapView, with places: [LocationManager.FixedPlace]) {
            let currentAnnotations = mapView.annotations.compactMap { $0 as? PlaceAnnotation }
            let targetIDs = Set(places.map(\.id))

            for annotation in currentAnnotations where !targetIDs.contains(annotation.placeID) {
                draggingAnnotations.remove(annotation.placeID)
                mapView.removeAnnotation(annotation)
            }

            for place in places {
                if let existing = currentAnnotations.first(where: { $0.placeID == place.id }) {
                    existing.title = place.name
                    existing.subtitle = "Radio: \(Int(place.radius)) m"
                    if draggingAnnotations.contains(place.id) { continue }
                    if existing.coordinate.latitude != place.coordinate.latitude ||
                        existing.coordinate.longitude != place.coordinate.longitude {
                        existing.coordinate = place.coordinate
                    }
                } else {
                    let annotation = PlaceAnnotation(place: place)
                    mapView.addAnnotation(annotation)
                }
            }
        }

        func updateOverlays(on mapView: MKMapView, with places: [LocationManager.FixedPlace]) {
            let targetIDs = Set(places.map(\.id))

            for (placeID, overlay) in overlayCache where !targetIDs.contains(placeID) {
                mapView.removeOverlay(overlay)
                overlayCache.removeValue(forKey: placeID)
                lastOverlayRefresh.removeValue(forKey: placeID)
            }

            for place in places {
                if let circle = overlayCache[place.id] {
                    let sameCoordinate = circle.coordinate.latitude == place.coordinate.latitude &&
                        circle.coordinate.longitude == place.coordinate.longitude
                    let sameRadius = circle.radius == place.radius
                    if sameCoordinate && sameRadius { continue }
                    mapView.removeOverlay(circle)
                    overlayCache.removeValue(forKey: place.id)
                } else {
                    lastOverlayRefresh.removeValue(forKey: place.id)
                }
                let circle = MKCircle(center: place.coordinate, radius: place.radius)
                circle.placeID = place.id
                overlayCache[place.id] = circle
                lastOverlayRefresh[place.id] = (place.coordinate, CFAbsoluteTimeGetCurrent())
                mapView.addOverlay(circle)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is PlaceAnnotation else { return nil }
            let identifier = "PlaceAnnotation"
            let view: MKMarkerAnnotationView

            if let dequeued = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView {
                view = dequeued
                view.annotation = annotation
            } else {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }

            view.canShowCallout = true
            view.isDraggable = true
            view.displayPriority = .required
            view.glyphImage = UIImage(systemName: "dot.circle.fill")
            view.markerTintColor = .systemBlue
            view.subtitleVisibility = .visible
            view.leftCalloutAccessoryView = makeDeleteButton()
            view.rightCalloutAccessoryView = makeEditButton()

            view.gestureRecognizers?
                .compactMap { $0 as? UILongPressGestureRecognizer }
                .forEach {
                    $0.minimumPressDuration = 0
                    $0.allowableMovement = 6
                }

            ensurePanGesture(on: view)

            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard let placeAnnotation = view.annotation as? PlaceAnnotation else { return }
            switch newState {
            case .starting:
                draggingAnnotations.insert(placeAnnotation.placeID)
                view.setSelected(false, animated: false)
                view.setDragState(.dragging, animated: true)
            case .dragging:
                updateOverlay(on: mapView,
                              for: placeAnnotation.placeID,
                              with: placeAnnotation.coordinate,
                              throttle: true)
            case .ending:
                draggingAnnotations.remove(placeAnnotation.placeID)
                let coordinate = placeAnnotation.coordinate
                updateOverlay(on: mapView,
                              for: placeAnnotation.placeID,
                              with: coordinate,
                              throttle: false)
                DispatchQueue.main.async { [parent] in
                    parent.onDragEnded(placeAnnotation.placeID, coordinate)
                }
                view.setDragState(.none, animated: true)
            case .canceling:
                draggingAnnotations.remove(placeAnnotation.placeID)
                if let original = parent.places.first(where: { $0.id == placeAnnotation.placeID }) {
                    placeAnnotation.coordinate = original.coordinate
                    updateOverlay(on: mapView,
                                  for: placeAnnotation.placeID,
                                  with: original.coordinate,
                                  throttle: false)
                }
                view.setDragState(.none, animated: true)
            default:
                break
            }
        }

        func queueRegionIfNeeded(_ region: MKCoordinateRegion) {
            if let last = lastBindingRegion, last.isApproximatelyEqual(to: region) {
                return
            }
            pendingRegion = region
        }

        func applyQueuedRegion(to mapView: MKMapView) {
            guard let target = pendingRegion else { return }
            pendingRegion = nil
            isProgrammaticRegionChange = true
            mapView.setRegion(target, animated: false)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticRegionChange = false
                self?.lastBindingRegion = target
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isProgrammaticRegionChange else { return }
            let newRegion = mapView.region
            lastBindingRegion = newRegion
            pendingRegion = nil
            parent.region = newRegion
        }

        private func updateOverlay(on mapView: MKMapView,
                                   for id: UUID,
                                   with coordinate: CLLocationCoordinate2D,
                                   throttle: Bool) {
            guard let radius = parent.places.first(where: { $0.id == id })?.radius else { return }

            if throttle {
                let now = CFAbsoluteTimeGetCurrent()
                if var last = lastOverlayRefresh[id] {
                    let deltaTime = now - last.timestamp
                    let distance = coordinate.distance(from: last.coordinate)
                    if deltaTime < 0.1 && distance < 2 {
                        return
                    }
                    last.coordinate = coordinate
                    last.timestamp = now
                    lastOverlayRefresh[id] = last
                } else {
                    lastOverlayRefresh[id] = (coordinate, now)
                }
            } else {
                lastOverlayRefresh[id] = (coordinate, CFAbsoluteTimeGetCurrent())
            }

            if let existing = overlayCache[id] {
                mapView.removeOverlay(existing)
            }

            let circle = MKCircle(center: coordinate, radius: radius)
            circle.placeID = id
            overlayCache[id] = circle
            lastOverlayRefresh[id] = (coordinate, CFAbsoluteTimeGetCurrent())
            mapView.addOverlay(circle)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.2)
            renderer.lineWidth = 2
            return renderer
        }

        private func ensurePanGesture(on view: MKAnnotationView) {
            let alreadyAttached = view.gestureRecognizers?
                .compactMap { $0 as? UIPanGestureRecognizer }
                .contains(where: { $0.name == "PinPanGesture" }) ?? false
            if alreadyAttached { return }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePinPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.minimumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.name = "PinPanGesture"
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        @objc private func handlePinPan(_ recognizer: UIPanGestureRecognizer) {
            guard let mapView = mapView,
                  let annotationView = recognizer.view as? MKAnnotationView,
                  let placeAnnotation = annotationView.annotation as? PlaceAnnotation else { return }

            let touchPoint = recognizer.location(in: mapView)
            let coordinate = mapView.convert(touchPoint, toCoordinateFrom: mapView)
            let placeID = placeAnnotation.placeID

            switch recognizer.state {
            case .began:
                draggingAnnotations.insert(placeID)
                dragStartingCoordinate[placeID] = placeAnnotation.coordinate
                mapView.isScrollEnabled = false
                annotationView.setSelected(false, animated: false)
                mapView.deselectAnnotation(placeAnnotation, animated: false)
                placeAnnotation.coordinate = coordinate
                updateOverlay(on: mapView, for: placeID, with: coordinate, throttle: false)
            case .changed:
                placeAnnotation.coordinate = coordinate
                updateOverlay(on: mapView, for: placeID, with: coordinate, throttle: true)
            case .ended, .cancelled, .failed:
                mapView.isScrollEnabled = true
                draggingAnnotations.remove(placeID)

                let finalCoordinate: CLLocationCoordinate2D
                if recognizer.state == .ended {
                    finalCoordinate = coordinate
                } else if let original = dragStartingCoordinate[placeID] {
                    finalCoordinate = original
                } else {
                    finalCoordinate = coordinate
                }

                placeAnnotation.coordinate = finalCoordinate
                updateOverlay(on: mapView, for: placeID, with: finalCoordinate, throttle: false)

                if recognizer.state == .ended {
                    DispatchQueue.main.async { [parent] in
                        parent.onDragEnded(placeID, finalCoordinate)
                    }
                }

                dragStartingCoordinate.removeValue(forKey: placeID)
            default:
                break
            }
        }

        private func makeDeleteButton() -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "trash"), for: .normal)
            button.tintColor = .systemRed
            return button
        }

        private func makeEditButton() -> UIButton {
            let button = UIButton(type: .detailDisclosure)
            return button
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // Allow callout to display; nothing else required.
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            guard let placeAnnotation = view.annotation as? PlaceAnnotation else { return }
            if control == view.leftCalloutAccessoryView {
                DispatchQueue.main.async { [parent] in
                    parent.onRemove(placeAnnotation.placeID)
                }
            } else if control == view.rightCalloutAccessoryView {
                DispatchQueue.main.async { [parent] in
                    parent.onEdit(placeAnnotation.placeID)
                }
            }
            mapView.deselectAnnotation(view.annotation, animated: true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer.name == "PinPanGesture" {
                return true
            }
            var view: UIView? = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer.name == "PinPanGesture" || otherGestureRecognizer.name == "PinPanGesture" {
                return false
            }
            return true
        }
    }
}

private final class PlaceAnnotation: MKPointAnnotation {
    let placeID: UUID

    init(place: LocationManager.FixedPlace) {
        self.placeID = place.id
        super.init()
        title = place.name
        coordinate = place.coordinate
        subtitle = "Radio: \(Int(place.radius)) m"
    }
}

private extension MKCircle {
    private struct AssociatedKeys {
        static var placeIDHandle: UInt8 = 0
    }

    var placeID: UUID? {
        get {
            objc_getAssociatedObject(self, &AssociatedKeys.placeIDHandle) as? UUID
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.placeIDHandle, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private extension MKCoordinateRegion {
    func isApproximatelyEqual(to other: MKCoordinateRegion, epsilon: Double = 0.0001) -> Bool {
        abs(center.latitude - other.center.latitude) < epsilon &&
        abs(center.longitude - other.center.longitude) < epsilon &&
        abs(span.latitudeDelta - other.span.latitudeDelta) < epsilon &&
        abs(span.longitudeDelta - other.span.longitudeDelta) < epsilon
    }
}

private extension CLLocationCoordinate2D {
    func distance(from other: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: latitude, longitude: longitude)
        let loc2 = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return loc1.distance(from: loc2)
    }
}

