import Foundation

/// Dictator's SDK appends operation paths to this gateway base.
public enum DictatorGatewayEndpoint {
    public static func baseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/v1/audio/transcriptions", "/v1/stream", "/v1/translate", "/v1"] {
            if path.hasSuffix(suffix) {
                path.removeLast(suffix.count)
                break
            }
        }
        components.percentEncodedPath = path
        return components.url ?? url
    }
}
