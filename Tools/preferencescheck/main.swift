import Foundation
let suite = CommandLine.arguments[1]
let defaults = UserDefaults(suiteName: suite)!
switch CommandLine.arguments[2] {
case "write":
    ScreenSize.moreSpace.save(to: defaults)
case "read":
    precondition(ScreenSize.load(from: defaults) == .moreSpace)
    precondition(ScreenSize.allCases.count == 2)
    precondition(!ScreenSize.allCases.contains { $0.title == "Larger Text" })
    precondition(ModeID.selectableCases == [.secondDisplay, .dashboard])
    print("Saved screen size survived a separate process; removed menu options are absent")
case "migrate":
    defaults.set("largeText", forKey: "screenSize")
    precondition(ScreenSize.load(from: defaults) == .standard)
    precondition(defaults.string(forKey: "screenSize") == "standard")
    defaults.removePersistentDomain(forName: suite)
    print("Legacy Larger Text preference migrated")
default: fatalError("Unknown test action")
}
