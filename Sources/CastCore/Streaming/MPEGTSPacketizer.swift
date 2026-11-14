import Foundation

public final class MPEGTSPacketizer: @unchecked Sendable {
    public static let syncByte: UInt8 = 0x47
    public static let patPID: UInt16 = 0x0000
    public static let pmtPID: UInt16 = 0x1000
    public static let videoPID: UInt16 = 0x0100
    public static let audioPID: UInt16 = 0x0101

    private var videoContinuityCounter: UInt8 = 0
    private var audioContinuityCounter: UInt8 = 0
    private var patContinuityCounter: UInt8 = 0
    private var pmtContinuityCounter: UInt8 = 0
    private let lock = NSLock()

    public init() {}

    public func generatePAT() -> Data {
        lock.lock()
        defer { lock.unlock() }

        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = Self.syncByte
        // Transport error (0), payload unit start indicator (1), priority (0), PID (0x0000)
        packet[1] = 0x40
        packet[2] = 0x00
        // Adaptation (01 - payload only), continuity counter
        packet[3] = 0x10 | (patContinuityCounter & 0x0F)
        patContinuityCounter = (patContinuityCounter + 1) & 0x0F

        // Pointer field
        packet[4] = 0x00

        // Table ID = 0x00 (PAT)
        var patTable = Data([
            0x00,               // Table ID
            0xB0, 0x0D,         // Section syntax indicator, section length = 13 (0x00D)
            0x00, 0x01,         // Transport stream ID = 1
            0xC1,               // Version 0, current_next = 1
            0x00,               // Section number = 0
            0x00,               // Last section number = 0
            // Program 1 -> PMT PID 0x1000
            0x00, 0x01,         // Program number = 1
            0xF0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)
        ])

        // Compute and append CRC32
        let crc = computeCRC32(data: patTable)
        var crcBE = crc.bigEndian
        patTable.append(Data(bytes: &crcBE, count: 4))

        packet.replaceSubrange(5..<(5 + patTable.count), with: patTable)
        return packet
    }

    public func generatePMT() -> Data {
        lock.lock()
        defer { lock.unlock() }

        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = Self.syncByte
        packet[1] = 0x40 | UInt8((Self.pmtPID >> 8) & 0x1F)
        packet[2] = UInt8(Self.pmtPID & 0xFF)
        packet[3] = 0x10 | (pmtContinuityCounter & 0x0F)
        pmtContinuityCounter = (pmtContinuityCounter + 1) & 0x0F

        // Pointer field
        packet[4] = 0x00

        // PMT table definition
        var pmtTable = Data([
            0x02,               // Table ID = 0x02 (PMT)
            0xB0, 0x17,         // Section syntax, length = 23 (0x017)
            0x00, 0x01,         // Program number = 1
            0xC1,               // Version 0, current = 1
            0x00,               // Section 0
            0x00,               // Last section 0
            0xE0 | UInt8((Self.videoPID >> 8) & 0x1F), UInt8(Self.videoPID & 0xFF), // PCR PID = Video PID
            0xF0, 0x00,         // Program info length = 0
            // Video stream: Type 0x1B (H.264), PID 0x0100
            0x1B,
            0xE0 | UInt8((Self.videoPID >> 8) & 0x1F), UInt8(Self.videoPID & 0xFF),
            0xF0, 0x00,         // ES info length = 0
            // Audio stream: Type 0x0F (AAC ADTS), PID 0x0101
            0x0F,
            0xE0 | UInt8((Self.audioPID >> 8) & 0x1F), UInt8(Self.audioPID & 0xFF),
            0xF0, 0x00          // ES info length = 0
        ])

        let crc = computeCRC32(data: pmtTable)
        var crcBE = crc.bigEndian
        pmtTable.append(Data(bytes: &crcBE, count: 4))

        packet.replaceSubrange(5..<(5 + pmtTable.count), with: pmtTable)
        return packet
    }

    public func packetizeVideo(nalu: Data, pts: UInt64, isKeyframe: Bool) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        // Construct PES Packet:
        // Start code: 0x000001, Stream ID: 0xE0 (Video)
        var pesHeader = Data([0x00, 0x00, 0x01, 0xE0])
        // PES Packet Length: 0 for video (unbounded)
        pesHeader.append(contentsOf: [0x00, 0x00])
        // PTS flag only = 0x80, header data length = 5
        pesHeader.append(contentsOf: [0x80, 0x80, 0x05])

        // Encode 33-bit PTS into 5 bytes
        let ptsVal = pts & 0x1FFFFFFFF
        let b0: UInt8 = 0x21 | UInt8((ptsVal >> 29) & 0x0E)
        let b1: UInt8 = UInt8((ptsVal >> 22) & 0xFF)
        let b2: UInt8 = 0x01 | UInt8((ptsVal >> 14) & 0xFE)
        let b3: UInt8 = UInt8((ptsVal >> 7) & 0xFF)
        let b4: UInt8 = 0x01 | UInt8((ptsVal << 1) & 0xFE)
        pesHeader.append(contentsOf: [b0, b1, b2, b3, b4])

        // Full PES data = PES header + NALU
        var pesData = pesHeader
        pesData.append(nalu)

        var packets: [Data] = []
        var offset = 0
        var isFirst = true

        while offset < pesData.count {
            var packet = Data(repeating: 0xFF, count: 188)
            packet[0] = Self.syncByte

            let payloadStartIndicator: UInt8 = isFirst ? 0x40 : 0x00
            packet[1] = payloadStartIndicator | UInt8((Self.videoPID >> 8) & 0x1F)
            packet[2] = UInt8(Self.videoPID & 0xFF)

            let remaining = pesData.count - offset

            if remaining >= 184 {
                // Payload only
                packet[3] = 0x10 | (videoContinuityCounter & 0x0F)
                videoContinuityCounter = (videoContinuityCounter + 1) & 0x0F
                packet.replaceSubrange(4..<188, with: pesData.subdata(in: offset..<(offset + 184)))
                offset += 184
            } else {
                // Needs adaptation field stuffing
                let adaptationLength = 184 - remaining
                packet[3] = 0x30 | (videoContinuityCounter & 0x0F)
                videoContinuityCounter = (videoContinuityCounter + 1) & 0x0F

                packet[4] = UInt8(adaptationLength - 1)
                if adaptationLength > 1 {
                    packet[5] = 0x00 // Flags
                    if adaptationLength > 2 {
                        // Fill stuffing with 0xFF
                        let stuffing = Data(repeating: 0xFF, count: adaptationLength - 2)
                        packet.replaceSubrange(6..<(4 + adaptationLength), with: stuffing)
                    }
                }

                let payloadStart = 4 + adaptationLength
                packet.replaceSubrange(payloadStart..<188, with: pesData.subdata(in: offset..<pesData.count))
                offset = pesData.count
            }

            packets.append(packet)
            isFirst = false
        }

        return packets
    }

    private func computeCRC32(data: Data) -> UInt32 {
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
