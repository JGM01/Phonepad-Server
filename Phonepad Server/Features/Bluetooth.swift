import CoreBluetooth
import Cocoa
import AppleScriptObjC

class BLEPeripheral: NSObject, ObservableObject {
    @Published var isAdvertising = false
    @Published var isConnected = false
    @Published var sensitivity: Double = 0.5 {
        didSet {
            print("Sensitivity updated to: \(sensitivity)")
            trackpad.setSensitivity(CGFloat(sensitivity))
        }
    }
    
    private let bluetoothService: BluetoothService
    private let trackpad: MacOSTrackpad
    private let appTracker: AppTracker
    
    private var textReceiver = TextReceiver()
        private var receivedTextBuffer = Data()
    
    init(trackpad: MacOSTrackpad, dataParser: TrackpadDataParser) {
        print("Initializing BLEPeripheral")
        self.trackpad = trackpad
        self.bluetoothService = BluetoothService(dataParser: dataParser)
        self.appTracker = AppTracker()
        self.textReceiver = TextReceiver()
        super.init()
        self.bluetoothService.delegate = self
        self.appTracker.blePeripheral = self
    }
    
    func startAdvertising() {
        print("Starting to advertise")
        bluetoothService.startAdvertising()
        isAdvertising = true
    }
    
    func stopAdvertising() {
        print("Stopping advertising")
        bluetoothService.stopAdvertising()
        isAdvertising = false
    }
    
    func sendAppUpdate(_ data: Data) {
        print("Queueing app update. Data size: \(data.count) bytes")
        bluetoothService.queueAppUpdate(data)
    }
    
    func handleAppListRequest() {
        print("Received request for full app list")
        appTracker.sendFullAppList()
    }
    
    func handleChunkAcknowledgment(appIndex: Int, chunkIndex: Int) {
        appTracker.handleChunkAcknowledgment(appIndex: appIndex, chunkIndex: chunkIndex)
    }
    
    func handleReceivedText(_ data: Data) {
            receivedTextBuffer.append(data)
            
            // Check if this is the last chunk (you may need to implement a proper protocol to determine this)
            let isLastChunk = true // This should be determined based on your protocol
            
            if isLastChunk {
                if let text = String(data: receivedTextBuffer, encoding: .utf8) {
                    print("Received complete text. Length: \(text.count) characters")
                    DispatchQueue.main.async {
                        self.textReceiver.insertText(text)
                    }
                } else {
                    print("Error: Unable to convert received data to string")
                }
                receivedTextBuffer = Data() // Clear the buffer
            }
        }
}

extension BLEPeripheral: BluetoothServiceDelegate {
    func didReceiveText(_ data: Data) {
        handleReceivedText(data)

    }
    
    func didReceiveTrackpadData(_ data: TrackpadData) {
        print("Received trackpad data: deltaX: \(data.deltaX), deltaY: \(data.deltaY), gestureType: \(data.gestureType)")
        trackpad.handleGesture(data.gestureType, deltaX: CGFloat(data.deltaX), deltaY: CGFloat(data.deltaY))
    }
    
    func didUpdateConnectionState(isConnected: Bool) {
        print("Connection state updated: \(isConnected ? "Connected" : "Disconnected")")
        DispatchQueue.main.async {
            self.isConnected = isConnected
            if isConnected {
                self.bluetoothService.sendQueuedUpdates()
            }
        }
    }
    
    func didReceiveAppSwitchRequest(bundleIdentifier: String) {
        print("Received app switch request for bundle identifier: \(bundleIdentifier)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Add a slight delay
            let workspace = NSWorkspace.shared
            
            // Try to find the running app
            if let runningApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                // First, try to activate using native methods
                if #available(macOS 14.0, *) {
                    runningApp.activate(options: [])
                } else {
                    runningApp.activate(options: .activateIgnoringOtherApps)
                }
                
                // If native activation doesn't work, try AppleScript
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if runningApp.isActive == false {
                        self.activateAppUsingAppleScript(appName: runningApp.localizedName ?? "")
                    } else {
                        print("Successfully activated app: \(bundleIdentifier)")
                    }
                }
            } else {
                // If the app is not running, try to launch it
                if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                    do {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                         workspace.openApplication(at: appURL, configuration: configuration)
                        print("Launched and activated app: \(bundleIdentifier)")
                    }
                } else {
                    print("Could not find app with bundle identifier: \(bundleIdentifier)")
                }
            }
        }
    }

    private func activateAppUsingAppleScript(appName: String) {
        let script = """
        tell application "System Events"
            if exists process "\(appName)" then
                set frontmost of process "\(appName)" to true
            end if
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript execution failed: \(error)")
                // Fallback to other methods or notify the user
            } else {
                print("Activated running app via AppleScript: \(appName)")
            }
        }
    }
    
    func didReceiveAppListRequest() {
        handleAppListRequest()
    }
    
    func didReceiveChunkAcknowledgment(appIndex: Int, chunkIndex: Int) {
        handleChunkAcknowledgment(appIndex: appIndex, chunkIndex: chunkIndex)
    }
}

class BluetoothService: NSObject, CBPeripheralManagerDelegate {
    weak var delegate: BluetoothServiceDelegate?
    
    private var peripheralManager: CBPeripheralManager!
    private var transferService: CBMutableService?
    private var transferCharacteristic: CBMutableCharacteristic?
    private var appUpdateCharacteristic: CBMutableCharacteristic?
    private var appSwitchCharacteristic: CBMutableCharacteristic?
    private var appListRequestCharacteristic: CBMutableCharacteristic?
    private var chunkAckCharacteristic: CBMutableCharacteristic?
    private var textTransferCharacteristic: CBMutableCharacteristic?
    
    private let serviceUUID = CBUUID(string: "5FFB1810-2672-4FFE-B9B8-54122F7E4F99")
    private let characteristicUUID = CBUUID(string: "34722DA8-9E9A-44A3-BB59-9E8E3A41728E")
    private let appUpdateCharacteristicUUID = CBUUID(string: "481B51DC-5649-4F0F-B1EE-EC527E0B985B")
    private let appSwitchCharacteristicUUID = CBUUID(string: "D62D00F3-02ED-4005-B427-86B5E4881601")
    private let appListRequestCharacteristicUUID = CBUUID(string: "65E43765-0C73-4F52-85D3-C49D068AA5BF")
    private let chunkAckCharacteristicUUID = CBUUID(string: "C54DCF47-7708-40E9-90F9-013723282D14")
    private let textTransferCharacteristicUUID = CBUUID(string: "733E7C66-6D92-46F9-9EB3-276172C93C8A")
    
    private let dataParser: TrackpadDataParser
    private var appUpdateQueue: [Data] = []
    private var isSubscribed = false
    
    init(dataParser: TrackpadDataParser) {
        print("Initializing BluetoothService")
        self.dataParser = dataParser
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("Peripheral manager state updated: \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            setupService()
            startAdvertising() // Add this line
        }
    }
    
    private func setupService() {
        print("Setting up Bluetooth service")
        transferService = CBMutableService(type: serviceUUID, primary: true)
        
        transferCharacteristic = CBMutableCharacteristic(
            type: characteristicUUID,
            properties: [.writeWithoutResponse, .write],
            value: nil,
            permissions: .writeable
        )
        
        appUpdateCharacteristic = CBMutableCharacteristic(
            type: appUpdateCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: .readable
        )
        
        appSwitchCharacteristic = CBMutableCharacteristic(
            type: appSwitchCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: .writeable
        )
        
        appListRequestCharacteristic = CBMutableCharacteristic(
            type: appListRequestCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: .writeable
        )
        
        chunkAckCharacteristic = CBMutableCharacteristic(
            type: chunkAckCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: .writeable
        )
        
        textTransferCharacteristic = CBMutableCharacteristic(
            type: textTransferCharacteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: .writeable
        )
        
        transferService?.characteristics = [
            transferCharacteristic!,
            appUpdateCharacteristic!,
            appSwitchCharacteristic!,
            appListRequestCharacteristic!,
            chunkAckCharacteristic!,
            textTransferCharacteristic!
        ]
        
        peripheralManager.add(transferService!)
        print("Service set up complete")
    }
    
    func startAdvertising() {
        print("Starting to advertise Bluetooth service")
        if peripheralManager.state == .poweredOn {
            peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                CBAdvertisementDataLocalNameKey: "Phonepad Server"
            ])
            print("Advertising started successfully")
        } else {
            print("Cannot start advertising. Peripheral manager state: \(peripheralManager.state.rawValue)")
        }
    }
    
    func stopAdvertising() {
        print("Stopping Bluetooth advertising")
        peripheralManager.stopAdvertising()
    }
    
    func queueAppUpdate(_ data: Data) {
        print("Queueing app update. Data size: \(data.count) bytes")
        appUpdateQueue.append(data)
        if isSubscribed {
            sendQueuedUpdates()
        }
    }
    
    func sendQueuedUpdates() {
        guard isSubscribed else {
            print("No subscribers. Updates queued: \(appUpdateQueue.count)")
            return
        }
        
        for update in appUpdateQueue {
            print("Sending queued app update. Data size: \(update.count) bytes")
            peripheralManager.updateValue(update, for: appUpdateCharacteristic!, onSubscribedCentrals: nil)
        }
        appUpdateQueue.removeAll()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("Central subscribed to characteristic: \(characteristic.uuid)")
        if characteristic.uuid == appUpdateCharacteristicUUID {
            isSubscribed = true
            sendQueuedUpdates()
            delegate?.didUpdateConnectionState(isConnected: true)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        print("Central unsubscribed from characteristic: \(characteristic.uuid)")
        if characteristic.uuid == appUpdateCharacteristicUUID {
            isSubscribed = false
            delegate?.didUpdateConnectionState(isConnected: false)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        print("Received write requests: \(requests.count)")
        for request in requests {
            print("Received write request for characteristic: \(request.characteristic.uuid)")
            if request.characteristic.uuid == textTransferCharacteristicUUID, let value = request.value {
                delegate?.didReceiveText(value)
                print("Failed to parse received text data")
            } else if request.characteristic.uuid == characteristicUUID, let value = request.value {
                print("Received trackpad data. Size: \(value.count) bytes")
                if let trackpadData = dataParser.parse(data: value) {
                    delegate?.didReceiveTrackpadData(trackpadData)
                } else {
                    print("Failed to parse trackpad data")
                }
            } else if request.characteristic.uuid == appSwitchCharacteristicUUID, let value = request.value {
                print("Received app switch request. Size: \(value.count) bytes")
                if let bundleIdentifier = String(data: value, encoding: .utf8) {
                    delegate?.didReceiveAppSwitchRequest(bundleIdentifier: bundleIdentifier)
                } else {
                    print("Failed to parse app switch request")
                }
            } else if request.characteristic.uuid == appListRequestCharacteristicUUID {
                print("Received app list request")
                delegate?.didReceiveAppListRequest()
            } else if request.characteristic.uuid == chunkAckCharacteristicUUID, let value = request.value {
                handleChunkAcknowledgment(value)
            }
            
            // Respond to the request if it's a write with response
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
    
    private func handleChunkAcknowledgment(_ data: Data) {
        guard data.count == 2 else {
            print("Invalid chunk acknowledgment data")
            return
        }
        let appIndex = Int(data[0])
        let chunkIndex = Int(data[1])
        print("Received chunk acknowledgment for app \(appIndex), chunk \(chunkIndex)")
        delegate?.didReceiveChunkAcknowledgment(appIndex: appIndex, chunkIndex: chunkIndex)
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        print("Peripheral manager is ready to update subscribers")
        sendQueuedUpdates()
    }
}

protocol BluetoothServiceDelegate: AnyObject {
    func didReceiveTrackpadData(_ data: TrackpadData)
    func didUpdateConnectionState(isConnected: Bool)
    func didReceiveAppSwitchRequest(bundleIdentifier: String)
    func didReceiveAppListRequest()
    func didReceiveChunkAcknowledgment(appIndex: Int, chunkIndex: Int)
    func didReceiveText(_ data: Data)
}

struct TrackpadData {
    let deltaX: Int8
    let deltaY: Int8
    let gestureType: GestureType
}

enum GestureType: Int8 {
    case move = 0
    case leftClick = 1
    case rightClick = 2
    case scroll = 3
    case switchSpaceLeft = 4
    case switchSpaceRight = 5
}

protocol TrackpadDataParser {
    func parse(data: Data) -> TrackpadData?
}

class StandardTrackpadDataParser: TrackpadDataParser {
    func parse(data: Data) -> TrackpadData? {
        guard data.count == 3 else { return nil }
        
        let deltaX = Int8(bitPattern: data[0])
        let deltaY = Int8(bitPattern: data[1])
        let gestureTypeRawValue = data[2]
        
        guard let gestureType = GestureType(rawValue: Int8(gestureTypeRawValue)) else { return nil }
        
        return TrackpadData(deltaX: deltaX, deltaY: deltaY, gestureType: gestureType)
    }
}

class TextReceiver {
    func insertText(_ text: String) {
        print("Inserting text. Length: \(text.count) characters")
        
        // Get the current application
        guard let application = NSWorkspace.shared.frontmostApplication else {
            print("No frontmost application found")
            return
        }
        
        // Ensure the application is active
        application.activate()
        
        // Small delay to ensure the application is active
        Thread.sleep(forTimeInterval: 0.1)
        
        // Create a pasteboard instance
        let pasteboard = NSPasteboard.general
        
        // Clear the pasteboard and set the text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Simulate Command+V to paste the text
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        
        vKeyDown?.flags = .maskCommand
        vKeyUp?.flags = .maskCommand
        
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
        
        print("Text insertion completed")
    }
}
