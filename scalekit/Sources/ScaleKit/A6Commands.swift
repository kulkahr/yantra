import Foundation

/// Command builders — ports of `ProtocolCommand.get*ForA6*`, `A6ProtocolParser.getAckPacket`,
/// `FatScalePairWorker.getDeviceId`.
public enum A6Commands {

    // MARK: Pairing (SRD-002)

    /// `0x0001` register: [cmd(2B)][deviceId 6B][registerState 1B]
    public static func register(deviceIdHex12: String, state: RegisterState, mac: String) -> [UInt8] {
        var p = A6Bytes.from(short: A6Command.deviceRegisterDeviceID.rawValue)
        p += A6Hex.decode(deviceIdHex12)
        p.append(state.rawValue)
        return p
    }

    /// `0x0008` auth response. NOTE (decompiled quirk): all trailing fields are
    /// appended as **ASCII hex strings**, not raw bytes:
    /// `cmd(2B) + "01"|"02" + verificationCode(12 ASCII chars) + mode 2 digits + "02"`.
    public static func authResponse(success: Bool, verificationCodeHex6: String, mode: Int) -> [UInt8] {
        var hex = A6Bytes.from(short: A6Command.auth.rawValue).map { String(format: "%02X", $0) }.joined()
        hex += success ? "01" : "02"
        hex += verificationCodeHex6.uppercased()
        hex += String(format: "%02d", mode)
        hex += "02"                                     // DEFAULT_PHONE_PLATFORM
        return A6Hex.decode(hex)
    }

    /// `0x0003` bind notice: [cmd][userNumber 1B][confirmState 1B]
    public static func bindNotice(userNumber: Int, confirm: PairedConfirmState) -> [UInt8] {
        var hex = A6Bytes.from(short: A6Command.bindNotice.rawValue).map { String(format: "%02X", $0) }.joined()
        hex += String(format: "%02X", userNumber)
        hex += String(format: "%02X", confirm.rawValue)
        return A6Hex.decode(hex)
    }

    /// `0x0005` unbind notice: [cmd][userState 1B] (BindUserState.GUEST = 0)
    public static func unbindNotice(userState: Int = 0x00) -> [UInt8] {
        A6Bytes.from(short: A6Command.unbindNotice.rawValue) + [UInt8(userState)]
    }

    /// Device ID derivation (`FatScalePairWorker.getDeviceId`):
    /// `deviceId = verificationCode ⊕ MAC`, 12 uppercase hex chars.
    public static func deviceId(verificationCodeHex6: String, mac: String) -> String {
        let v = UInt64(verificationCodeHex6.uppercased(), radix: 16) ?? 0
        let m = UInt64(A6Obfuscation.macHex(mac), radix: 16) ?? 0
        // NOTE: String(format: "%012X", UInt64) truncates to 32-bit on Apple platforms — pad manually.
        let hex = String(v ^ m, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 12 - hex.count)) + hex
    }

    // MARK: ACK frames

    /// `[00 01 status]`, status XORed with MAC[0] when obfuscation is active
    /// (`A6ProtocolParser.getAckPacket`). Written to characteristic `A622`.
    public static func ack(ok: Bool, mac: String, xored: Bool) -> [UInt8] {
        var status: UInt8 = ok ? 1 : 2
        if xored {
            status ^= A6Obfuscation.macBytes(mac)[0]
        }
        return [0x00, 0x01, status]
    }

    // MARK: Session setup (SRD-003/005)

    /// `0x000A` init response: capability bitmap + optional UTC/tz/timestamp.
    /// Flags: 0x01 mtu, 0x02 slaveLatency, 0x04 supervisoryTimeout,
    ///        0x08 utc, 0x10 timeZone, 0x20 timestamp.
    /// `0x000A` init response — **hardware-verified form (HCI capture 2026-09-21):**
    /// the scale's `0x0009` flags `0x18` request UTC + timezone only, and the
    /// official app answers with exactly 8 bytes: `[cmd][0x18][utc 4B][tz 1B]`.
    /// (No MTU byte, no date-of-time stamp — those flags were never set.)
    public static func responseInit(utc: UInt32, timeZoneHex: UInt8) -> [UInt8] {
        var p = A6Bytes.from(short: A6Command.responseInit.rawValue)
        p.append(0x18)                       // mirrors the device's request flags
        p += A6Bytes.from(int: utc)
        p.append(timeZoneHex)
        return p
    }

    /// `0x1002` push time: flags(1) + utc(4)? + tz(1)? + timestamp(7)?
    public static func pushTime(utc: UInt32, timeZoneHex: UInt8, date: (Int, Int, Int, Int, Int, Int)) -> [UInt8] {
        var p = A6Bytes.from(short: A6Command.pushTime.rawValue)
        let flags: UInt8 = 0x01 | 0x02 | 0x04
        p.append(flags)
        p += A6Bytes.from(int: utc)
        p.append(timeZoneHex)
        p += A6Bytes.from(short: UInt16(date.0))
        p.append(UInt8(date.1)); p.append(UInt8(date.2))
        p.append(UInt8(date.3)); p.append(UInt8(date.4)); p.append(UInt8(date.5))
        return p
    }

    /// `0x1001` push user info (11-byte fixed frame):
    /// [cmd][slot][sex 0m/1f][age][height×100 2B][athlete][activity][weight×100 2B]
    /// weight `0xFFFF` = unset.
    public static func pushUserInfo(slot: Int, sexMale: Bool, age: Int,
                                    heightMeters: Double, athlete: Bool,
                                    activityLevel: Int, weightKg: Double?) -> [UInt8] {
        var p = A6Bytes.from(short: A6Command.pushUserInfo.rawValue)
        p.append(UInt8(slot))
        p.append(sexMale ? 0 : 1)
        p.append(UInt8(age))
        p += A6Bytes.from(short: UInt16((heightMeters * 100.0).rounded()))
        p.append(athlete ? 1 : 0)
        p.append(UInt8(activityLevel))
        if let w = weightKg, w > 0 {
            p += A6Bytes.from(short: UInt16((w * 100.0).rounded()))
        } else {
            p += [0xFF, 0xFF]
        }
        return p
    }

    /// `0x1004` push unit: 0 kg, 1 lb, 2 st, 3 jin.
    public static func pushUnit(_ unit: UnitType) -> [UInt8] {
        A6Bytes.from(short: A6Command.pushUnit.rawValue) + [unit.rawValue]
    }

    /// `0x4801` measure setting: [cmd][slot][on 0/1]
    /// `0x4801` measure setting — **hardware-verified (HCI capture): the slot
    /// byte is 0-based** (`48 01 00 01` targets the first registered user).
    public static func measureSetting(slot: Int, on: Bool) -> [UInt8] {
        A6Bytes.from(short: A6Command.measureSetting.rawValue) + [UInt8(slot - 1), on ? 1 : 0]
    }

    /// `0x1003` push target: [cmd][slot][enable 1][target×100 4B]
    public static func pushTarget(slot: Int, targetKg: Double) -> [UInt8] {
        var p = A6Bytes.from(short: A6Command.pushTarget.rawValue)
        p.append(UInt8(slot))
        p.append(1)
        p += A6Bytes.from(int: UInt32((targetKg * 100.0).rounded()))
        return p
    }

    /// `0x1005` clear stored data — decompiled PacketProfile: 0x1005 =
    /// PUSH_CLEAR_DATA (4101). NOTE: the byte after the command is a flag,
    /// not the slot (hardware sends `10 05 00` variants as callbacks too).
    public static func clearData(slot: Int, utc: UInt32) -> [UInt8] {
        A6Bytes.from(short: A6Command.pushClearData.rawValue) + [UInt8(slot)] + A6Bytes.from(int: utc)
    }

    /// `0x1007` heart-rate switch — hardware sends `[10 07 01]` (on).
    public static func pushHeartRateSwitch(on: Bool = true) -> [UInt8] {
        A6Bytes.from(short: A6Command.pushHeartRateSwitch.rawValue) + [on ? 1 : 0]
    }
}

public enum RegisterState: UInt8 {
    case unknown = 0
    case normalUnregister = 1
    case registered = 2
    case illegal = 3
    case other = 255
}

public enum PairedConfirmState: UInt8 {
    case pairingSuccess = 1
    case pairingFail = 2
    case unregistered = 3
    case illegal = 4
    case other = 255
}

public enum UnitType: UInt8 {
    case kg = 0
    case lb = 1
    case st = 2
    case jin = 3
    case gongJin = 4
}
