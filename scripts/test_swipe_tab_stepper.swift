import Foundation

// Run: swiftc boringNotch/extensions/PanGesture.swift scripts/test_swipe_tab_stepper.swift -o /tmp/t && /tmp/t
@main
struct SwipeTabStepperTest {
    static func main() {
        // Home, Shelf, AI
        assert(SwipeTabStepper.targetIndex(current: 0, count: 3, forward: true, toEnd: false) == 1, "Home -> Shelf")
        assert(SwipeTabStepper.targetIndex(current: 1, count: 3, forward: true, toEnd: false) == 2, "Shelf -> AI")
        assert(SwipeTabStepper.targetIndex(current: 2, count: 3, forward: true, toEnd: false) == nil, "Stops at the last tab")
        assert(SwipeTabStepper.targetIndex(current: 0, count: 3, forward: false, toEnd: false) == nil, "Stops at the first tab")
        assert(SwipeTabStepper.targetIndex(current: 2, count: 3, forward: false, toEnd: false) == 1, "AI -> Shelf")

        // Long swipe
        assert(SwipeTabStepper.targetIndex(current: 0, count: 3, forward: true, toEnd: true) == 2, "Long swipe jumps to the last tab")
        assert(SwipeTabStepper.targetIndex(current: 2, count: 3, forward: false, toEnd: true) == 0, "Long swipe back jumps to Home")
        assert(SwipeTabStepper.targetIndex(current: 2, count: 3, forward: true, toEnd: true) == nil, "Already at the end")

        // Fewer tabs / not a tab
        assert(SwipeTabStepper.targetIndex(current: 0, count: 1, forward: true, toEnd: false) == nil, "Only Home: nothing to switch to")
        assert(SwipeTabStepper.targetIndex(current: 0, count: 2, forward: true, toEnd: true) == 1, "Two tabs: long swipe = next")
        assert(SwipeTabStepper.targetIndex(current: 5, count: 3, forward: true, toEnd: false) == nil, "Out of range is ignored")

        print("All tests passed.")
    }
}
