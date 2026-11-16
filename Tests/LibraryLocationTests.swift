import XCTest
@testable import Kapi

/// 乐库位置的选择记录，以及选目标文件夹时的排除规则。
/// 类本身不标 @MainActor：XCTest 的 setUp / tearDown 是非隔离的，整类标了会有隔离警告；
/// 只有碰 LibraryRoot、FolderPicker 的用例单独标
final class LibraryLocationTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        saved = UserDefaults.standard.string(forKey: LibraryRoot.Location.defaultsKey)
    }

    override func tearDown() {
        // 测试和 App 共用 standard defaults，跑完还原，免得把模拟器上的选择弄丢
        if let saved {
            UserDefaults.standard.set(saved, forKey: LibraryRoot.Location.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LibraryRoot.Location.defaultsKey)
        }
    }

    @MainActor
    func testNotChosenFallsBackToICloudForText() {
        UserDefaults.standard.removeObject(forKey: LibraryRoot.Location.defaultsKey)
        XCTAssertNil(LibraryRoot.Location.chosen)
        XCTAssertEqual(LibraryRoot.Location.stored, .icloud)
    }

    @MainActor
    func testChosenValueIsRead() {
        UserDefaults.standard.set("local", forKey: LibraryRoot.Location.defaultsKey)
        XCTAssertEqual(LibraryRoot.Location.chosen, .local)
        XCTAssertEqual(LibraryRoot.Location.stored, .local)
    }

    @MainActor
    func testUnknownValueCountsAsNotChosen() {
        UserDefaults.standard.set("nas", forKey: LibraryRoot.Location.defaultsKey)
        XCTAssertNil(LibraryRoot.Location.chosen)
    }

    @MainActor
    func testNewRootStartsInChoiceStateWhenNothingChosen() {
        UserDefaults.standard.removeObject(forKey: LibraryRoot.Location.defaultsKey)
        let root = LibraryRoot()
        root.start()
        XCTAssertEqual(root.state, .needsChoice)
        XCTAssertFalse(root.hasChosen)
    }

    @MainActor
    func testChooseLeavesChoiceStateAndRemembers() {
        UserDefaults.standard.removeObject(forKey: LibraryRoot.Location.defaultsKey)
        let root = LibraryRoot()
        root.start()
        root.choose(.local)
        XCTAssertEqual(root.location, .local)
        XCTAssertTrue(root.hasChosen)
        XCTAssertNotEqual(root.state, .needsChoice)
        XCTAssertEqual(LibraryRoot.Location.chosen, .local)
    }

    @MainActor
    func testFolderPickerExcludesFolderAndDescendantsOnly() {
        let excluded: Set<String> = ["华语/怀旧"]
        XCTAssertTrue(FolderPicker.isExcluded("华语/怀旧", excluded))
        XCTAssertTrue(FolderPicker.isExcluded("华语/怀旧/老歌", excluded))
        XCTAssertFalse(FolderPicker.isExcluded("华语", excluded))
        XCTAssertFalse(FolderPicker.isExcluded("华语/怀旧2", excluded))
        XCTAssertFalse(FolderPicker.isExcluded("", excluded))
    }
}
