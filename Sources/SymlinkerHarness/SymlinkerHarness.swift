import Foundation
import DroppyKit
import DroppyKitHarness
import Symlinker

@main
struct SymlinkerHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        let droplet = SymlinkerDroplet()
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let state = environment["SYMLINKER_PREVIEW_STATE"], let directory = environment["SYMLINKER_PREVIEW_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory)
            droplet.preparePreview(state: state, source: root.appendingPathComponent("Project notes.txt"),
                                   destination: root.appendingPathComponent("Workspace"))
        }
        if let output = environment["SYMLINKER_PLAYGROUND_SHOT"] { droplet.renderPlayground(to: output) }
        #endif
        return droplet
    }
}
