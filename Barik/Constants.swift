import CoreFoundation

struct Constants {
    static let menuBarHeight = CGFloat(55)
    static let menuBarPopupAnimationDurationInMilliseconds = 350
    static let menuBarHorizontalPadding = CGFloat(25)
    /// How long to wait after the cursor leaves an auto-hidden system menu bar
    /// before raising Barik back above it, so macOS can finish sliding the
    /// menu bar out instead of the two briefly overlapping.
    static let menuBarRestoreDelayInMilliseconds = 400
    /// Full height of widget backgrounds such as the spaces pills. Bars too
    /// short to fit this plus their vertical padding use shorter backgrounds.
    static let widgetContentHeight = CGFloat(30)
    /// Default empty space above and below the widgets, as a fraction of the
    /// bar height (per side). 0.1 keeps 30pt pills on a 38pt notched menu bar
    /// and gives a 30pt external one 24pt pills with 3pt above and below.
    static let menuBarVerticalPaddingRatio = CGFloat(0.1)
}
