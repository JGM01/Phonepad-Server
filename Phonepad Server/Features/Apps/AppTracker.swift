import Cocoa

class AppTracker: NSObject {
    private var runningApps: [NSRunningApplication] = []
    private let workspace = NSWorkspace.shared
    weak var blePeripheral: BLEPeripheral?
    
    private var currentAppIndex = 0
    private var currentChunkIndex = 0
    private var chunksToSend: [AppChunk] = []
    
    override init() {
        super.init()
        updateRunningApps()
        setupNotifications()
    }
    
    private func setupNotifications() {
        let notificationCenter = workspace.notificationCenter
        notificationCenter.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }
    
    private func updateRunningApps() {
        runningApps = workspace.runningApplications.filter { $0.activationPolicy == .regular }
        printRunningApps()
    }
    
    private func printRunningApps() {
        print("Currently running apps:")
        for app in runningApps {
            print("- \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "Unknown"))")
        }
        print("Total: \(runningApps.count) apps")
    }
    
    func sendFullAppList() {
        print("Preparing to send full app list")
        currentAppIndex = 0
        currentChunkIndex = 0
        chunksToSend.removeAll()
        sendNextApp()
    }
    
    private func sendNextApp() {
        guard currentAppIndex < runningApps.count else {
            print("Finished sending all apps")
            return
        }
        
        let app = runningApps[currentAppIndex]
        let appData = prepareAppData(app)
        let chunks = chunkAppData(appData)
        chunksToSend.append(contentsOf: chunks)
        sendNextChunk()
    }
    
    private func prepareAppData(_ app: NSRunningApplication) -> Data {
        var appData = Data()
        appData.append(0) // Not removed
        if let bundleIdentifier = app.bundleIdentifier {
            appData.append(bundleIdentifier.data(using: .utf8)!)
        }
        appData.append(0) // Null terminator
        if let localizedName = app.localizedName {
            appData.append(localizedName.data(using: .utf8)!)
        }
        appData.append(0) // Null terminator
        
        if let icon = app.icon {
            let optimizedIcon = icon.resized(to: NSSize(width: 64, height: 64))
            if let tiffData = optimizedIcon.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                appData.append(pngData)
            }
        }
        
        return appData
    }
    
    private func chunkAppData(_ appData: Data) -> [AppChunk] {
        let chunkSize = 512
        let totalChunks = Int(ceil(Double(appData.count) / Double(chunkSize)))
        return (0..<totalChunks).map { i in
            let start = i * chunkSize
            let end = min(start + chunkSize, appData.count)
            let chunkData = appData[start..<end]
            return AppChunk(appIndex: currentAppIndex, chunkIndex: i, totalChunks: totalChunks, data: chunkData)
        }
    }
    
    private func sendNextChunk() {
        guard let chunk = chunksToSend.first else {
            currentAppIndex += 1
            currentChunkIndex = 0
            sendNextApp()
            return
        }
        
        let chunkData = encodeChunk(chunk)
        blePeripheral?.sendAppUpdate(chunkData)
    }
    
    private func encodeChunk(_ chunk: AppChunk) -> Data {
        var data = Data()
        data.append(UInt8(chunk.appIndex))
        data.append(UInt8(chunk.chunkIndex))
        data.append(UInt8(chunk.totalChunks))
        data.append(chunk.data)
        return data
    }
    
    func handleChunkAcknowledgment(appIndex: Int, chunkIndex: Int) {
        if appIndex == currentAppIndex && chunkIndex == currentChunkIndex {
            chunksToSend.removeFirst()
            currentChunkIndex += 1
            sendNextChunk()
        }
    }
    
    @objc private func appLaunched(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            print("App launched: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "Unknown"))")
            updateRunningApps()
            sendAppUpdate(app, isRemoved: false)
        }
    }
    
    @objc private func appTerminated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            print("App terminated: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "Unknown"))")
            updateRunningApps()
            sendAppUpdate(app, isRemoved: true)
        }
    }
    
    private func sendAppUpdate(_ app: NSRunningApplication, isRemoved: Bool) {
        var appData = Data()
        appData.append(isRemoved ? 1 : 0)
        if let bundleIdentifier = app.bundleIdentifier {
            appData.append(bundleIdentifier.data(using: .utf8)!)
        }
        appData.append(0) // Null terminator
        if let localizedName = app.localizedName {
            appData.append(localizedName.data(using: .utf8)!)
        }
        appData.append(0) // Null terminator
        
        if !isRemoved, let icon = app.icon {
            let optimizedIcon = icon.resized(to: NSSize(width: 64, height: 64))
            if let tiffData = optimizedIcon.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                appData.append(pngData)
            }
        }
        
        let chunks = chunkAppData(appData)
        for chunk in chunks {
            let chunkData = encodeChunk(chunk)
            blePeripheral?.sendAppUpdate(chunkData)
        }
    }
}

struct AppChunk {
    let appIndex: Int
    let chunkIndex: Int
    let totalChunks: Int
    let data: Data
}

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: size),
                  operation: .copy,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
