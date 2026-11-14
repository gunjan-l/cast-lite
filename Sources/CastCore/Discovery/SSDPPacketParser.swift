import Foundation

public enum SSDPPacketParser {
    public static func parse(packet: String, senderIP: String) -> DiscoveredDevice? {
        let lines = packet.components(separatedBy: "\r\n")
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

        guard let usn = headers["USN"] ?? headers["NT"] ?? headers["ST"] else {
            return nil
        }

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

            return DiscoveredDevice(
                id: usn,
                name: "\(brand) TV",
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
            name: name,
            type: .chromecast,
            ipAddress: ipAddress,
            port: port,
            locationURL: nil,
            lastSeen: Date()
        )
    }
}
