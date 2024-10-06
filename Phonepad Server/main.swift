import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var blePeripheral: BLEPeripheral?
    var popover: NSPopover?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("Application did finish launching")
        let macOSTrackpad = MacOSTrackpad()
        let dataParser = StandardTrackpadDataParser()
        blePeripheral = BLEPeripheral(trackpad: macOSTrackpad, dataParser: dataParser)
        createMenuBarItem()
        setupPopover()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        print("Application will terminate")
    }
    
    private func createMenuBarItem() {
        print("Creating menu bar item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "touchpad", accessibilityDescription: "Phonepad")
            if button.image == nil {
                print("Failed to set image, using fallback text")
                button.title = "P"
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        } else {
            print("Failed to create status item button")
        }
    }
    
    private func setupPopover() {
        print("Setting up popover")
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 150)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: PopoverView(blePeripheral: blePeripheral!))
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        print("Toggle popover called")
        if let button = statusItem?.button {
            if popover?.isShown == true {
                print("Closing popover")
                popover?.performClose(sender)
            } else {
                print("Showing popover")
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var blePeripheral: BLEPeripheral
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Phonepad Server")
                .font(.headline)
            
            Text(blePeripheral.isConnected ? "Connected" : "Disconnected")
                .foregroundColor(blePeripheral.isConnected ? .green : .red)
            
            HStack {
                Text("Sensitivity:")
                Slider(value: $blePeripheral.sensitivity, in: 0.25...2.0, step: 0.25)
            }
            
            Button(action: {
                if blePeripheral.isAdvertising {
                    blePeripheral.stopAdvertising()
                } else {
                    blePeripheral.startAdvertising()
                }
            }) {
                Text(blePeripheral.isAdvertising ? "Stop Advertising" : "Start Advertising")
            }
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }
}

print("Starting application")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

print("Delegate set, running application")
app.run()
