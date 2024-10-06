import Cocoa

protocol TrackpadProtocol {
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat)
    func performClick(button: MouseButton)
    func scroll(deltaY: CGFloat)
    func setSensitivity(_ newSensitivity: CGFloat)
    func handleGesture(_ gestureType: GestureType, deltaX: CGFloat, deltaY: CGFloat)
}

enum MouseButton {
    case left
    case right
}

class QuartzSpaceSwitcher {
    private let eventSource: CGEventSource
    
    init() {
        eventSource = CGEventSource(stateID: .combinedSessionState)!
    }
    
    func switchSpace(direction: Int32) {
        let keyCode: Int64 = direction == 1 ? 0x7B : 0x7C // Left Arrow : Right Arrow
        let keyName = direction == 1 ? "Left Arrow" : "Right Arrow"
        
        print("Attempting to switch space: Direction = \(direction > 0 ? "Left" : "Right")")
        print("Simulating key press: Ctrl + \(keyName)")
        
        // Create key down event
        guard let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
            print("Failed to create key down event")
            return
        }
        
        // Set flags for Ctrl + Cmd
        keyDownEvent.flags = [.maskCommand]
        
        print("Sending key down event: Ctrl + \(keyName)")
        // Post the key down event
        keyDownEvent.post(tap: .cghidEventTap)
        
        // Create key up event
        guard let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            print("Failed to create key up event")
            return
        }
        
        // Set flags for Ctrl + Cmd
        keyUpEvent.flags = [.maskCommand, .maskControl]
        
        print("Sending key up event: Ctrl + \(keyName)")
        // Post the key up event
        keyUpEvent.post(tap: .cghidEventTap)
        
        print("Finished sending events for space switch")
    }
}

class MacOSTrackpad: TrackpadProtocol {
    private let spaceSwitcher: QuartzSpaceSwitcher
    private var currentMousePosition: CGPoint = .zero
    private var sensitivity: CGFloat = 0.5
    private let scrollSensitivity: CGFloat = 0.3
    private var lastScrollTime: Date = Date()
    
    init() {
        spaceSwitcher = QuartzSpaceSwitcher()
    }
    
    func setSensitivity(_ newSensitivity: CGFloat) {
        sensitivity = newSensitivity
    }
    
    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) {
        if let screen = NSScreen.main {
            let scaleFactor: CGFloat = 1.0 // Increase this value to make the cursor move faster
            let adjustedDeltaX = deltaX * sensitivity * scaleFactor
            let adjustedDeltaY = deltaY * sensitivity * scaleFactor
            
            let newX = currentMousePosition.x + adjustedDeltaX
            let newY = currentMousePosition.y + adjustedDeltaY
            
            currentMousePosition.x = max(0, min(newX, screen.frame.width))
            currentMousePosition.y = max(0, min(newY, screen.frame.height))
            
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: currentMousePosition, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
        }
    }
    
    func performClick(button: MouseButton) {
        let mouseButton: CGMouseButton = button == .right ? .right : .left
        let mouseDownType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let mouseUpType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        
        if let downEvent = CGEvent(mouseEventSource: nil, mouseType: mouseDownType, mouseCursorPosition: currentMousePosition, mouseButton: mouseButton) {
            downEvent.post(tap: .cghidEventTap)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let upEvent = CGEvent(mouseEventSource: nil, mouseType: mouseUpType, mouseCursorPosition: self.currentMousePosition, mouseButton: mouseButton) {
                upEvent.post(tap: .cghidEventTap)
            }
        }
    }
    
    func scroll(deltaY: CGFloat) {
        let currentTime = Date()
        let timeDelta = currentTime.timeIntervalSince(lastScrollTime)
        lastScrollTime = currentTime
        
        // Adjust scroll amount based on time delta to maintain consistent speed
        let adjustedDeltaY = deltaY * scrollSensitivity * CGFloat(timeDelta * 60) // Assuming 60 FPS as baseline
        
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(adjustedDeltaY), wheel2: 0, wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }
    
    func handleGesture(_ gestureType: GestureType, deltaX: CGFloat, deltaY: CGFloat) {
        switch gestureType {
        case .move:
            moveCursor(deltaX: deltaX, deltaY: deltaY)
        case .leftClick:
            performClick(button: .left)
        case .rightClick:
            performClick(button: .right)
        case .scroll:
            scroll(deltaY: deltaY)
        case .switchSpaceLeft:
            spaceSwitcher.switchSpace(direction: 1)
        case .switchSpaceRight:
            spaceSwitcher.switchSpace(direction: -1)
        }
    }
}
