import Foundation

// swiftc Tools/welcomecheck/main.swift Phone/FirstRunWelcome.swift -o build/welcomecheck
let build = Date(timeIntervalSince1970: 1000)
let oldContainer = build.addingTimeInterval(-100)
let newContainer = build.addingTimeInterval(100)
precondition(FirstRunWelcome.shouldWelcome(seen: false, containerDate: newContainer, buildDate: build))
precondition(!FirstRunWelcome.shouldWelcome(seen: true, containerDate: newContainer, buildDate: build))
precondition(!FirstRunWelcome.shouldWelcome(seen: false, containerDate: oldContainer, buildDate: build))
precondition(!FirstRunWelcome.shouldWelcome(seen: false, containerDate: nil, buildDate: build))
precondition(!FirstRunWelcome.shouldWelcome(seen: false, containerDate: newContainer, buildDate: nil))
let suite = "septintas.welcomecheck.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
_ = FirstRunWelcome.claim(defaults: defaults)
precondition(defaults.bool(forKey: FirstRunWelcome.seenKey))
precondition(!FirstRunWelcome.claim(defaults: defaults))
print("Welcome: fresh install, repeat launch, legacy migration, missing dates and launch claim passed")
