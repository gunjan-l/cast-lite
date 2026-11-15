import Foundation

public enum SSDPPacketParser {
    public static func parse(packet: String, senderIP: String) -> DiscoveredDevice? {
        let normalized = packet.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let firstLine = lines.first?.uppercased(),
              firstLine.contains("200 OK") || firstLine.contains("NOTIFY") else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let nts = headers["NTS"], nts.lowercased().contains("byebye") {
            return nil
        }

        guard let rawUsn = headers["USN"] ?? headers["NT"] ?? headers["ST"] else {
            return nil
        }
        let usn = rawUsn.components(separatedBy: "::").first ?? rawUsn

        let st = headers["ST"] ?? ""
        let nt = headers["NT"] ?? ""
        let server = headers["SERVER"] ?? ""
        let locationString = headers["LOCATION"]
        let locationURL = locationString.flatMap { URL(string: $0) }

        let port: UInt16
        if let locationURL = locationURL, let urlPort = locationURL.port {
            port = UInt16(urlPort)
        } else if st.contains("roku:ecp") || nt.contains("roku:ecp") {
            port = 8060
        } else {
            port = 8080
        }

        if st.contains("roku:ecp") || nt.contains("roku:ecp") || server.uppercased().contains("ROKU") {
            return DiscoveredDevice(
                id: usn,
                name: "Roku TV",
                type: .roku,
                ipAddress: senderIP,
                port: port,
                locationURL: locationURL,
                lastSeen: Date()
            )
        }

        if st.contains("MediaRenderer") || nt.contains("MediaRenderer") ||
           st.contains("AVTransport") || nt.contains("AVTransport") ||
           server.uppercased().contains("UPNP") || server.uppercased().contains("SAMSUNG") || server.uppercased().contains("LG") {

            let brand: String
            if server.uppercased().contains("SAMSUNG") {
                brand = "Samsung"
            } else if server.uppercased().contains("LG") {
                brand = "LG"
            } else if server.uppercased().contains("SONY") {
                brand = "Sony"
            } else {
                brand = "Smart TV"
            }

            let deviceName = (brand == "Smart TV") ? "Smart TV" : "\(brand) TV"

            return DiscoveredDevice(
                id: usn,
                name: deviceName,
                type: .dlna(brand: brand),
                ipAddress: senderIP,
                port: port,
                locationURL: locationURL,
                lastSeen: Date()
            )
        }

        return nil
    }
}

public enum MDNSParser {
    public static func parseChromecast(name: String, ipAddress: String, port: UInt16 = 8009) -> DiscoveredDevice {
        return DiscoveredDevice(
            id: "chromecast-\(ipAddress):\(port)",
            name: name.isEmpty ? "Chromecast" : name,
            type: .chromecast,
            ipAddress: ipAddress,
            port: port,
            locationURL: nil,
            lastSeen: Date()
        )
    }

    public static func parseTXTRecord(data: Data) -> [String: String] {
        var result: [String: String] = [:]
        #if canImport(Darwin)
        let dict = NetService.dictionary(fromTXTRecord: data)
        for (k, v) in dict {
            if let str = String(data: v, encoding: .utf8) {
                result[k] = str
            }
        }
        if !result.isEmpty {
            return result
        }
        #endif

        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let len = Int(bytes[offset])
            offset += 1
            guard len > 0 else { continue }
            guard offset + len <= bytes.count else { break }
            let itemData = Data(bytes[offset..<(offset + len)])
            if let itemStr = String(data: itemData, encoding: .utf8), !itemStr.isEmpty {
                if let eqIdx = itemStr.firstIndex(of: "=") {
                    let key = String(itemStr[..<eqIdx])
                    let val = String(itemStr[itemStr.index(after: eqIdx)...])
                    if !key.isEmpty {
                        result[key] = val
                    }
                } else {
                    result[itemStr] = ""
                }
            }
            offset += len
        }
        return result
    }
}
