//
//  RTMPStreamManager.swift
//  Image_sender
//
//  Manages RTMP camera streaming using HaishinKit 2.x
//

import Foundation
import Combine
import AVFoundation
import UIKit
import HaishinKit
import RTMPHaishinKit

/// Connection status for RTMP
enum RTMPConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case publishing
    case error(String)
    
    static func == (lhs: RTMPConnectionStatus, rhs: RTMPConnectionStatus) -> Bool {
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

/// Manages RTMP connection and camera streaming using HaishinKit 2.x
@MainActor
class RTMPStreamManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectionStatus: RTMPConnectionStatus = .disconnected
    @Published var statusMessage = "RTMP Ready"
    @Published var isStreaming = false
    @Published var isConnected = false
    
    // MARK: - Server Configuration (Published for UI binding)
    @Published var rtmpURL: String {
        didSet {
            UserDefaults.standard.set(rtmpURL, forKey: "rtmp_url")
        }
    }
    @Published var streamKey: String {
        didSet {
            UserDefaults.standard.set(streamKey, forKey: "rtmp_stream_key")
        }
    }
    
    // Video settings
    @Published var videoBitrate: Int {
        didSet {
            UserDefaults.standard.set(videoBitrate, forKey: "rtmp_video_bitrate")
        }
    }
    @Published var audioBitrate: Int {
        didSet {
            UserDefaults.standard.set(audioBitrate, forKey: "rtmp_audio_bitrate")
        }
    }
    
    // MARK: - HaishinKit 2.x Components
    private var mixer: MediaMixer?
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    
    // MARK: - Preview View
    private var previewView: MTHKView?
    
    // MARK: - Orientation Observer
    private var orientationObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    override init() {
        // Load saved settings or use defaults
        let savedRtmpURL = UserDefaults.standard.string(forKey: "rtmp_url") ?? "rtmp://localhost:1935/live"
        let savedStreamKey = UserDefaults.standard.string(forKey: "rtmp_stream_key") ?? "stream"
        var savedVideoBitrate = UserDefaults.standard.integer(forKey: "rtmp_video_bitrate")
        if savedVideoBitrate == 0 { savedVideoBitrate = 4000 } // 4 Mbps default
        var savedAudioBitrate = UserDefaults.standard.integer(forKey: "rtmp_audio_bitrate")
        if savedAudioBitrate == 0 { savedAudioBitrate = 128 } // 128 kbps default
        
        self.rtmpURL = savedRtmpURL
        self.streamKey = savedStreamKey
        self.videoBitrate = savedVideoBitrate
        self.audioBitrate = savedAudioBitrate
        
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
            print("[RTMP] Audio session error: \(error)")
        }
    }
    
    // MARK: - Screen Lock Prevention
    private func preventScreenLock(_ prevent: Bool) {
        UIApplication.shared.isIdleTimerDisabled = prevent
        print("[RTMP] Screen lock prevention: \(prevent ? "enabled" : "disabled")")
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
        print("[RTMP] Orientation observer started")
    }
    
    private func stopOrientationObserver() {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        print("[RTMP] Orientation observer stopped")
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
            print("[RTMP] Video orientation updated to: \(orientation.rawValue) (device: \(device.rawValue))")
        }
    }
    
    
    // MARK: - Connection Management
    func startStreaming() {
        guard !isStreaming else {
            print("[RTMP] Already streaming")
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
        print("[RTMP] === Starting RTMP Stream ===")
        
        // STEP 0: Check and request camera/audio permissions
        print("[RTMP] Checking camera permission...")
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("[RTMP] Camera authorization status: \(cameraStatus.rawValue)")
        
        if cameraStatus == .notDetermined {
            print("[RTMP] Requesting camera permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                print("[RTMP] ✗ Camera permission denied")
                await MainActor.run {
                    statusMessage = "Camera permission denied"
                    connectionStatus = .error("No camera access")
                    isStreaming = false
                }
                return
            }
            print("[RTMP] ✓ Camera permission granted")
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            print("[RTMP] ✗ Camera permission denied/restricted")
            await MainActor.run {
                statusMessage = "Camera permission denied"
                connectionStatus = .error("No camera access")
                isStreaming = false
            }
            return
        }
        
        // Check audio permission
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[RTMP] Audio authorization status: \(audioStatus.rawValue)")
        if audioStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        
        // List available cameras
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        print("[RTMP] Available cameras: \(cameras.map { "\($0.localizedName) (\($0.position.rawValue))" })")
        
        guard let camera = cameras.first(where: { $0.position == .back }) ?? cameras.first else {
            print("[RTMP] ✗ No camera found!")
            await MainActor.run {
                statusMessage = "No camera found"
                connectionStatus = .error("No camera")
                isStreaming = false
            }
            return
        }
        print("[RTMP] Using camera: \(camera.localizedName)")
        
        // Create components
        print("[RTMP] Creating MediaMixer...")
        mixer = MediaMixer()
        guard let mixer = mixer else {
            await MainActor.run {
                statusMessage = "Failed to create mixer"
                connectionStatus = .error("Mixer error")
                isStreaming = false
            }
            return
        }
        
        print("[RTMP] Creating RTMPConnection...")
        connection = RTMPConnection(
            fourCcList: nil,
            videoFourCcInfoMap: nil,
            audioFourCcInfoMap: nil,
            capsEx: 0
        )
        guard let connection = connection else {
            await MainActor.run {
                statusMessage = "Failed to create connection"
                connectionStatus = .error("Init error")
                isStreaming = false
            }
            return
        }
        
        print("[RTMP] Creating RTMPStream...")
        stream = RTMPStream(connection: connection)
        guard let stream = stream else {
            await MainActor.run {
                statusMessage = "Failed to create stream"
                connectionStatus = .error("Init error")
                isStreaming = false
            }
            return
        }
        
        // Attach camera to mixer FIRST
        print("[RTMP] Attaching camera to mixer...")
        do {
            try await mixer.attachVideo(camera)
            print("[RTMP] ✓ Camera attached successfully")
        } catch {
            print("[RTMP] ✗ Camera attach FAILED: \(error)")
            await MainActor.run {
                statusMessage = "Camera error: \(error.localizedDescription)"
                connectionStatus = .error("Camera error")
                isStreaming = false
            }
            return
        }
        
        // Attach audio
        print("[RTMP] Attaching audio to mixer...")
        if let mic = AVCaptureDevice.default(for: .audio) {
            do {
                try await mixer.attachAudio(mic)
                print("[RTMP] ✓ Audio attached: \(mic.localizedName)")
            } catch {
                print("[RTMP] ⚠ Audio attach failed (continuing): \(error)")
            }
        }
        
        // Add stream as output from mixer
        print("[RTMP] Adding stream as mixer output...")
        await mixer.addOutput(stream)
        print("[RTMP] ✓ Stream connected to mixer")
        
        // Attach preview view to MIXER (not stream) - this shows raw capture output
        if let view = previewView {
            print("[RTMP] Attaching preview view to mixer...")
            await mixer.addOutput(view)
            print("[RTMP] ✓ Preview attached to mixer (should show camera feed)")
        } else {
            print("[RTMP] ⚠ No preview view available")
        }
        
        // START THE MIXER - this is required to begin capture!
        print("[RTMP] Starting mixer (capture session)...")
        await mixer.startRunning()
        print("[RTMP] ✓ Mixer started - isRunning: \(await mixer.isRunning)")
        
        // Wait a moment for capture to start producing frames
        print("[RTMP] Waiting for capture pipeline to produce frames...")
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Connect to server
        print("[RTMP] Connecting to server: \(rtmpURL)")
        await MainActor.run {
            statusMessage = "Connecting..."
        }
        
        do {
            _ = try await connection.connect(rtmpURL)
            print("[RTMP] ✓ Connected to server")
            await MainActor.run {
                isConnected = true
                connectionStatus = .connected
            }
        } catch {
            print("[RTMP] ✗ Connection error: \(error)")
            await MainActor.run {
                isConnected = false
                connectionStatus = .error("Connection failed")
                statusMessage = "Connection failed"
                isStreaming = false
            }
            return
        }
        
        // Publish
        print("[RTMP] Publishing with stream key: \(streamKey)")
        await MainActor.run {
            statusMessage = "Publishing..."
        }
        
        do {
            _ = try await stream.publish(streamKey)
            print("[RTMP] ✓ Publish started!")
            await MainActor.run {
                connectionStatus = .publishing
                statusMessage = "Streaming"
                
                // Prevent screen from locking during stream
                preventScreenLock(true)
                
                // Start listening for orientation changes
                startOrientationObserver()
            }
            print("[RTMP] === Stream is LIVE ===")
        } catch {
            print("[RTMP] ✗ Publish error: \(error)")
            await MainActor.run {
                connectionStatus = .error("Publish failed")
                statusMessage = "Publish failed"
                isStreaming = false
            }
        }
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        print("[RTMP] Stopping stream")
        
        // Re-enable screen lock
        preventScreenLock(false)
        
        // Stop orientation observer
        stopOrientationObserver()
        
        Task {
            // Close stream
            if let stream = stream {
                _ = try? await stream.close()
            }
            
            // Close connection
            if let connection = connection {
                try? await connection.close()
            }
            
            // Stop and cleanup mixer
            if let mixer = mixer {
                print("[RTMP] Stopping mixer...")
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
            print("[RTMP] Stream stopped and cleaned up")
        }
    }
    
    // MARK: - Preview Management
    func setPreviewView(_ view: MTHKView) {
        previewView = view
        
        // If stream is active, attach view
        if let stream = stream {
            Task {
                await stream.addOutput(view)
            }
        }
    }
    
    func removePreviewView(_ view: MTHKView) {
        if previewView === view {
            if let stream = stream {
                Task {
                    await stream.removeOutput(view)
                }
            }
            previewView = nil
        }
    }
}
