//
//  H264TCPStreamManager.swift
//  Image_sender
//
//  Manages H.264 video streaming over TCP in MPEG-TS container format
//  for GStreamer tcpserversrc compatibility
//

import Foundation
import Combine
import AVFoundation
import VideoToolbox
import UIKit

// MARK: - MPEG-TS Muxer

/// MPEG-TS Muxer for wrapping H.264 video in Transport Stream format
/// Provides reliable framing with sync bytes (0x47) for GStreamer compatibility
class TSMuxer {
    // TS packet size is always 188 bytes
    private let tsPacketSize = 188
    
    // PIDs (Packet Identifiers)
    private let patPID: UInt16 = 0x0000      // Program Association Table
    private let pmtPID: UInt16 = 0x1000      // Program Map Table
    private let videoPID: UInt16 = 0x0100    // Video stream
    
    // Continuity counters (0-15, wrap around)
    private var patContinuityCounter: UInt8 = 0
    private var pmtContinuityCounter: UInt8 = 0
    private var videoContinuityCounter: UInt8 = 0
    
    // PAT/PMT interval counter
    private var packetsSincePAT: Int = 0
    private let patInterval = 30  // Send PAT/PMT every 30 video packets (~1 second at 30fps)
    
    // Pre-built PAT and PMT
    private var patPacket: Data!
    private var pmtPacket: Data!
    
    init() {
        buildPATPacket()
        buildPMTPacket()
    }
    
    /// Reset the muxer state (call when starting a new stream)
    func reset() {
        patContinuityCounter = 0
        pmtContinuityCounter = 0
        videoContinuityCounter = 0
        packetsSincePAT = 0
    }
    
    /// Mux H.264 Annex B data into MPEG-TS packets
    /// - Parameters:
    ///   - annexBData: H.264 data in Annex B format (with start codes)
    ///   - pts: Presentation timestamp in 90kHz units
    ///   - isKeyframe: Whether this is a keyframe (for random access indicator)
    /// - Returns: MPEG-TS data containing TS packets
    func mux(annexBData: Data, pts: UInt64, isKeyframe: Bool) -> Data {
        var output = Data()
        
        // Send PAT and PMT periodically (or on keyframes)
        if packetsSincePAT >= patInterval || isKeyframe {
            output.append(generatePATPacket())
            output.append(generatePMTPacket())
            packetsSincePAT = 0
        }
        
        // Wrap video data in PES and TS packets
        let pesData = createPESPacket(payload: annexBData, pts: pts, streamID: 0xE0)
        let tsPackets = createTSPackets(pesData: pesData, pid: videoPID, isKeyframe: isKeyframe)
        output.append(tsPackets)
        
        packetsSincePAT += 1
        
        return output
    }
    
    // MARK: - PAT (Program Association Table)
    
    private func buildPATPacket() {
        // PAT tells decoder where to find PMT
        // Program 1 -> PMT at PID 0x1000
        var packet = Data(count: tsPacketSize)
        
        // Sync byte
        packet[0] = 0x47
        
        // Header: PUSI=1, PID=0x0000
        packet[1] = 0x40  // Transport error=0, PUSI=1, Priority=0
        packet[2] = 0x00  // PID high bits = 0
        
        // Adaptation + CC (will be updated when sent)
        packet[3] = 0x10  // No adaptation field, payload only
        
        // Pointer field (since PUSI=1)
        packet[4] = 0x00
        
        // PAT section
        var offset = 5
        
        // Table ID (0x00 for PAT)
        packet[offset] = 0x00
        offset += 1
        
        // Section syntax + section length (13 bytes: 5 header + 4 program + 4 CRC)
        packet[offset] = 0xB0      // Section syntax indicator=1, private=0, reserved=11
        packet[offset + 1] = 0x0D  // Section length = 13
        offset += 2
        
        // Transport stream ID
        packet[offset] = 0x00
        packet[offset + 1] = 0x01  // TS ID = 1
        offset += 2
        
        // Version number, current/next
        packet[offset] = 0xC1  // Reserved=11, version=0, current=1
        offset += 1
        
        // Section number
        packet[offset] = 0x00
        offset += 1
        
        // Last section number
        packet[offset] = 0x00
        offset += 1
        
        // Program 1
        packet[offset] = 0x00
        packet[offset + 1] = 0x01  // Program number = 1
        offset += 2
        
        // PMT PID (0x1000)
        packet[offset] = 0xF0 | UInt8((pmtPID >> 8) & 0x1F)  // Reserved=111, PID high
        packet[offset + 1] = UInt8(pmtPID & 0xFF)
        offset += 2
        
        // Calculate CRC32
        let crcData = packet[5..<offset]
        let crc = calculateCRC32(data: crcData)
        packet[offset] = UInt8((crc >> 24) & 0xFF)
        packet[offset + 1] = UInt8((crc >> 16) & 0xFF)
        packet[offset + 2] = UInt8((crc >> 8) & 0xFF)
        packet[offset + 3] = UInt8(crc & 0xFF)
        offset += 4
        
        // Fill rest with 0xFF (stuffing)
        for i in offset..<tsPacketSize {
            packet[i] = 0xFF
        }
        
        patPacket = packet
    }
    
    private func generatePATPacket() -> Data {
        var packet = patPacket!
        // Update continuity counter
        packet[3] = 0x10 | (patContinuityCounter & 0x0F)
        patContinuityCounter = (patContinuityCounter + 1) & 0x0F
        return packet
    }
    
    // MARK: - PMT (Program Map Table)
    
    private func buildPMTPacket() {
        // PMT describes the program's streams
        var packet = Data(count: tsPacketSize)
        
        // Sync byte
        packet[0] = 0x47
        
        // Header: PUSI=1, PID=0x1000
        packet[1] = 0x40 | UInt8((pmtPID >> 8) & 0x1F)
        packet[2] = UInt8(pmtPID & 0xFF)
        
        // Adaptation + CC
        packet[3] = 0x10
        
        // Pointer field
        packet[4] = 0x00
        
        var offset = 5
        
        // Table ID (0x02 for PMT)
        packet[offset] = 0x02
        offset += 1
        
        // Section syntax + section length (18 bytes)
        packet[offset] = 0xB0
        packet[offset + 1] = 0x12  // Section length = 18
        offset += 2
        
        // Program number
        packet[offset] = 0x00
        packet[offset + 1] = 0x01  // Program 1
        offset += 2
        
        // Version, current/next
        packet[offset] = 0xC1
        offset += 1
        
        // Section number
        packet[offset] = 0x00
        offset += 1
        
        // Last section number
        packet[offset] = 0x00
        offset += 1
        
        // PCR PID (use video PID)
        packet[offset] = 0xE0 | UInt8((videoPID >> 8) & 0x1F)
        packet[offset + 1] = UInt8(videoPID & 0xFF)
        offset += 2
        
        // Program info length (0)
        packet[offset] = 0xF0
        packet[offset + 1] = 0x00
        offset += 2
        
        // Stream: H.264 video
        packet[offset] = 0x1B  // Stream type = H.264
        offset += 1
        
        // Elementary PID
        packet[offset] = 0xE0 | UInt8((videoPID >> 8) & 0x1F)
        packet[offset + 1] = UInt8(videoPID & 0xFF)
        offset += 2
        
        // ES info length (0)
        packet[offset] = 0xF0
        packet[offset + 1] = 0x00
        offset += 2
        
        // CRC32
        let crcData = packet[5..<offset]
        let crc = calculateCRC32(data: crcData)
        packet[offset] = UInt8((crc >> 24) & 0xFF)
        packet[offset + 1] = UInt8((crc >> 16) & 0xFF)
        packet[offset + 2] = UInt8((crc >> 8) & 0xFF)
        packet[offset + 3] = UInt8(crc & 0xFF)
        offset += 4
        
        // Stuffing
        for i in offset..<tsPacketSize {
            packet[i] = 0xFF
        }
        
        pmtPacket = packet
    }
    
    private func generatePMTPacket() -> Data {
        var packet = pmtPacket!
        packet[3] = 0x10 | (pmtContinuityCounter & 0x0F)
        pmtContinuityCounter = (pmtContinuityCounter + 1) & 0x0F
        return packet
    }
    
    // MARK: - PES (Packetized Elementary Stream)
    
    private func createPESPacket(payload: Data, pts: UInt64, streamID: UInt8) -> Data {
        var pes = Data()
        
        // PES start code (0x000001)
        pes.append(contentsOf: [0x00, 0x00, 0x01])
        
        // Stream ID (0xE0 = video)
        pes.append(streamID)
        
        // PES packet length (0 = unbounded for video)
        pes.append(contentsOf: [0x00, 0x00])
        
        // Optional PES header
        // Marker bits + scrambling + priority + alignment + copyright + original
        pes.append(0x80)  // '10' marker, no scrambling, etc.
        
        // PTS/DTS flags + other flags
        pes.append(0x80)  // PTS only, no DTS
        
        // PES header data length (5 bytes for PTS)
        pes.append(0x05)
        
        // PTS (5 bytes)
        // Format: 0010 PTS[32..30] 1 PTS[29..15] 1 PTS[14..0] 1
        let pts32_30 = UInt8((pts >> 30) & 0x07)
        let pts29_15 = UInt16((pts >> 15) & 0x7FFF)
        let pts14_0 = UInt16(pts & 0x7FFF)
        
        pes.append(0x21 | (pts32_30 << 1))  // 0010 xxx1
        pes.append(UInt8((pts29_15 >> 7) & 0xFF))
        pes.append(UInt8(((pts29_15 & 0x7F) << 1) | 0x01))
        pes.append(UInt8((pts14_0 >> 7) & 0xFF))
        pes.append(UInt8(((pts14_0 & 0x7F) << 1) | 0x01))
        
        // Payload (H.264 Annex B data)
        pes.append(payload)
        
        return pes
    }
    
    // MARK: - TS Packets
    
    private func createTSPackets(pesData: Data, pid: UInt16, isKeyframe: Bool) -> Data {
        var output = Data()
        var pesOffset = 0
        var isFirstPacket = true
        
        while pesOffset < pesData.count {
            var packet = Data(count: tsPacketSize)
            var packetOffset = 0
            
            // Sync byte
            packet[packetOffset] = 0x47
            packetOffset += 1
            
            // Transport header
            var header1: UInt8 = 0
            var header2: UInt8 = UInt8(pid & 0xFF)
            
            if isFirstPacket {
                header1 |= 0x40  // PUSI (Payload Unit Start Indicator)
            }
            header1 |= UInt8((pid >> 8) & 0x1F)
            
            packet[packetOffset] = header1
            packet[packetOffset + 1] = header2
            packetOffset += 2
            
            // Calculate how much payload we can fit
            let remainingPES = pesData.count - pesOffset
            var payloadSize = tsPacketSize - 4  // 184 bytes max
            
            // Check if we need adaptation field for stuffing
            var needsAdaptation = false
            var adaptationLength = 0
            
            if remainingPES < payloadSize {
                // Need stuffing - use adaptation field
                needsAdaptation = true
                adaptationLength = payloadSize - remainingPES
                payloadSize = remainingPES
            }
            
            // For first packet of keyframe, add PCR in adaptation field
            if isFirstPacket && isKeyframe && !needsAdaptation {
                needsAdaptation = true
                adaptationLength = 8  // Minimum for PCR
                payloadSize = tsPacketSize - 4 - adaptationLength - 1
            }
            
            // Adaptation field control + continuity counter
            var afControl: UInt8 = 0x10  // Payload only
            if needsAdaptation {
                afControl = 0x30  // Adaptation + payload
            }
            afControl |= (videoContinuityCounter & 0x0F)
            videoContinuityCounter = (videoContinuityCounter + 1) & 0x0F
            
            packet[packetOffset] = afControl
            packetOffset += 1
            
            // Adaptation field if needed
            if needsAdaptation {
                if adaptationLength > 0 {
                    packet[packetOffset] = UInt8(adaptationLength - 1)  // AF length (excluding length byte)
                    packetOffset += 1
                    
                    if adaptationLength > 1 {
                        // Adaptation flags: discontinuity, random access, priority, PCR, etc.
                        var flags: UInt8 = 0
                        if isFirstPacket && isKeyframe {
                            flags |= 0x40  // Random access indicator
                        }
                        packet[packetOffset] = flags
                        packetOffset += 1
                        
                        // Fill remaining adaptation field with stuffing (0xFF)
                        for _ in 2..<adaptationLength {
                            packet[packetOffset] = 0xFF
                            packetOffset += 1
                        }
                    }
                }
            }
            
            // Payload
            let payloadData = pesData[pesOffset..<(pesOffset + payloadSize)]
            for byte in payloadData {
                packet[packetOffset] = byte
                packetOffset += 1
            }
            
            // Fill any remaining bytes (shouldn't happen with proper calculation)
            while packetOffset < tsPacketSize {
                packet[packetOffset] = 0xFF
                packetOffset += 1
            }
            
            output.append(packet)
            pesOffset += payloadSize
            isFirstPacket = false
        }
        
        return output
    }
    
    // MARK: - CRC32 (MPEG-2 variant)
    
    private func calculateCRC32(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                if (crc & 0x80000000) != 0 {
                    crc = (crc << 1) ^ 0x04C11DB7
                } else {
                    crc <<= 1
                }
            }
        }
        
        return crc
    }
}

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

/// Manages H.264 streaming over TCP in MPEG-TS container format
/// Compatible with GStreamer: tcpserversrc ! tsdemux ! h264parse ! avdec_h264 ! autovideosink
@MainActor
class H264TCPStreamManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectionStatus: H264TCPConnectionStatus = .disconnected
    @Published var statusMessage = "MPEG-TS Ready"
    @Published var isStreaming = false
    @Published var isConnected = false
    @Published var framesSent: Int = 0
    @Published var bytesSent: Int64 = 0
    
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
    
    // MARK: - VideoToolbox Compression
    private var compressionSession: VTCompressionSession?
    private var hasWrittenSPS = false
    private var spsData: Data?
    private var ppsData: Data?
    
    // MARK: - MPEG-TS Muxer
    private var tsMuxer = TSMuxer()
    private var streamStartTime: CMTime?
    
    // MARK: - TCP Socket
    private var tcpSocket: TCPSocket?
    private let socketQueue = DispatchQueue(label: "com.imagesender.h264tcp.socket", qos: .userInitiated)
    
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
    
    // MARK: - VideoToolbox H.264 Encoder Setup
    private func setupEncoder(width: Int32, height: Int32) -> Bool {
        print("[H264TCP] Setting up H.264 encoder for \(width)x\(height)")
        
        // Create compression session
        let encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let compressionSession = session else {
            print("[H264TCP] Failed to create compression session: \(status)")
            return false
        }
        
        self.compressionSession = compressionSession
        
        // Configure encoder properties
        // Real-time encoding
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        // Profile: Main or High for good quality/compatibility balance
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        
        // Bitrate (in bits per second)
        let bitrateValue = videoBitrate * 1000 as CFNumber
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateValue)
        
        // Data rate limits (peak bitrate) - allow 1.5x average for bursts
        let dataRateLimit = [videoBitrate * 1500, 1] as CFArray
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimit)
        
        // Keyframe interval (max interval between keyframes)
        let keyframeIntervalValue = keyframeInterval as CFNumber
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeIntervalValue)
        
        // Expected frame rate
        let frameRate = 30 as CFNumber
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate)
        
        // Allow frame reordering (B-frames) - disable for lower latency
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        // Entropy mode: CAVLC for compatibility, CABAC for better compression
        VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        
        // Prepare encoder
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        guard prepareStatus == noErr else {
            print("[H264TCP] Failed to prepare encoder: \(prepareStatus)")
            return false
        }
        
        print("[H264TCP] H.264 encoder setup complete")
        return true
    }
    
    // MARK: - TCP Connection
    private func connectTCP() async -> Bool {
        print("[H264TCP] Connecting to \(serverHost):\(serverPort)...")
        
        guard let port = UInt16(serverPort) else {
            print("[H264TCP] Invalid port number")
            return false
        }
        
        let socket = TCPSocket()
        
        let connected = await socket.connect(host: serverHost, port: port)
        
        if connected {
            self.tcpSocket = socket
            print("[H264TCP] TCP connected successfully")
            return true
        } else {
            print("[H264TCP] TCP connection failed")
            return false
        }
    }
    
    // MARK: - H.264 NAL Unit Handling
    /// Convert VideoToolbox AVCC format to Annex B byte-stream format
    /// GStreamer h264parse expects Annex B with start codes (0x00 0x00 0x00 0x01)
    private func convertToAnnexB(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            return nil
        }
        
        var annexBData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        
        var offset = 0
        while offset < length {
            // Read NAL unit length (4 bytes, big endian in AVCC)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4
            
            if offset + Int(nalLength) > length {
                print("[H264TCP] Invalid NAL unit length")
                break
            }
            
            // Write Annex B start code
            annexBData.append(contentsOf: startCode)
            
            // Write NAL unit data
            annexBData.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
            
            offset += Int(nalLength)
        }
        
        return annexBData
    }
    
    /// Extract SPS and PPS from format description and convert to Annex B
    private func extractParameterSets(formatDescription: CMFormatDescription) -> Data? {
        var data = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        
        // Get SPS
        var spsSize: Int = 0
        var spsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let sps = spsPointer {
            data.append(contentsOf: startCode)
            data.append(Data(bytes: sps, count: spsSize))
            spsData = Data(bytes: sps, count: spsSize)
            print("[H264TCP] Extracted SPS: \(spsSize) bytes")
        }
        
        // Get PPS
        var ppsSize: Int = 0
        var ppsPointer: UnsafePointer<UInt8>?
        
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        
        if status == noErr, let pps = ppsPointer {
            data.append(contentsOf: startCode)
            data.append(Data(bytes: pps, count: ppsSize))
            ppsData = Data(bytes: pps, count: ppsSize)
            print("[H264TCP] Extracted PPS: \(ppsSize) bytes")
        }
        
        return data.isEmpty ? nil : data
    }
    
    // MARK: - Frame Encoding and Sending
    private func encodeAndSendFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = compressionSession else { return }
        guard tcpSocket?.isConnected == true else { return }
        
        // Encode frame using the handler-based API
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime.invalid,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, infoFlags, sampleBuffer in
                guard let self = self else { return }
                guard status == noErr, let sampleBuffer = sampleBuffer else {
                    if status != noErr {
                        print("[H264TCP] Encoding error: \(status)")
                    }
                    return
                }
                
                self.processsEncodedFrame(sampleBuffer)
            }
        )
        
        if status != noErr {
            print("[H264TCP] Failed to submit frame for encoding: \(status)")
        }
    }
    
    private func processsEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        // Check if this is a keyframe (IDR frame)
        // kCMSampleAttachmentKey_NotSync is true for non-keyframes, false or absent for keyframes
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }
        
        var annexBData = Data()
        
        // For keyframes, prepend SPS/PPS (only extract once, then reuse)
        if isKeyframe {
            if !hasWrittenSPS {
                // First keyframe - extract and cache SPS/PPS
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let paramSets = extractParameterSets(formatDescription: formatDesc) {
                    annexBData.append(paramSets)
                    hasWrittenSPS = true
                }
            } else if let sps = spsData, let pps = ppsData {
                // Subsequent keyframes - use cached SPS/PPS
                let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
                annexBData.append(contentsOf: startCode)
                annexBData.append(sps)
                annexBData.append(contentsOf: startCode)
                annexBData.append(pps)
            }
        }
        
        // Convert frame data to Annex B
        if let frameData = convertToAnnexB(sampleBuffer: sampleBuffer) {
            annexBData.append(frameData)
        }
        
        guard !annexBData.isEmpty else { return }
        
        // Calculate PTS in 90kHz units (MPEG-TS standard timebase)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // Initialize stream start time on first frame
        if streamStartTime == nil {
            streamStartTime = presentationTime
        }
        
        // Calculate relative PTS from stream start
        let relativeTime = CMTimeSubtract(presentationTime, streamStartTime!)
        let pts90kHz = UInt64(CMTimeGetSeconds(relativeTime) * 90000.0)
        
        // Mux into MPEG-TS
        let tsData = tsMuxer.mux(annexBData: annexBData, pts: pts90kHz, isKeyframe: isKeyframe)
        
        // Send over TCP
        socketQueue.async { [weak self] in
            self?.tcpSocket?.send(data: tsData)
            
            Task { @MainActor in
                guard let self = self else { return }
                self.framesSent += 1
                self.bytesSent += Int64(tsData.count)
                
                // Log every 30 frames (roughly once per second at 30fps)
                if self.framesSent % 30 == 0 {
                    let mbSent = Double(self.bytesSent) / 1_000_000.0
                    print("[MPEG-TS] Sent \(self.framesSent) frames, \(String(format: "%.2f", mbSent)) MB")
                }
            }
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
        
        // Setup encoder
        let encoderReady = setupEncoder(width: width, height: height)
        guard encoderReady else {
            await MainActor.run {
                statusMessage = "Encoder setup failed"
                connectionStatus = .error("Encoder error")
                isStreaming = false
            }
            captureSession?.stopRunning()
            captureSession = nil
            return
        }
        
        // Connect TCP
        await MainActor.run {
            statusMessage = "Connecting to server..."
        }
        
        let tcpConnected = await connectTCP()
        guard tcpConnected else {
            await MainActor.run {
                statusMessage = "Connection failed"
                connectionStatus = .error("TCP connection failed")
                isStreaming = false
            }
            teardownEncoder()
            captureSession?.stopRunning()
            captureSession = nil
            return
        }
        
        await MainActor.run {
            isConnected = true
            connectionStatus = .connected
            statusMessage = "Connected, starting camera..."
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
        
        // Reset counters and muxer state
        hasWrittenSPS = false
        framesSent = 0
        bytesSent = 0
        streamStartTime = nil
        tsMuxer.reset()
        
        await MainActor.run {
            connectionStatus = .streaming
            statusMessage = "Streaming (MPEG-TS)"
        }
        
        print("[MPEG-TS] === Stream is LIVE ===")
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        print("[H264TCP] Stopping stream")
        
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
        
        // Teardown encoder
        teardownEncoder()
        
        // Disconnect TCP
        tcpSocket?.disconnect()
        tcpSocket = nil
        
        isStreaming = false
        isConnected = false
        connectionStatus = .disconnected
        statusMessage = "Stopped"
        
        print("[H264TCP] Stream stopped and cleaned up")
    }
    
    private func teardownEncoder() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        hasWrittenSPS = false
        spsData = nil
        ppsData = nil
        streamStartTime = nil
        tsMuxer.reset()
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
        
        // Encode and send (this is called on capture queue)
        Task { @MainActor in
            self.encodeAndSendFrame(pixelBuffer, presentationTime: presentationTime)
        }
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("[H264TCP] Frame dropped")
    }
}

// MARK: - TCP Socket Helper
class TCPSocket {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private(set) var isConnected = false
    private let streamQueue = DispatchQueue(label: "com.imagesender.tcpsocket.stream")
    
    func connect(host: String, port: UInt16) async -> Bool {
        return await withCheckedContinuation { continuation in
            streamQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                
                var readStream: Unmanaged<CFReadStream>?
                var writeStream: Unmanaged<CFWriteStream>?
                
                CFStreamCreatePairWithSocketToHost(
                    kCFAllocatorDefault,
                    host as CFString,
                    UInt32(port),
                    &readStream,
                    &writeStream
                )
                
                guard let input = readStream?.takeRetainedValue() as InputStream?,
                      let output = writeStream?.takeRetainedValue() as OutputStream? else {
                    print("[TCPSocket] Failed to create streams")
                    continuation.resume(returning: false)
                    return
                }
                
                self.inputStream = input
                self.outputStream = output
                
                // Disable Nagle's algorithm for lower latency
                input.setProperty(NSNumber(value: true), forKey: Stream.PropertyKey(rawValue: "kCFStreamPropertyTCPNoDelay"))
                output.setProperty(NSNumber(value: true), forKey: Stream.PropertyKey(rawValue: "kCFStreamPropertyTCPNoDelay"))
                
                input.open()
                output.open()
                
                // Wait for connection with timeout
                var attempts = 0
                let maxAttempts = 50 // 5 seconds
                
                while attempts < maxAttempts {
                    if output.streamStatus == .open {
                        self.isConnected = true
                        print("[TCPSocket] Connected to \(host):\(port)")
                        continuation.resume(returning: true)
                        return
                    } else if output.streamStatus == .error {
                        print("[TCPSocket] Connection error: \(output.streamError?.localizedDescription ?? "unknown")")
                        self.cleanup()
                        continuation.resume(returning: false)
                        return
                    }
                    
                    Thread.sleep(forTimeInterval: 0.1)
                    attempts += 1
                }
                
                print("[TCPSocket] Connection timeout")
                self.cleanup()
                continuation.resume(returning: false)
            }
        }
    }
    
    func send(data: Data) {
        guard isConnected, let output = outputStream else { return }
        
        data.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var bytesRemaining = data.count
            var offset = 0
            
            while bytesRemaining > 0 {
                let bytesWritten = output.write(pointer.advanced(by: offset), maxLength: bytesRemaining)
                
                if bytesWritten < 0 {
                    // Error
                    print("[TCPSocket] Write error: \(output.streamError?.localizedDescription ?? "unknown")")
                    isConnected = false
                    break
                } else if bytesWritten == 0 {
                    // Stream full, wait briefly
                    Thread.sleep(forTimeInterval: 0.001)
                } else {
                    offset += bytesWritten
                    bytesRemaining -= bytesWritten
                }
            }
        }
    }
    
    func disconnect() {
        streamQueue.async { [weak self] in
            self?.cleanup()
        }
    }
    
    private func cleanup() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        isConnected = false
        print("[TCPSocket] Disconnected")
    }
}

