import Foundation

/// Extended GATT UUIDs — used by every host (a6host CLI + Yantra iOS app).
/// `a6Broadcast`/`otaData` are wire-verified requirements (REPLICATION.md fact #2):
/// the scale only challenges peers that subscribe all four notifiable channels.
public enum GATTPlus {
    public static let a6Broadcast = UUID(uuidString: "0000A620-0000-1000-8000-00805F9B34FB")!      // A620 READ|INDICATE — 100a broadcast-ID on connect (challenge gate)
    public static let otaData     = UUID(uuidString: "00001531-1212-EFDE-1523-785FEABCD123")!      // 1531 WRITE|NOTIFY — OTA/data channel
    public static let firmwareRevision = UUID(uuidString: "00002A26-0000-1000-8000-00805F9B34FB")! // 180a FW (XOR-variant gate)
    public static let hardwareRevision = UUID(uuidString: "00002A27-0000-1000-8000-00805F9B34FB")!
    public static let modelNumber      = UUID(uuidString: "00002A24-0000-1000-8000-00805F9B34FB")!
    public static let serialNumber     = UUID(uuidString: "00002A25-0000-1000-8000-00805F9B34FB")!
    public static let manufacturerName = UUID(uuidString: "00002A29-0000-1000-8000-00805F9B34FB")!
}
