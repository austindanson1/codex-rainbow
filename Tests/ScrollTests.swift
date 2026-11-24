import Foundation

@main
struct ScrollTests {
    static func main() {
        let top: CGFloat = 100
        let frames: [CGRect] = [
            CGRect(x: 20, y: top, width: 250, height: 2),
            CGRect(x: 20, y: top, width: 250, height: 2),
            CGRect(x: 20, y: top, width: 250, height: 10),
            CGRect(x: 20, y: 112, width: 250, height: 30),
            CGRect(x: 20, y: 144, width: 250, height: 30),
            CGRect(x: 20, y: 270, width: 250, height: 2)
        ]
        precondition(CodexSidebar.firstCandidate(frames.count, top: top) { frames[$0] } == 2)
        precondition(CodexSidebar.firstCandidate(frames.count, top: 110) { frames[$0] } == 3)
        precondition(CodexSidebar.firstCandidate(frames.count, top: 180) { frames[$0] } == 5)
        precondition(CodexSidebar.firstCandidate(frames.count, top: 280) { frames[$0] } == frames.count)
        precondition(CodexSidebar.firstCandidate(frames.count, top: top) { _ in nil } == 0)
        print("Scroll viewport lookup passed")
    }
}
