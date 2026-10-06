import XCTest
@testable import Calshot

final class OpenAIStreamTests: XCTestCase {
    func testRequiresCompletedEvent() throws {
        let partial = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n"
        XCTAssertThrowsError(try OpenAIEventAnalyzer.completedStreamResponse(Data(partial.utf8)))

        let complete = "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"events\\\":[]}\"}]}]}}\n\n"
        let result = try OpenAIEventAnalyzer.completedStreamResponse(Data(complete.utf8))
        XCTAssertEqual(result.output?.first?.content?.first?.text, "{\"events\":[]}")
    }

    func testFailedEventIsNotAccepted() {
        let failed = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Usage limit reached\"}}}\n\n"
        XCTAssertThrowsError(try OpenAIEventAnalyzer.completedStreamResponse(Data(failed.utf8)))
    }

    func testUsesCompletedOutputItemWhenFinalEnvelopeOmitsOutput() throws {
        let item = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"events\\\":[]}\"}]}}\n\n"
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
        let result = try OpenAIEventAnalyzer.completedStreamResponse(Data((item + completed).utf8))
        XCTAssertEqual(result.output?.first?.content?.first?.text, "{\"events\":[]}")
    }
}
