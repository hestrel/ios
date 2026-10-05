import Foundation
import OpenAI

/// SDK 0.5.1 requires a web-search action even on an unfinished output_item.added.
/// Buffer complete SSE frames (network chunks need not align with UTF-8 or event boundaries).
nonisolated final class ChatGPTSearchStreamMiddleware: OpenAIMiddleware, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func interceptStreamingData(request: URLRequest?, _ data: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var output = Data()
        while let range = boundary(in: pending) {
            let frame = pending.subdata(in: pending.startIndex..<range.lowerBound)
            pending.removeSubrange(pending.startIndex..<range.upperBound)
            output.append(Self.normalize(frame))
            output.append(Data("\n\n".utf8))
        }
        return output
    }

    private func boundary(in data: Data) -> Range<Data.Index>? {
        let unix = data.range(of: Data("\n\n".utf8))
        let windows = data.range(of: Data("\r\n\r\n".utf8))
        return [unix, windows].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func normalize(_ frame: Data) -> Data {
        guard let text = String(data: frame, encoding: .utf8) else { return frame }
        let lines = text.components(separatedBy: .newlines)
        let payload = lines.filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        guard var event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              event["type"] as? String == "response.output_item.added",
              var item = event["item"] as? [String: Any], item["type"] as? String == "web_search_call",
              item["action"] == nil || item["action"] is NSNull else { return frame }
        // A decoding placeholder only; never displayed or executed. The done event supplies the real action.
        item["action"] = ["type": "search"]
        event["item"] = item
        guard let encoded = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: encoded, encoding: .utf8) else { return frame }
        let metadata = lines.filter { !$0.hasPrefix("data:") && !$0.isEmpty }
        return Data((metadata + ["data: \(json)"]).joined(separator: "\n").utf8)
    }
}
