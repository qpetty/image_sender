//
//  SRTStreamManager.swift
//  Image_sender
//
//  Manages SRT camera streaming using HaishinKit 2.x (SRTHaishinKit module)
//

import Foundation
import Combine
import AVFoundation
import UIKit
import HaishinKit
import SRTHaishinKit

/// Connection status for SRT
enum SRTConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case publishing
    case error(String)
    
    static func == (lhs: SRTConnectionStatus, rhs: SRTConnectionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.publishing, .publishing):
            return true
        case (.error(let lhsMsg), .error(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Manages SRT connection and camera streaming using HaishinKit 2.x
@MainActor
class SRTStreamManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectionStatus: SRTConnectionStatus = .disconnected
    @Published var statusMessage = "SRT Ready"
    @Published var isStreaming = false
    @Published var isConnected = false
    
    // MARK: - Server Configuration (Published for UI binding)
    @Published var serverHost: String {
        didSet {
            UserDefaults.standard.set(serverHost, forKey: "srt_server_host")
        }
    }
    @Published var serverPort: String {
        didSet {
            UserDefaults.standard.set(serverPort, forKey: "srt_server_port")
        }
    }
    @Published var streamId: String {
        didSet {
            UserDefaults.standard.set(streamId, forKey: "srt_stream_id")
        }
    }
    @Published var latency: Int {
        didSet {
            UserDefaults.standard.set(latency, forKey: "srt_latency")
        }
    }
    @Published var passphrase: String {
        didSet {
            UserDefaults.standard.set(passphrase, forKey: "srt_passphrase")
        }
    }
    
    // MARK: - HaishinKit 2.x Components
    private var mixer: MediaMixer?
    private var connection: SRTConnection?
    private var stream: SRTStream?
    
    // MARK: - Preview View
    private var previewView: MTHKView?
    
    // MARK: - Orientation Observer
    private var orientationObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    override init() {
        // Load saved settings or use defaults
        self.serverHost = UserDefaults.standard.string(forKey: "srt_server_host") ?? "192.168.1.100"
        self.serverPort = UserDefaults.standard.string(forKey: "srt_server_port") ?? "9000"
        self.streamId = UserDefaults.standard.string(forKey: "srt_stream_id") ?? ""
        var savedLatency = UserDefaults.standard.integer(forKey: "srt_latency")
        if savedLatency == 0 { savedLatency = 120 } // 120ms default latency
        self.latency = savedLatency
        self.passphrase = UserDefaults.standard.string(forKey: "srt_passphrase") ?? ""
        
        super.init()
        
        setupAudioSession()
    }
    
    // MARK: - Audio Session Setup
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            print("[SRT] Audio session error: \(error)")
        }
    }
    
    // MARK: - Screen Lock Prevention
    private func preventScreenLock(_ prevent: Bool) {
        UIApplication.shared.isIdleTimerDisabled = prevent
        print("[SRT] Screen lock prevention: \(prevent ? "enabled" : "disabled")")
    }
    
    // MARK: - Orientation Handling
    private func startOrientationObserver() {
        // Enable device orientation notifications
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        // Set initial orientation
        updateVideoOrientation()
        
        // Listen for orientation changes
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateVideoOrientation()
            }
        }
        print("[SRT] Orientation observer started")
    }
    
    private func stopOrientationObserver() {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        print("[SRT] Orientation observer stopped")
    }
    
    private func updateVideoOrientation() {
        guard let mixer = mixer else { return }
        
        let deviceOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        
        switch deviceOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            // Device landscape left = video landscape right (camera is on opposite side)
            videoOrientation = .landscapeRight
        case .landscapeRight:
            // Device landscape right = video landscape left
            videoOrientation = .landscapeLeft
        default:
            // For face up/down or unknown, keep current orientation
            return
        }
        
        // Update orientation asynchronously since MediaMixer is an actor
        let orientation = videoOrientation
        let device = deviceOrientation
        Task {
            await mixer.setVideoOrientation(orientation)
            print("[SRT] Video orientation updated to: \(orientation.rawValue) (device: \(device.rawValue))")
        }
    }
    
    // MARK: - SRT URL Builder
    private func buildSRTURL() -> String {
        // Format: srt://host:port?mode=caller&transtype=live&streamid=<id>&passphrase=<pass>
        // The mode=caller tells HaishinKit we're connecting TO a server (GStreamer srtsrc in listener mode)
        var urlString = "srt://\(serverHost):\(serverPort)"
        
        // Build query parameters
        var params: [String] = []
        
        // Mode: caller means we initiate connection to a listener server
        params.append("mode=caller")
        
        // Add stream ID if provided (commonly used for routing/authentication)
        if !streamId.isEmpty {
            if let encodedStreamId = streamId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                params.append("streamid=\(encodedStreamId)")
            }
        }
        
        // Add passphrase if provided (for SRT encryption)
        if !passphrase.isEmpty {
            if let encodedPassphrase = passphrase.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                params.append("passphrase=\(encodedPassphrase)")
            }
        }
        
        // Append query string
        if !params.isEmpty {
            urlString += "?" + params.joined(separator: "&")
        }
        
        return urlString
    }
    
    // MARK: - Connection Management
    func startStreaming() {
        guard !isStreaming else {
            print("[SRT] Already streaming")
            return
        }
        
        statusMessage = "Initializing..."
        isStreaming = true
        connectionStatus = .connecting
        
        Task {
            await startStreamingAsync()
        }
    }
    
    private func startStreamingAsync() async {
        print("[SRT] === Starting SRT Stream ===")
        
        // STEP 0: Check and request camera/audio permissions
        print("[SRT] Checking camera permission...")
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("[SRT] Camera authorization status: \(cameraStatus.rawValue)")
        
        if cameraStatus == .notDetermined {
            print("[SRT] Requesting camera permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                print("[SRT] ✗ Camera permission denied")
                await MainActor.run {
                    statusMessage = "Camera permission denied"
                    connectionStatus = .error("No camera access")
                    isStreaming = false
                }
                return
            }
            print("[SRT] ✓ Camera permission granted")
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            print("[SRT] ✗ Camera permission denied/restricted")
            await MainActor.run {
                statusMessage = "Camera permission denied"
                connectionStatus = .error("No camera access")
                isStreaming = false
            }
            return
        }
        
        // Check audio permission
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[SRT] Audio authorization status: \(audioStatus.rawValue)")
        if audioStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        
        // List available cameras
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        print("[SRT] Available cameras: \(cameras.map { "\($0.localizedName) (\($0.position.rawValue))" })")
        
        guard let camera = cameras.first(where: { $0.position == .back }) ?? cameras.first else {
            print("[SRT] ✗ No camera found!")
            await MainActor.run {
                statusMessage = "No camera found"
                connectionStatus = .error("No camera")
                isStreaming = false
            }
            return
        }
        print("[SRT] Using camera: \(camera.localizedName)")
        
        // Create components
        print("[SRT] Creating MediaMixer...")
        mixer = MediaMixer()
        guard let mixer = mixer else {
            await MainActor.run {
                statusMessage = "Failed to create mixer"
                connectionStatus = .error("Mixer error")
                isStreaming = false
            }
            return
        }
        
        print("[SRT] Creating SRTConnection...")
        connection = SRTConnection()
        guard let connection = connection else {
            await MainActor.run {
                statusMessage = "Failed to create connection"
                connectionStatus = .error("Init error")
                isStreaming = false
            }
            return
        }
        
        print("[SRT] Creating SRTStream...")
        stream = SRTStream(connection: connection)
        guard let stream = stream else {
            await MainActor.run {
                statusMessage = "Failed to create stream"
                connectionStatus = .error("Init error")
                isStreaming = false
            }
            return
        }
        
        // Attach camera to mixer FIRST
        print("[SRT] Attaching camera to mixer...")
        do {
            try await mixer.attachVideo(camera)
            print("[SRT] ✓ Camera attached successfully")
        } catch {
            print("[SRT] ✗ Camera attach FAILED: \(error)")
            await MainActor.run {
                statusMessage = "Camera error: \(error.localizedDescription)"
                connectionStatus = .error("Camera error")
                isStreaming = false
            }
            return
        }
        
        // Attach audio
        print("[SRT] Attaching audio to mixer...")
        if let mic = AVCaptureDevice.default(for: .audio) {
            do {
                try await mixer.attachAudio(mic)
                print("[SRT] ✓ Audio attached: \(mic.localizedName)")
            } catch {
                print("[SRT] ⚠ Audio attach failed (continuing): \(error)")
            }
        }
        
        // Add stream as output from mixer
        print("[SRT] Adding stream as mixer output...")
        await mixer.addOutput(stream)
        print("[SRT] ✓ Stream connected to mixer")
        
        // Attach preview view to MIXER (not stream) - this shows raw capture output
        if let view = previewView {
            print("[SRT] Attaching preview view to mixer...")
            await mixer.addOutput(view)
            print("[SRT] ✓ Preview attached to mixer (should show camera feed)")
        } else {
            print("[SRT] ⚠ No preview view available")
        }
        
        // START THE MIXER - this is required to begin capture!
        print("[SRT] Starting mixer (capture session)...")
        await mixer.startRunning()
        print("[SRT] ✓ Mixer started - isRunning: \(await mixer.isRunning)")
        
        // Set initial video orientation based on current device orientation
        print("[SRT] Setting initial video orientation...")
        await MainActor.run {
            startOrientationObserver()
        }
        
        // Wait a moment for capture to start producing frames
        print("[SRT] Waiting for capture pipeline to produce frames...")
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Build SRT URL
        let srtURL = buildSRTURL()
        print("[SRT] Connecting to server: \(srtURL)")
        await MainActor.run {
            statusMessage = "Connecting..."
        }
        
        do {
            guard let url = URL(string: srtURL) else {
                print("[SRT] ✗ Invalid URL: \(srtURL)")
                throw SRTConnection.Error.unsupportedUri(nil)
            }
            print("[SRT] Parsed URL successfully, attempting connection...")
            print("[SRT] SRT Library version: \(SRTConnection.version)")
            try await connection.connect(url)
            print("[SRT] ✓ Connected to server")
            await MainActor.run {
                isConnected = true
                connectionStatus = .connected
            }
        } catch let error as SRTConnection.Error {
            print("[SRT] ✗ SRT Connection error: \(error)")
            // Cleanup on failure
            await cleanupAfterFailure()
            await MainActor.run {
                isConnected = false
                switch error {
                case .invalidState:
                    connectionStatus = .error("Invalid state - check SRT server")
                    statusMessage = "Connection failed: Invalid state"
                case .unsupportedUri(let uri):
                    connectionStatus = .error("Invalid URI")
                    statusMessage = "Invalid URI: \(uri?.absoluteString ?? "nil")"
                case .failedToConnect(let reason):
                    connectionStatus = .error("Rejected: \(reason)")
                    statusMessage = "Connection rejected: \(reason)"
                }
                isStreaming = false
            }
            return
        } catch {
            print("[SRT] ✗ Unexpected connection error: \(error)")
            // Cleanup on failure
            await cleanupAfterFailure()
            await MainActor.run {
                isConnected = false
                connectionStatus = .error("Connection failed")
                statusMessage = "Error: \(error.localizedDescription)"
                isStreaming = false
            }
            return
        }
        
        // Publish
        print("[SRT] Publishing stream...")
        await MainActor.run {
            statusMessage = "Publishing..."
        }
        
        do {
            // Set expected media types before publishing
            await stream.setExpectedMedias([.video, .audio])
            
            await stream.publish("")
            print("[SRT] ✓ Publish started!")
            await MainActor.run {
                connectionStatus = .publishing
                statusMessage = "Streaming"
                
                // Prevent screen from locking during stream
                preventScreenLock(true)
            }
            print("[SRT] === Stream is LIVE ===")
        } catch {
            print("[SRT] ✗ Publish error: \(error)")
            await MainActor.run {
                connectionStatus = .error("Publish failed")
                statusMessage = "Publish failed"
                isStreaming = false
            }
        }
    }
    
    /// Cleanup resources after a connection failure (called from async context)
    private func cleanupAfterFailure() async {
        print("[SRT] Cleaning up after connection failure...")
        
        // Stop orientation observer on main thread
        await MainActor.run {
            stopOrientationObserver()
        }
        
        // Close stream if exists
        if let stream = stream {
            await stream.close()
        }
        
        // Close connection if exists
        if let connection = connection {
            await connection.close()
        }
        
        // Stop mixer
        if let mixer = mixer {
            await mixer.stopRunning()
            if let stream = stream {
                await mixer.removeOutput(stream)
            }
            if let view = previewView {
                await mixer.removeOutput(view)
            }
        }
        
        // Clear references
        stream = nil
        connection = nil
        mixer = nil
        
        print("[SRT] Cleanup complete")
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        print("[SRT] Stopping stream")
        
        // Re-enable screen lock
        preventScreenLock(false)
        
        // Stop orientation observer
        stopOrientationObserver()
        
        Task {
            // Close stream
            if let stream = stream {
                await stream.close()
            }
            
            // Close connection
            if let connection = connection {
                await connection.close()
            }
            
            // Stop and cleanup mixer
            if let mixer = mixer {
                print("[SRT] Stopping mixer...")
                await mixer.stopRunning()
                if let stream = stream {
                    await mixer.removeOutput(stream)
                }
                if let view = previewView {
                    await mixer.removeOutput(view)
                }
            }
            
            // Clear references
            stream = nil
            connection = nil
            mixer = nil
            
            await MainActor.run {
                isStreaming = false
                isConnected = false
                connectionStatus = .disconnected
                statusMessage = "Stopped"
            }
            print("[SRT] Stream stopped and cleaned up")
        }
    }
    
    // MARK: - Preview Management
    func setPreviewView(_ view: MTHKView) {
        previewView = view
        
        // If stream is active, attach view
        if let mixer = mixer {
            Task {
                await mixer.addOutput(view)
            }
        }
    }
    
    func removePreviewView(_ view: MTHKView) {
        if previewView === view {
            if let mixer = mixer {
                Task {
                    await mixer.removeOutput(view)
                }
            }
            previewView = nil
        }
    }
}

