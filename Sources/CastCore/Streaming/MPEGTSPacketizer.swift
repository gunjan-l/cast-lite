import Foundation

/// Video-only MPEG transport stream muxer for H.264 access units.
/// Continuity counters live here, so they carry across HLS segments.
public final class MPEGTSPacketizer: @unchecked Sendable {
    public static let syncByte: UInt8 = 0x47
    public static let patPID: UInt16 = 0x0000
    public static let pmtPID: UInt16 = 0x1000
    public static let videoPID: UInt16 = 0x0100

    /// Access unit delimiter NAL (type 9, primary_pic_type 7 = any slice type).
    static let accessUnitDelimiter = Data([0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
    /// PCR leads the PTS by this much so the decoder clock is ahead of presentation.
    static let pcrLead: Int64 = 9_000

    private var videoContinuityCounter: UInt8 = 0
    private var patContinuityCounter: UInt8 = 0
    private var pmtContinuityCounter: UInt8 = 0
    private let lock = NSLock()

    public init() {}

    public func generatePAT() -> Data {
        lock.lock()
        defer { lock.unlock() }

        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = Self.syncByte
        packet[1] = 0x40
        packet[2] = 0x00
        packet[3] = 0x10 | (patContinuityCounter & 0x0F)
        patContinuityCounter = (patContinuityCounter + 1) & 0x0F
        packet[4] = 0x00 // pointer field

        var patTable = Data([
            0x00,               // table id
            0xB0, 0x0D,         // section length = 13
            0x00, 0x01,         // transport stream id
            0xC1,               // version 0, current
            0x00, 0x00,         // section numbers
            0x00, 0x01,         // program 1
            0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)
        ])
        var crcBE = Self.crc32(patTable).bigEndian
        patTable.append(Data(bytes: &crcBE, count: 4))

        packet.replaceSubrange(5..<(5 + patTable.count), with: patTable)
        return packet
    }

    /// Video-only PMT: one H.264 elementary stream, PCR carried on the video PID.
    public func generatePMT() -> Data {
        lock.lock()
        defer { lock.unlock() }

        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = Self.syncByte
        packet[1] = 0x40 | UInt8((Self.pmtPID >> 8) & 0x1F)
        packet[2] = UInt8(Self.pmtPID & 0xFF)
        packet[3] = 0x10 | (pmtContinuityCounter & 0x0F)
        pmtContinuityCounter = (pmtContinuityCounter + 1) & 0x0F
        packet[4] = 0x00 // pointer field

        var pmtTable = Data([
            0x02,               // table id
            0xB0, 0x12,         // section length = 18
            0x00, 0x01,         // program number
            0xC1,               // version 0, current
            0x00, 0x00,         // section numbers
            0xE0 | UInt8((Self.videoPID >> 8) & 0x1F), UInt8(Self.videoPID & 0xFF), // PCR PID
            0xF0, 0x00,         // program info length
            0x1B,               // H.264
            0xE0 | UInt8((Self.videoPID >> 8) & 0x1F), UInt8(Self.videoPID & 0xFF),
            0xF0, 0x00          // ES info length
        ])
        var crcBE = Self.crc32(pmtTable).bigEndian
        pmtTable.append(Data(bytes: &crcBE, count: 4))

        packet.replaceSubrange(5..<(5 + pmtTable.count), with: pmtTable)
        return packet
    }

    /// Packetizes one access unit into 188-byte TS packets: an AUD is ensured at the
    /// front, and keyframes carry a PCR and the random access indicator.
    public func packetizeVideo(_ accessUnit: AccessUnit) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        var es = Data()
        if !Self.startsWithAUD(accessUnit.annexB) {
            es.append(Self.accessUnitDelimiter)
        }
        es.append(accessUnit.annexB)

        // PES header: start code, stream id, unbounded length, PTS only.
        var pes = Data([0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05])
        pes.append(Self.encodePTS(accessUnit.pts.ticks))
        pes.append(es)

        let pcr: Int64? = accessUnit.isKeyframe ? max(0, accessUnit.pts.ticks - Self.pcrLead) : nil

        var packets: [Data] = []
        var offset = 0
        while offset < pes.count {
            let isFirst = offset == 0
            let withPCR = isFirst && pcr != nil
            let minAdaptation = withPCR ? 8 : 0
            let remaining = pes.count - offset
            let capacity = 184 - minAdaptation

            let payloadLength: Int
            let adaptationTotal: Int
            if remaining >= capacity {
                payloadLength = capacity
                adaptationTotal = minAdaptation
            } else {
                payloadLength = remaining
                adaptationTotal = 184 - remaining
            }

            var packet = Data(repeating: 0xFF, count: 188)
            packet[0] = Self.syncByte
            packet[1] = (isFirst ? 0x40 : 0x00) | UInt8((Self.videoPID >> 8) & 0x1F)
            packet[2] = UInt8(Self.videoPID & 0xFF)
            let control: UInt8 = adaptationTotal > 0 ? 0x30 : 0x10
            packet[3] = control | (videoContinuityCounter & 0x0F)
            videoContinuityCounter = (videoContinuityCounter + 1) & 0x0F

            if adaptationTotal > 0 {
                packet[4] = UInt8(adaptationTotal - 1)
                if adaptationTotal >= 2 {
                    var flags: UInt8 = 0
                    if isFirst && accessUnit.isKeyframe { flags |= 0x40 } // random access
                    if withPCR { flags |= 0x10 }
                    packet[5] = flags
                    if withPCR, let pcr {
                        packet.replaceSubrange(6..<12, with: Self.encodePCR(pcr))
                    }
                }
            }

            let payloadStart = 4 + adaptationTotal
            packet.replaceSubrange(payloadStart..<188, with: pes.subdata(in: offset..<(offset + payloadLength)))
            offset += payloadLength
            packets.append(packet)
        }
        return packets
    }

    private static func startsWithAUD(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(5))
        if bytes.count >= 5, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 {
            return bytes[4] & 0x1F == 9
        }
        if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 {
            return bytes[3] & 0x1F == 9
        }
        return false
    }

    private static func encodePTS(_ ticks: Int64) -> Data {
        let v = UInt64(bitPattern: ticks) & 0x1_FFFF_FFFF
        return Data([
            0x21 | UInt8((v >> 29) & 0x0E),
            UInt8((v >> 22) & 0xFF),
            0x01 | UInt8((v >> 14) & 0xFE),
            UInt8((v >> 7) & 0xFF),
            0x01 | UInt8((v << 1) & 0xFE)
        ])
    }

    private static func encodePCR(_ ticks: Int64) -> Data {
        let base = UInt64(bitPattern: ticks) & 0x1_FFFF_FFFF
        return Data([
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8(((base & 1) << 7) | 0x7E),
            0x00
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            for bit in 0..<8 {
                let bitVal = ((byte >> (7 - bit)) & 1) == 1
                let c15 = ((crc >> 31) & 1) == 1
                crc = crc << 1
                if c15 != bitVal {
                    crc ^= 0x04C11DB7
                }
            }
        }
        return crc
    }
}
