import Foundation

/// Which Internet Econet room a network is in, as its file keeps it:
/// nothing secret (the credentials are in the Keychain, by service and
/// room), so a network can be passed on without giving its room away.
public struct InternetRoomLink: Codable, Sendable, Equatable {
    public var service: URL
    public var roomId: String
    public var roomName: String
    /// This network made the room (its host).
    public var hosting: Bool
    /// The machines it shares, by node. Others keep their station numbers
    /// in the room (so nobody else takes them) but take no traffic.
    public var shared: [UUID]
    /// This person shows their shared machines' screens to the room (when
    /// its host allows screen sharing).
    public var showsScreens: Bool?

    public init(service: URL, roomId: String, roomName: String, hosting: Bool, shared: [UUID]) {
        self.service = service
        self.roomId = roomId
        self.roomName = roomName
        self.hosting = hosting
        self.shared = shared
    }
}

/// A running network in its room: the gateway on its line and the
/// connection to the room, joined up.
public final class InternetEconetLink: @unchecked Sendable {
    public let gateway = EconetGateway()
    public let connection: RoomConnection
    /// Each change to the room (on the connection's queue).
    public var onChange: (@Sendable (RoomConnection.Snapshot) -> Void)?
    /// Takes the gateway off the line it was put on.
    private var detach: ((EconetLineDevice) -> Void)?

    public init(api: RoomAPI, roomId: String, credentials: RoomCredentials, claims: [StationClaim], shared: Set<UInt8>) {
        connection = RoomConnection(api: api, roomId: roomId, credentials: credentials, claims: claims)
        gateway.sharedStations = shared
        let gateway = gateway
        let connection = connection
        gateway.send = { connection.send($0) }
        connection.onTraffic = { gateway.receive($0) }
        connection.onChange = { [weak self] snapshot in
            // The stations the gateway answers for: everyone else's, online.
            gateway.remoteStations = Set(snapshot.stations
                .filter { $0.participantId != snapshot.participantId && $0.online }
                .map { UInt8($0.station) })
            self?.onChange?(snapshot)
        }
    }

    /// Puts the gateway on a line (`attach`), and connects to the room.
    public func start(attach: (EconetLineDevice) -> Void, detach: @escaping (EconetLineDevice) -> Void) {
        attach(gateway)
        self.detach = detach
        connection.start()
    }

    public func stop() {
        connection.stop()
        gateway.remoteStations = []
        detach?(gateway)
        detach = nil
    }

    /// The network's machines changed (added, removed, renumbered, shared).
    public func update(claims: [StationClaim], shared: Set<UInt8>) {
        gateway.sharedStations = shared
        connection.setClaims(claims)
    }
}
