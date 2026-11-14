import Foundation

public enum UPnPClient {
    public static func generateSetAVTransportURIPayload(mediaURL: String) -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    <CurrentURI>\(mediaURL)</CurrentURI>
                    <CurrentURIMetaData></CurrentURIMetaData>
                </u:SetAVTransportURI>
            </s:Body>
        </s:Envelope>
        """
    }

    public static func generatePlayPayload() -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    <Speed>1</Speed>
                </u:Play>
            </s:Body>
        </s:Envelope>
        """
    }

    public static func generatePausePayload() -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                </u:Pause>
            </s:Body>
        </s:Envelope>
        """
    }

    public static func generateStopPayload() -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                </u:Stop>
            </s:Body>
        </s:Envelope>
        """
    }

    public static func generateSeekPayload(targetTime: String) -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    <Unit>REL_TIME</Unit>
                    <Target>\(targetTime)</Target>
                </u:Seek>
            </s:Body>
        </s:Envelope>
        """
    }
}

public enum RokuECPClient {
    public static func buildLaunchURL(deviceIP: String, mediaURL: String, format: String = "mp4") -> URL {
        let encodedURL = mediaURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? mediaURL
        return URL(string: "http://\(deviceIP):8060/launch/15985?streamformat=\(format)&url=\(encodedURL)")!
    }

    public static func buildKeypressURL(deviceIP: String, key: String) -> URL {
        return URL(string: "http://\(deviceIP):8060/keypress/\(key)")!
    }
}
