import Foundation
import OpenAI
import XCTest
@testable import StreamAdapter

final class ChatGPTStreamOutputTests: XCTestCase {
    func testCompletedTextIsNotTreatedAsAToolCall() throws {
        let item = try JSONDecoder().decode(OutputItem.self, from: Data(#"{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Test received. How can I help?","annotations":[],"logprobs":[]}]}"#.utf8))
        XCTAssertNil(ChatGPTStreamOutput.toolCall(item))
    }

    func testCompletedReasoningIsNotTreatedAsAToolCall() throws {
        let item = try JSONDecoder().decode(OutputItem.self, from: Data(#"{"type":"reasoning","id":"rs_1","summary":[]}"#.utf8))
        XCTAssertNil(ChatGPTStreamOutput.toolCall(item))
    }

    func testFunctionCallPreservesCallIDAndArguments() throws {
        let item = try JSONDecoder().decode(OutputItem.self, from: Data(#"{"type":"function_call","id":"fc_1","call_id":"call_1","namespace":"hestrel","name":"lookup","arguments":"{\"query\":\"test\"}","status":"completed"}"#.utf8))
        let call = try XCTUnwrap(ChatGPTStreamOutput.toolCall(item))
        XCTAssertEqual(call.id, "call_1")
        XCTAssertEqual(call.name, "lookup")
        XCTAssertEqual(call.arguments, #"{"query":"test"}"#)
        XCTAssertNil(call.result)
    }

    func testNativeSearchToolHasCorrectWireType() throws {
        let data = try JSONEncoder().encode(ChatGPTStreamOutput.webSearchTool)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["type"] as? String, "web_search")
    }

    func testWebActionsAreHostedAndNeverPendingLocalExecution() throws {
        for (action, name) in [(#"{"type":"search","queries":["weather"]}"#, "Web search"),
                               (#"{"type":"open_page","url":"https://example.com"}"#, "Open page"),
                               (#"{"type":"find_in_page","url":"https://example.com","pattern":"hello"}"#, "Find in page")] {
            let json = #"{"type":"web_search_call","id":"ws_1","status":"completed","action":\#(action)}"#
            let item = try JSONDecoder().decode(OutputItem.self, from: Data(json.utf8))
            let call = try XCTUnwrap(ChatGPTStreamOutput.toolCall(item))
            XCTAssertEqual(call.id, "ws_1")
            XCTAssertEqual(call.name, name)
            XCTAssertTrue(call.isHosted)
            XCTAssertNotNil(call.result)
        }
    }

    func testSourcesAreClickableAndPreserveUnicodeProse() throws {
        let json = #"{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"🌍 News today","annotations":[{"type":"url_citation","url":"https://example.com/news","title":"News","start_index":2,"end_index":12}],"logprobs":[]}]}"#
        let item = try JSONDecoder().decode(OutputItem.self, from: Data(json.utf8))
        XCTAssertEqual(ChatGPTStreamOutput.citedText(item), "🌍 News today [News](<https://example.com/news>)")
    }

    func testEarlySearchEventAcrossArbitraryNetworkChunks() throws {
        let middleware = ChatGPTSearchStreamMiddleware()
        let frame = #"data: {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"web_search_call","id":"ws_1","status":"in_progress"}}"# + "\r\n\r\n"
        var output = Data()
        for byte in frame.utf8 {
            output.append(middleware.interceptStreamingData(request: nil, Data([byte])))
        }
        let text = try XCTUnwrap(String(data: output, encoding: .utf8))
        let payload = String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try JSONDecoder().decode(ResponseStreamEvent.self, from: Data(payload.utf8))
        let done = Data("data: [DONE]\n\n".utf8)
        XCTAssertEqual(middleware.interceptStreamingData(request: nil, done), done)
    }
}
