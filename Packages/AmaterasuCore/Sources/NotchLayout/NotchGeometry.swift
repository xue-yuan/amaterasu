import CoreGraphics

/// Where the hardware notch is on a screen, or where the fallback capsule goes on a screen without one.
/// All rects are in AppKit screen coordinates (bottom-left origin, global).
public struct NotchGeometry: Equatable, Sendable {
    /// The notch cut-out, or the fallback capsule's area on a screen without a notch.
    public let notchRect: CGRect
    public let hasHardwareNotch: Bool
    public let screenFrame: CGRect

    /// The parameters mirror `NSScreen`: `frame`, `safeAreaInsets.top`, `auxiliaryTopLeftArea`,
    /// `auxiliaryTopRightArea`. `menuBarHeight` and `fallbackWidth` size the capsule on screens without a notch.
    public init(
        screenFrame: CGRect,
        safeAreaTop: CGFloat,
        topLeftArea: CGRect?,
        topRightArea: CGRect?,
        menuBarHeight: CGFloat,
        fallbackWidth: CGFloat
    ) {
        self.screenFrame = screenFrame
        if safeAreaTop > 0, let left = topLeftArea, let right = topRightArea {
            // Accept the auxiliary areas either in global coordinates or relative to the screen's origin.
            let offset = screenFrame.intersects(left) ? CGPoint.zero : screenFrame.origin
            let notchMinX = left.maxX + offset.x
            let notchMaxX = right.minX + offset.x
            if notchMaxX > notchMinX {
                notchRect = CGRect(x: notchMinX, y: screenFrame.maxY - safeAreaTop, width: notchMaxX - notchMinX, height: safeAreaTop)
                hasHardwareNotch = true
                return
            }
        }
        let height = max(menuBarHeight, 24)
        let width = min(fallbackWidth, screenFrame.width)
        notchRect = CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
        hasHardwareNotch = false
    }

    /// A panel frame of `size`, hanging from the top of the screen and centred on the notch, kept on screen.
    public func panelFrame(for size: CGSize) -> CGRect {
        let width = min(size.width, screenFrame.width)
        let x = min(max(notchRect.midX - width / 2, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: x, y: screenFrame.maxY - size.height, width: width, height: size.height)
    }
}

/// Panel sizes for the collapsed and expanded states.
public struct PanelMetrics: Equatable, Sendable {
    /// Width of each "ear" beside the hardware notch that shows the main deck while collapsed.
    public var earWidth: CGFloat = 72
    /// Outward curve where the panel meets the top edge of the screen, like the hardware notch.
    public var topFlare: CGFloat = 6
    public var deckWidth: CGFloat = 168
    public var deckSpacing: CGFloat = 10
    public var horizontalPadding: CGFloat = 16
    /// Height of the expanded content below the notch: deck cards plus the recommendation row.
    public var contentHeight: CGFloat = 166
    /// Narrowest content width while decks are shown, so the recommendation chips fit.
    public var minimumDecksWidth: CGFloat = 420
    /// Extra height for the "next track" suggestions (a title and three rows).
    public var suggestionsHeight: CGFloat = 78
    /// Content size when no deck is loaded ("Waiting for Serato…").
    public var emptyContentWidth: CGFloat = 220
    public var emptyContentHeight: CGFloat = 52

    public init() {}

    /// On a notched screen the panel covers the notch, plus the ears when there is something to show.
    /// On other screens it is the fallback capsule.
    public func collapsedSize(for geometry: NotchGeometry, showsEars: Bool) -> CGSize {
        let notch = geometry.notchRect.size
        guard geometry.hasHardwareNotch else { return notch }
        let ears = showsEars ? 2 * earWidth : 0
        return CGSize(width: notch.width + ears + 2 * topFlare, height: notch.height)
    }

    public func expandedSize(for geometry: NotchGeometry, deckCount: Int, showsSuggestions: Bool = false) -> CGSize {
        let notch = geometry.notchRect.size
        let count = CGFloat(max(deckCount, 0))
        let decks = deckCount == 0
            ? emptyContentWidth
            : max(count * deckWidth + (count - 1) * deckSpacing, minimumDecksWidth)
        let width = max(decks + 2 * horizontalPadding, notch.width + 2 * earWidth) + 2 * topFlare
        let content = deckCount == 0 ? emptyContentHeight : contentHeight + (showsSuggestions ? suggestionsHeight : 0)
        return CGSize(width: width, height: notch.height + content)
    }
}
