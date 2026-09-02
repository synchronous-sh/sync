import Foundation

enum CaptureDeepLink {
    static func make(saveID: UUID? = nil, urlString: String?, text: String?) -> URL? {
        var comps = URLComponents()
        comps.scheme = "synchronous"
        comps.host = "save"
        var items: [URLQueryItem] = []
        if let saveID {
            items.append(URLQueryItem(name: "id", value: saveID.uuidString))
        }
        if let urlString, !urlString.isEmpty {
            items.append(URLQueryItem(name: "url", value: urlString))
        }
        if let text, !text.isEmpty {
            items.append(URLQueryItem(name: "text", value: String(text.prefix(2000))))
        }
        guard !items.isEmpty else { return nil }
        comps.queryItems = items
        return comps.url
    }

    static func parse(_ url: URL) -> (id: UUID?, url: String?, text: String?)? {
        guard url.scheme == "synchronous", url.host == "save" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
        let link = items.first(where: { $0.name == "url" })?.value
        let text = items.first(where: { $0.name == "text" })?.value
        return (id, link, text)
    }
}
