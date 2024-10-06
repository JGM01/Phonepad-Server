import CoreBluetooth
import Cocoa

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
    
    init(trackpad: MacOSTrackpad, dataParser: TrackpadDataParser) {
        print("Initializing BLEPeripheral")
        self.trackpad = trackpad
        self.bluetoothService = BluetoothService(dataParser: dataParser)
        self.appTracker = AppTracker()
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
}

extension BLEPeripheral: BluetoothServiceDelegate {
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
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            app.activate(options: .activateIgnoringOtherApps)
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
    
    private let serviceUUID = CBUUID(string: "5FFB1810-2672-4FFE-B9B8-54122F7E4F99")
    private let characteristicUUID = CBUUID(string: "34722DA8-9E9A-44A3-BB59-9E8E3A41728E")
    private let appUpdateCharacteristicUUID = CBUUID(string: "481B51DC-5649-4F0F-B1EE-EC527E0B985B")
    private let appSwitchCharacteristicUUID = CBUUID(string: "D62D00F3-02ED-4005-B427-86B5E4881601")
    private let appListRequestCharacteristicUUID = CBUUID(string: "65E43765-0C73-4F52-85D3-C49D068AA5BF")
    private let chunkAckCharacteristicUUID = CBUUID(string: "C54DCF47-7708-40E9-90F9-013723282D14")
    
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
        
        transferService?.characteristics = [
            transferCharacteristic!,
            appUpdateCharacteristic!,
            appSwitchCharacteristic!,
            appListRequestCharacteristic!,
            chunkAckCharacteristic!
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
            if request.characteristic.uuid == characteristicUUID, let value = request.value {
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
