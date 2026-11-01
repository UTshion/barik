import CoreFoundation

struct Constants {
    static let menuBarHeight = CGFloat(55)
    static let menuBarPopupAnimationDurationInMilliseconds = 350
    static let menuBarHorizontalPadding = CGFloat(25)
    /// How long to wait after the cursor leaves an auto-hidden system menu bar
    /// before raising Barik back above it, so macOS can finish sliding the
    /// menu bar out instead of the two briefly overlapping.
    static let menuBarRestoreDelayInMilliseconds = 400
}
