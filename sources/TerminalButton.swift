//
//  TerminalButton.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 9/26/23.
//

import Foundation

@available(macOS 11, *)
@objc(iTermTerminalButton)
class TerminalButton: NSObject {
    @objc var action: ((NSPoint) -> ())?
    private let tintedForegroundImage: TintedImage
    private let aspectRatio: CGFloat
    @objc weak var mark: iTermMarkProtocol?
    // Returns -1 if unset
    @objc var transientAbsY: Int {
        return -1
    }
    // Clients can use this as they like
    @objc var desiredFrame = NSRect.zero
    @objc var absCoordForDesiredFrame = VT100GridAbsCoordMake(-1, -1)
    @objc var pressed: Bool {
        switch state {
        case .normal: return false
        case .pressedInside, .pressedOutside: return true
        }
    }
    enum State: Int {
        case normal
        case pressedOutside
        case pressedInside
    }
    var floating: Bool { false }
    private(set) var state = State.normal
    @objc let id: Int
    @objc var enclosingSessionWidth: Int32 = 0
    @objc var shift = CGFloat(0)
    var selected: Bool { false }

    init(id: Int, backgroundImage: NSImage, foregroundImage: NSImage, mark: iTermMarkProtocol?) {
        self.id = id
        tintedForegroundImage = TintedImage(original: foregroundImage)
        self.mark = mark
        aspectRatio = foregroundImage.size.height / foregroundImage.size.width;
    }

    required init?(_ original: TerminalButton) {
        self.id = original.id
        tintedForegroundImage = original.tintedForegroundImage.clone()
        self.mark = original.mark
        aspectRatio = original.tintedForegroundImage.original.size.height / original.tintedForegroundImage.original.size.width;
        desiredFrame = original.desiredFrame
        absCoordForDesiredFrame = original.absCoordForDesiredFrame
        state = original.state
        enclosingSessionWidth = original.enclosingSessionWidth
        shift = original.shift
    }

    @objc func clone() -> Self {
        return Self(self)!
    }

    private func images(backgroundColor: NSColor,
                        foregroundColor: NSColor,
                        size: NSSize) -> (NSImage, NSImage) {
        return (tintedForegroundImage.tintedImage(color: foregroundColor,
                                                  size: size),
                NSImage.roundedRect(size: size,
                                    radius: 2,
                                    color: backgroundColor))
    }

    @objc func size(cellSize: NSSize) -> NSSize {
        let width = cellSize.width * 2
        var result = NSSize(width: width, height: aspectRatio * width);
        let scale = cellSize.height / result.height
        if scale < 1 {
            result.width *= scale
            result.height *= scale
        }
        return result.retinaRound(2.0)
    }

    @objc(frameWithX:absY:minAbsLine:cumulativeOffset:cellSize:)
    func frame(x: CGFloat,
               absY: Int,
               minAbsLine: Int64,
               cumulativeOffset: Int64,
               cellSize: NSSize) -> NSRect {
        let size = size(cellSize: cellSize)
        let height = size.height
        let yoff = max(0, (cellSize.height - height))
        return NSRect(x: x,
                      y: CGFloat(max(minAbsLine, Int64(absY)) - cumulativeOffset) * cellSize.height + yoff,
                      width: size.width,
                      height: height)
    }

    @objc(drawWithBackgroundColor:foregroundColor:selectedColor:frame:virtualOffset:)
    func draw(backgroundColor: NSColor,
              foregroundColor: NSColor,
              selectedColor: NSColor,
              frame rect: NSRect,
              virtualOffset: CGFloat) {
        
        let (foregroundImage, backgroundImage) = switch state {
        case .normal, .pressedOutside:
            images(backgroundColor: selected ? selectedColor : backgroundColor,
                   foregroundColor: foregroundColor,
                   size: rect.size)
        case .pressedInside:
            images(backgroundColor: foregroundColor, 
                   foregroundColor: backgroundColor,
                   size: rect.size)
        }
        backgroundImage.it_draw(in: rect, virtualOffset: virtualOffset)
        foregroundImage.it_draw(in: rect, virtualOffset: virtualOffset)
    }

    func image(backgroundColor: NSColor,
               foregroundColor: NSColor,
               selectedColor: NSColor,
               cellSize: CGSize) -> NSImage {
        let size = self.size(cellSize: cellSize)
        return NSImage(size: size,
                       flipped: false) { [weak self] _ in
            self?.draw(backgroundColor: backgroundColor,
                       foregroundColor: foregroundColor,
                       selectedColor: selectedColor,
                       frame: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                       virtualOffset: 0)
            return true
        }
    }
    var highlighted: Bool {
        switch state {
        case .normal, .pressedOutside:
            return false
        case .pressedInside:
            return true
        }
    }

    @objc
    func mouseDownInside() -> Bool {
        DLog("Mouse down inside on \(description)")
        let wasHighlighted = highlighted
        state = .pressedInside
        return highlighted != wasHighlighted
    }

    @objc
    func mouseDownOutside() -> Bool {
        DLog("Mouse down outside on \(description)")
        let wasHighlighted = highlighted
        state = .pressedOutside
        return highlighted != wasHighlighted
    }

    @objc
    @discardableResult
    func mouseUp(locationInWindow: NSPoint) -> Bool {
        DLog("mouseUp: TerminalButton.mouseUp initial state is \(state)");
        let wasHighlighted = highlighted
        switch state {
        case .pressedInside:
            DLog("mouseUp: TerminalButton.mouseUp DO ACTION");
            action?(locationInWindow)
            state = .normal
        case .pressedOutside:
            state = .normal
        case .normal:
            break
        }
        return highlighted != wasHighlighted
    }

    @objc
    func mouseExited() {
        switch state {
        case .pressedInside:
            state = .pressedOutside
        case .pressedOutside, .normal:
            state = .normal
        }
    }
}

@available(macOS 11, *)
@objc
class GenericBlockButton: TerminalButton {
    @objc let blockID: String
    @objc var absY: NSNumber?
    override var transientAbsY: Int {
        if let absY {
            return absY.intValue
        }
        return -1
    }
    @objc var isFloating = false
    override var floating: Bool { isFloating }
    init?(id: Int, blockID: String, mark: iTermMarkProtocol?, absY: NSNumber?, fgName: String, bgName: String) {
        self.blockID = blockID
        guard let bg = NSImage(systemSymbolName: bgName, accessibilityDescription: nil),
              let fg = NSImage(systemSymbolName: fgName, accessibilityDescription: nil) else {
            return nil
        }
        self.absY = absY
        super.init(id: id,
                   backgroundImage: bg,
                   foregroundImage: fg,
                   mark: mark)
    }

    required init?(_ original: TerminalButton) {
        let downcast = original as! GenericBlockButton
        self.blockID = downcast.blockID
        self.absY = downcast.absY
        isFloating = downcast.isFloating
        super.init(original)
    }

    override func clone() -> Self {
        return Self(self)!
    }
}

@available(macOS 11, *)
@objc(iTermTerminalCopyButton)
class TerminalCopyButton: GenericBlockButton {
    @objc(initWithID:blockID:mark:absY:)
    init?(id: Int, blockID: String, mark: iTermMarkProtocol?, absY: NSNumber?) {
        super.init(id: id,
                   blockID: blockID,
                   mark: mark,
                   absY: absY,
                   fgName: "doc.on.doc",
                   bgName: "doc.on.doc.fill")
    }

    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}
    
@available(macOS 11, *)
@objc(iTermTerminalFoldBlockButton)
class TerminalFoldBlockButton: GenericBlockButton {
    @objc let absLineRange: NSRange
    @objc let folded: Bool

    @objc(initWithID:blockID:mark:absY:currentlyFolded:absLineRange:)
    init?(id: Int,
          blockID: String,
          mark: iTermMarkProtocol?,
          absY: NSNumber?,
          currentlyFolded: Bool,
          absLineRange: NSRange) {
        self.absLineRange = absLineRange
        self.folded = currentlyFolded
        let symbolName = currentlyFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
        super.init(id: id,
                   blockID: blockID,
                   mark: mark,
                   absY: absY,
                   fgName: symbolName,
                   bgName: symbolName)
    }

    required init?(_ original: TerminalButton) {
        absLineRange = (original as! TerminalFoldBlockButton).absLineRange
        folded = (original as! TerminalFoldBlockButton).folded
        super.init(original)
    }
}


@available(macOS 11, *)
@objc(iTermTerminalMarkButton)
class TerminalMarkButton: TerminalButton {
    @objc let screenMark: VT100ScreenMarkReading
    @objc let dx: Int32
    @objc var shouldFloat = false

    init?(identifier: Int,
          mark: VT100ScreenMarkReading,
          fgName: String,
          bgName: String,
          dx: Int32) {
        self.screenMark = mark
        guard let bg = NSImage(systemSymbolName: bgName, accessibilityDescription: nil),
              let fg = NSImage(systemSymbolName: fgName, accessibilityDescription: nil) else {
            return nil
        }
        self.dx = dx
        super.init(id: -2,
                   backgroundImage: bg,
                   foregroundImage: fg,
                   mark: mark)
    }

    required init?(_ original: TerminalButton) {
        let downcast = original as! TerminalMarkButton
        self.screenMark = downcast.screenMark
        self.dx = downcast.dx
        super.init(original)
    }

    override func clone() -> Self {
        return Self(self)!
    }
}

@available(macOS 11, *)
@objc(iTermTerminalCopyCommandButton)
class TerminalCopyCommandButton: TerminalMarkButton {

    @objc(initWithMark:dx:)
    init?(mark: VT100ScreenMarkReading, dx: Int32) {
        super.init(identifier: -2, mark: mark, fgName: "doc.on.doc", bgName: "doc.on.doc.fill", dx: dx)
    }

    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}


@available(macOS 11, *)
@objc(iTermTerminalBookmarkButton)
class TerminalBookmarkButton: TerminalMarkButton {
    override var selected: Bool {
        return screenMark.name != nil
    }
    @objc(initWithMark:dx:)
    init?(mark: VT100ScreenMarkReading, dx: Int32) {
        super.init(identifier: -3, mark: mark, fgName: "bookmark", bgName: "bookmark.fill", dx: dx)
    }
    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}

@available(macOS 11, *)
@objc(iTermTerminalShareButton)
class TerminalShareButton: TerminalMarkButton {
    @objc(initWithMark:dx:)
    init?(mark: VT100ScreenMarkReading, dx: Int32) {
        super.init(identifier: -4, mark: mark, fgName: "square.and.arrow.up", bgName: "square.and.arrow.up.fill", dx: dx)
    }
    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}

@available(macOS 11, *)
@objc(iTermCommandInfoButton)
class TerminalCommandInfoButton: TerminalMarkButton {
    @objc(initWithMark:dx:)
    init?(mark: VT100ScreenMarkReading, dx: Int32) {
        super.init(identifier: -5, mark: mark, fgName: "info.circle", bgName: "info.circle.fill", dx: dx)
    }
    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}

@available(macOS 11, *)
@objc(iTermTerminalFoldButton)
class TerminalFoldButton: TerminalMarkButton {
    @objc(initWithMark:dx:)
    init?(mark: VT100ScreenMarkReading, dx: Int32) {
        super.init(identifier: -6, mark: mark, fgName: "rectangle.compress.vertical", bgName: "rectangle.compress.vertical", dx: dx)
    }
    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}

@available(macOS 11, *)
@objc(iTermTerminalUnfoldButton)
class TerminalUnfoldButton: TerminalMarkButton {
    @objc(initWithMark:dx:)
    init?(mark: VT100ScreenMarkReading, dx: Int32) {
        super.init(identifier: -7, mark: mark, fgName: "rectangle.expand.vertical", bgName: "rectangle.expand.vertical", dx: dx)
    }
    required init?(_ original: TerminalButton) {
        super.init(original)
    }
}

extension NSImage {
    static func roundedRect(size: NSSize, radius: CGFloat, color: NSColor) -> NSImage {
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size.width, height: size.height), xRadius: radius, yRadius: radius)
            path.fill()
            return true
        }
    }
}
