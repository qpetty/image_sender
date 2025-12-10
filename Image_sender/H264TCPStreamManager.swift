//
//  H264TCPStreamManager.swift
//  Image_sender
//
//  Manages H.264 video streaming over TCP using a GStreamer pipeline
//  (appsrc -> h264parse -> mpegtsmux -> tcpclientsink)
//

import Foundation
import Combine
import AVFoundation
import VideoToolbox
import UIKit

/// Connection status for H264 TCP streaming
enum H264TCPConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case error(String)
    
    static func == (lhs: H264TCPConnectionStatus, rhs: H264TCPConnectionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.streaming, .streaming):
            return true
        case (.error(let lhsMsg), .error(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Manages H.264 streaming over TCP via a GStreamer pipeline
/// Pipeline: appsrc(h264) ! h264parse ! mpegtsmux ! tcpclientsink
class H264TCPStreamManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectionStatus: H264TCPConnectionStatus = .disconnected
    @Published var statusMessage = "MJPEG Ready"
    @Published var isStreaming = false
    @Published var isConnected = false
    @Published var framesSent: Int = 0
    @Published var bytesSent: Int64 = 0
    
    // MARK: - Video Encoding (H.264)
    private var compressionSession: VTCompressionSession?
    private var isPipelineRunning = false
    
    // MARK: - Server Configuration (Published for UI binding)
    @Published var serverHost: String {
        didSet {
            UserDefaults.standard.set(serverHost, forKey: "h264tcp_server_host")
        }
    }
    @Published var serverPort: String {
        didSet {
            UserDefaults.standard.set(serverPort, forKey: "h264tcp_server_port")
        }
    }
    @Published var videoBitrate: Int {
        didSet {
            UserDefaults.standard.set(videoBitrate, forKey: "h264tcp_video_bitrate")
        }
    }
    @Published var keyframeInterval: Int {
        didSet {
            UserDefaults.standard.set(keyframeInterval, forKey: "h264tcp_keyframe_interval")
        }
    }
    
    // MARK: - AVFoundation Components
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let captureQueue = DispatchQueue(label: "com.imagesender.h264tcp.capture", qos: .userInteractive)
    
    // MARK: - Orientation Observer
    private var orientationObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    override init() {
        // Load saved settings or use defaults
        self.serverHost = UserDefaults.standard.string(forKey: "h264tcp_server_host") ?? "192.168.1.100"
        self.serverPort = UserDefaults.standard.string(forKey: "h264tcp_server_port") ?? "5000"
        var savedBitrate = UserDefaults.standard.integer(forKey: "h264tcp_video_bitrate")
        if savedBitrate == 0 { savedBitrate = 4000 } // 4 Mbps default
        self.videoBitrate = savedBitrate
        var savedKeyframeInterval = UserDefaults.standard.integer(forKey: "h264tcp_keyframe_interval")
        if savedKeyframeInterval == 0 { savedKeyframeInterval = 30 } // 1 second at 30fps
        self.keyframeInterval = savedKeyframeInterval
        
        super.init()
    }
    
    deinit {
        // Cleanup is done in stopStreaming
    }
    
    // MARK: - Screen Lock Prevention
    private func preventScreenLock(_ prevent: Bool) {
        UIApplication.shared.isIdleTimerDisabled = prevent
        print("[H264TCP] Screen lock prevention: \(prevent ? "enabled" : "disabled")")
    }
    
    // MARK: - Orientation Handling
    private func startOrientationObserver() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        updateVideoOrientation()
        
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateVideoOrientation()
            }
        }
        print("[H264TCP] Orientation observer started")
    }
    
    private func stopOrientationObserver() {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        print("[H264TCP] Orientation observer stopped")
    }
    
    private func updateVideoOrientation() {
        guard let connection = videoOutput?.connection(with: .video) else { return }
        
        let deviceOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        
        switch deviceOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            videoOrientation = .landscapeRight
        case .landscapeRight:
            videoOrientation = .landscapeLeft
        default:
            return
        }
        
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        
        // Update preview layer orientation
        if let previewConnection = previewLayer?.connection {
            if previewConnection.isVideoOrientationSupported {
                previewConnection.videoOrientation = videoOrientation
            }
        }
        
        print("[H264TCP] Video orientation updated to: \(videoOrientation.rawValue)")
    }
    
    // MARK: - Camera Setup
    private func setupCamera() -> Bool {
        print("[H264TCP] Setting up camera...")
        
        captureSession = AVCaptureSession()
        guard let session = captureSession else {
            print("[H264TCP] Failed to create capture session")
            return false
        }
        
        session.beginConfiguration()
        
        // Set session preset for high quality
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            print("[H264TCP] Using 1080p preset")
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
            print("[H264TCP] Using 720p preset")
        } else {
            session.sessionPreset = .high
            print("[H264TCP] Using high preset")
        }
        
        // Get back camera
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("[H264TCP] No back camera found")
            session.commitConfiguration()
            return false
        }
        
        // Configure camera for optimal streaming
        do {
            try camera.lockForConfiguration()
            
            // Set frame rate to 30fps
            let targetFrameRate = CMTime(value: 1, timescale: 30)
            camera.activeVideoMinFrameDuration = targetFrameRate
            camera.activeVideoMaxFrameDuration = targetFrameRate
            
            camera.unlockForConfiguration()
        } catch {
            print("[H264TCP] Camera configuration error: \(error)")
        }
        
        // Add camera input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                print("[H264TCP] Camera input added")
            } else {
                print("[H264TCP] Cannot add camera input")
                session.commitConfiguration()
                return false
            }
        } catch {
            print("[H264TCP] Error creating camera input: \(error)")
            session.commitConfiguration()
            return false
        }
        
        // Add video output
        videoOutput = AVCaptureVideoDataOutput()
        guard let output = videoOutput else {
            print("[H264TCP] Failed to create video output")
            session.commitConfiguration()
            return false
        }
        
        // Use 420v (YUV 4:2:0) for best encoder compatibility
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            print("[H264TCP] Video output added")
        } else {
            print("[H264TCP] Cannot add video output")
            session.commitConfiguration()
            return false
        }
        
        session.commitConfiguration()
        
        print("[H264TCP] Camera setup complete")
        return true
    }
    
    // MARK: - Frame Encoding and Sending (H.264 in MPEG-TS with PTS)
    private func encodeAndSendFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard isPipelineRunning else { return }
        
        // Lazily create the compression session matching the capture buffer size
        setupCompressionSessionIfNeeded(width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                                        height: Int32(CVPixelBufferGetHeight(pixelBuffer)))
        
        guard let session = compressionSession else { return }
        
        if framesSent < 5 {
            let nowHost = CMClockGetTime(CMClockGetHostTimeClock())
            let ptsMs = Double(nowHost.value) / Double(nowHost.timescale) * 1000.0
            print("[H264TCP] host PTS ms=\(String(format: "%.3f", ptsMs)) timescale=\(nowHost.timescale)")
        }
        
        // Encode frame; PTS from camera presentationTime
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            print("[H264TCP] Encode error: \(status)")
        }
    }
    
    // MARK: - Public Methods
    func startStreaming() {
        guard !isStreaming else {
            print("[H264TCP] Already streaming")
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
        print("[H264TCP] === Starting H.264 TCP Stream ===")
        
        // Check camera permission
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                await MainActor.run {
                    statusMessage = "Camera permission denied"
                    connectionStatus = .error("No camera access")
                    isStreaming = false
                }
                return
            }
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            await MainActor.run {
                statusMessage = "Camera permission denied"
                connectionStatus = .error("No camera access")
                isStreaming = false
            }
            return
        }
        
        // Setup camera
        let cameraReady = setupCamera()
        guard cameraReady else {
            await MainActor.run {
                statusMessage = "Camera setup failed"
                connectionStatus = .error("Camera error")
                isStreaming = false
            }
            return
        }
        
        // Connect preview layer to session
        connectPreviewLayer()
        
        // Get video dimensions for encoder setup
        guard let session = captureSession else { return }
        var width: Int32 = 1920
        var height: Int32 = 1080
        
        if session.sessionPreset == .hd1280x720 {
            width = 1280
            height = 720
        }
        
        await MainActor.run {
            statusMessage = "Starting GStreamer..."
        }
        
        guard let port = Int32(serverPort) else {
            await MainActor.run {
                statusMessage = "Invalid port"
                connectionStatus = .error("Invalid port")
                isStreaming = false
            }
            captureSession?.stopRunning()
            captureSession = nil
            return
        }
        
        let pipelineStarted = GStreamerBridge.shared().startPipeline(withHost: serverHost, port: port)
        guard pipelineStarted else {
            await MainActor.run {
                statusMessage = "Pipeline start failed"
                connectionStatus = .error("GStreamer init failed")
                isStreaming = false
            }
            captureSession?.stopRunning()
            captureSession = nil
            return
        }
        
        isPipelineRunning = true
        
        await MainActor.run {
            isConnected = true
            connectionStatus = .connected
            statusMessage = "Pipeline ready, starting camera..."
        }
        
        // Start capture session on background thread (required by AVCaptureSession)
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.captureSession?.startRunning()
                continuation.resume()
            }
        }
        
        // Start orientation observer
        startOrientationObserver()
        
        // Prevent screen lock
        preventScreenLock(true)
        
        // Reset counters
        framesSent = 0
        bytesSent = 0
        
        await MainActor.run {
            connectionStatus = .streaming
            statusMessage = "Streaming (H.264 via GStreamer)"
        }
        
        print("[H264TCP] === Stream is LIVE (GStreamer) ===")
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        print("[H264TCP] Stopping stream")
        
        // Tear down encoder
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        
        // Re-enable screen lock
        preventScreenLock(false)
        
        // Stop orientation observer
        stopOrientationObserver()
        
        // Capture the session reference before clearing
        let session = captureSession
        captureSession = nil
        videoOutput = nil
        
        // Stop capture session on background thread
        captureQueue.async {
            session?.stopRunning()
        }
        
        // Stop GStreamer pipeline
        GStreamerBridge.shared().stopPipeline()
        isPipelineRunning = false
        
        isStreaming = false
        isConnected = false
        connectionStatus = .disconnected
        statusMessage = "Stopped"
        
        print("[H264TCP] Stream stopped and cleaned up")
    }
    
    // MARK: - H.264 Compression Session
    private func setupCompressionSessionIfNeeded(width: Int32, height: Int32) {
        if compressionSession != nil { return }
        
        var session: VTCompressionSession?
        let outputCallback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else { return }
            let streamManager = Unmanaged<H264TCPStreamManager>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
            streamManager.handleEncodedSample(sampleBuffer)
        }
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session else {
            print("[H264TCP] Failed to create compression session: \(status)")
            return
        }
        
        // Configure low-latency, reasonable quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_4_0)
        let bitrate: Int32 = Int32(videoBitrate * 1000) // kbps -> bps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFTypeRef)
        let keyframeSeconds = Double(keyframeInterval) / 30.0
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeSeconds as CFTypeRef)
        
        // Prepare session
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        print("[H264TCP] Compression session ready (\(width)x\(height))")
    }
    
    private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        guard isPipelineRunning else { return }
        guard let annexB = makeAnnexB(from: sampleBuffer) else { return }
        
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if framesSent < 3 {
            let ptsMs = Double(presentationTime.value) / Double(presentationTime.timescale) * 1000.0
            print("[H264TCP] capture PTS ms=\(String(format: "%.3f", ptsMs))")
        }
        
        let isKeyframe = !(CMGetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_NotSync, attachmentModeOut: nil) as? Bool ?? false)
        
        GStreamerBridge.shared().pushH264Data(annexB, isKeyframe: isKeyframe, presentationTime: presentationTime)
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.framesSent += 1
            self.bytesSent += Int64(annexB.count)
        }
    }
    
    private func makeAnnexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var annexB = Data()
        
        let isKeyframe = !(CMGetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_NotSync, attachmentModeOut: nil) as? Bool ?? false)
        if isKeyframe {
            // Prepend SPS/PPS
            var spsPointer: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            var ppsPointer: UnsafePointer<UInt8>?
            var ppsSize: Int = 0
            var parameterSetCount: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil) == noErr,
               let spsPointer, spsSize > 0 {
                annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                annexB.append(Data(bytes: spsPointer, count: spsSize))
            }
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil) == noErr,
               let ppsPointer, ppsSize > 0 {
                annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                annexB.append(Data(bytes: ppsPointer, count: ppsSize))
            }
        }
        
        var lengthAtOffset: size_t = 0
        var totalLength: size_t = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return nil }
        
        var bufferOffset: size_t = 0
        let avccHeaderLength = 4
        while bufferOffset + avccHeaderLength < totalLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, dataPointer.advanced(by: Int(bufferOffset)), avccHeaderLength)
            naluLength = CFSwapInt32BigToHost(naluLength)
            let naluStart = dataPointer.advanced(by: Int(bufferOffset + size_t(avccHeaderLength)))
            annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            annexB.append(Data(bytes: naluStart, count: Int(naluLength)))
            bufferOffset += size_t(avccHeaderLength) + size_t(naluLength)
        }
        
        return annexB
    }
    
    // MARK: - Preview Management
    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.videoGravity = .resizeAspectFill
        
        if let session = captureSession {
            layer.session = session
            print("[H264TCP] Preview layer connected to existing session")
        }
    }
    
    /// Connect the preview layer to the capture session (call after session is created)
    private func connectPreviewLayer() {
        guard let layer = previewLayer, let session = captureSession else { return }
        
        DispatchQueue.main.async {
            layer.session = session
            print("[H264TCP] Preview layer connected to session")
        }
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        if previewLayer == nil {
            previewLayer = AVCaptureVideoPreviewLayer()
            previewLayer?.videoGravity = .resizeAspectFill
            
            if let session = captureSession {
                previewLayer?.session = session
            }
        }
        return previewLayer
    }
    
    /// Get capture session for preview
    func getCaptureSession() -> AVCaptureSession? {
        return captureSession
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension H264TCPStreamManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Encode immediately on the capture queue (no main-thread hop)
        self.encodeAndSendFrame(pixelBuffer, presentationTime: presentationTime)
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("[H264TCP] Frame dropped")
    }
}

