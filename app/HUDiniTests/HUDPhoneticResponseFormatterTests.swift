import XCTest
@testable import HUDini

final class HUDPhoneticResponseFormatterTests: XCTestCase {

    func testStripsBulletsAndWhitespace() {
        let input = "1.  Hola, me llamo Ryan.  \n¿Y tú?"
        let cleaned = HUDPhoneticResponseFormatter.clean(input)
        XCTAssertEqual(cleaned, "Hola, me llamo Ryan.")
    }

    func testRemovesDiacriticsAndNonAscii() {
        let input = "• Ça va très bien! 😊"
        let cleaned = HUDPhoneticResponseFormatter.clean(input)
        XCTAssertEqual(cleaned, "Ca va tres bien!")
    }

    func testKeepsSingleSentence() {
        let input = "Bonjour. Comment ca va?"
        let cleaned = HUDPhoneticResponseFormatter.clean(input)
        XCTAssertEqual(cleaned, "Bonjour.")
    }
}
