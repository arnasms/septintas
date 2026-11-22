import Foundation

// Checks how Control Center's camera log lines are read, using lines captured from macOS 15.

let obs = "7626645E-4425-469E-9D8B-97E0FA59AC75"
let cases: [(String, Set<String>?)] = [
    ("Frame publisher cameras changed to [com.apple.PhotoBooth: [\"\(obs)\"]]", [obs]),
    ("Frame publisher cameras changed to [:]", []),
    ("Frame publisher cameras changed to [us.zoom.xos: [\"\(obs)\"], com.apple.PhotoBooth: [\"FDF90FEB-59E5-4FCF-AABD-DA03C4E19BFB\"]]",
     [obs, "FDF90FEB-59E5-4FCF-AABD-DA03C4E19BFB"]),
    ("Frame publisher cameras changed to [com.google.Chrome: [\"A\", \"B\"]]", ["A", "B"]),
    ("Navigating to new application [com.apple.PhotoBooth]", nil),
    ("Frame publisher cameras changed to nothing", nil),
]
var failed = false
for (message, expected) in cases where CameraViewers.cameras(inMessage: message) != expected {
    print("FAIL: \(message) -> \(String(describing: CameraViewers.cameras(inMessage: message)))")
    failed = true
}
if failed { exit(1) }
print("Camera viewer lines passed: one app, none, two apps on two cameras, unrelated lines")
