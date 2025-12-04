//
//  WebRTCStreamManager.swift
//  Image_sender
//
//  Manages WebRTC camera streaming without ARKit
//

import Foundation
import Combine
import AVFoundation
import UIKit
import WebRTC

/// Connection status for WebRTC
enum WebRTCConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
    
    static func == (lhs: WebRTCConnectionStatus, rhs: WebRTCConnectionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case (.error(let lhsMsg), .error(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Manages WebRTC peer connection and camera streaming
class WebRTCStreamManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectionStatus: WebRTCConnectionStatus = .disconnected
    @Published var statusMessage = "WebRTC Ready"
    @Published var isStreaming = false
    @Published var signalingConnected = false
    
    // MARK: - Server Configuration (Published for UI binding)
    @Published var serverHost: String {
        didSet {
            UserDefaults.standard.set(serverHost, forKey: "webrtc_server_host")
        }
    }
    @Published var serverPort: String {
        didSet {
            UserDefaults.standard.set(serverPort, forKey: "webrtc_server_port")
        }
    }
    @Published var useSecureConnection: Bool {
        didSet {
            UserDefaults.standard.set(useSecureConnection, forKey: "webrtc_use_secure")
        }
    }
    @Published var cameraId: Int {
        didSet {
            UserDefaults.standard.set(cameraId, forKey: "webrtc_camera_id")
        }
    }
    
    // MARK: - WebRTC Components
    private var peerConnectionFactory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    
    // MARK: - WebSocket Signaling (Raw WebSocket, not Socket.IO)
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    
    // MARK: - Camera Preview
    private var localVideoView: RTCMTLVideoView?
    
    // MARK: - ICE Servers (STUN/TURN)
    private let iceServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
    ]
    
    // MARK: - Initialization
    override init() {
        // Load saved settings or use defaults
        self.serverHost = UserDefaults.standard.string(forKey: "webrtc_server_host") ?? "localhost"
        self.serverPort = UserDefaults.standard.string(forKey: "webrtc_server_port") ?? "8080"
        self.useSecureConnection = UserDefaults.standard.bool(forKey: "webrtc_use_secure")
        self.cameraId = UserDefaults.standard.integer(forKey: "webrtc_camera_id") // defaults to 0
        super.init()
        
        initializeWebRTC()
    }
    
    deinit {
        stopStreaming()
        cleanup()
    }
    
    // MARK: - WebRTC Setup
    private func initializeWebRTC() {
        RTCInitializeSSL()
        
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        
        peerConnectionFactory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        
        print("[WebRTC] Initialized peer connection factory")
    }
    
    private func createPeerConnection() -> RTCPeerConnection? {
        guard let factory = peerConnectionFactory else {
            print("[WebRTC] Error: Factory not initialized")
            return nil
        }
        
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        let connection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        )
        
        print("[WebRTC] Created peer connection")
        return connection
    }
    
    // MARK: - Camera Setup
    private func setupCamera() {
        guard let factory = peerConnectionFactory else {
            print("[WebRTC] Error: Factory not initialized")
            return
        }
        
        videoSource = factory.videoSource()
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource!)
        
        // Find the back camera (prefer environment/back camera for mobile)
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let backCamera = devices.first(where: { $0.position == .back }) ?? devices.first else {
            print("[WebRTC] Error: No camera found")
            DispatchQueue.main.async {
                self.statusMessage = "Error: No camera found"
                self.connectionStatus = .error("No camera")
            }
            return
        }
        
        // Find format close to 1280x720
        let formats = RTCCameraVideoCapturer.supportedFormats(for: backCamera)
        let targetWidth: Int32 = 1280
        let targetHeight: Int32 = 720
        
        var selectedFormat: AVCaptureDevice.Format?
        var currentDiff = Int32.max
        
        for format in formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(dimensions.width - targetWidth) + abs(dimensions.height - targetHeight)
            if diff < currentDiff {
                currentDiff = diff
                selectedFormat = format
            }
        }
        
        guard let format = selectedFormat else {
            print("[WebRTC] Error: No suitable format found")
            return
        }
        
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("[WebRTC] Selected camera format: \(dimensions.width)x\(dimensions.height)")
        
        // Get frame rate
        var maxFrameRate: Float64 = 30.0
        for range in format.videoSupportedFrameRateRanges {
            maxFrameRate = max(maxFrameRate, range.maxFrameRate)
        }
        let targetFPS = min(30, Int(maxFrameRate))
        
        videoCapturer?.startCapture(with: backCamera, format: format, fps: targetFPS) { [weak self] error in
            if let error = error {
                print("[WebRTC] Error starting capture: \(error)")
                DispatchQueue.main.async {
                    self?.statusMessage = "Camera error: \(error.localizedDescription)"
                    self?.connectionStatus = .error("Camera error")
                }
            } else {
                print("[WebRTC] Camera capture started")
            }
        }
        
        localVideoTrack = factory.videoTrack(with: videoSource!, trackId: "video0")
        localVideoTrack?.isEnabled = true
        
        // Add to preview if available
        if let view = localVideoView {
            localVideoTrack?.add(view)
        }
        
        print("[WebRTC] Camera setup complete")
    }
    
    // MARK: - Raw WebSocket Signaling
    func connectSignaling() {
        let scheme = useSecureConnection ? "wss" : "ws"
        let urlString = "\(scheme)://\(serverHost):\(serverPort)"
        
        guard let url = URL(string: urlString) else {
            print("[WebRTC] Invalid signaling URL: \(urlString)")
            DispatchQueue.main.async {
                self.statusMessage = "Invalid server URL"
                self.connectionStatus = .error("Invalid URL")
            }
            return
        }
        
        DispatchQueue.main.async {
            self.connectionStatus = .connecting
            self.statusMessage = "Connecting to \(self.serverHost)..."
        }
        
        print("[WebRTC] Connecting to \(urlString)")
        
        // Create URLSession with delegate for SSL handling
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 300
        urlSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: OperationQueue())
        
        // Create WebSocket request with proper headers
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()
        
        // Start receiving messages immediately
        receiveMessage()
        
        // The didOpenWithProtocol delegate will be called when connected,
        // which will then call sendRegister()
        print("[WebRTC] WebSocket task started, waiting for connection...")
    }
    
    private func sendRegister() {
        guard webSocket != nil else {
            print("[WebRTC] Cannot register - WebSocket not connected")
            return
        }
        
        let message: [String: Any] = [
            "type": "register",
            "camera_id": cameraId
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            print("[WebRTC] Failed to encode register message")
            return
        }
        
        print("[WebRTC] Sending register for camera_id: \(cameraId)")
        
        webSocket?.send(.string(text)) { [weak self] error in
            if let error = error {
                print("[WebRTC] Failed to send register: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.statusMessage = "Failed to register"
                    self?.connectionStatus = .error("Send failed")
                }
            } else {
                print("[WebRTC] Register message sent successfully")
            }
        }
    }
    
    private func receiveMessage() {
        guard let ws = webSocket else {
            print("[WebRTC] Cannot receive - WebSocket is nil")
            return
        }
        
        ws.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("[WebRTC] Received message: \(text.prefix(200))...")
                    self.handleSignalingMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        print("[WebRTC] Received data message: \(text.prefix(200))...")
                        self.handleSignalingMessage(text)
                    }
                @unknown default:
                    print("[WebRTC] Received unknown message type")
                }
                // Continue receiving
                self.receiveMessage()
                
            case .failure(let error):
                let nsError = error as NSError
                print("[WebRTC] WebSocket receive error: \(error.localizedDescription)")
                print("[WebRTC] Error code: \(nsError.code), domain: \(nsError.domain)")
                
                // Don't report error if we intentionally disconnected
                if self.isStreaming {
                    DispatchQueue.main.async {
                        self.signalingConnected = false
                        self.connectionStatus = .error("Connection lost: \(nsError.code)")
                        self.statusMessage = "Connection lost"
                    }
                }
            }
        }
    }
    
    private func handleSignalingMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[WebRTC] Invalid signaling message: \(text)")
            return
        }
        
        print("[WebRTC] Received message type: \(type)")
        
        switch type {
        case "registered":
            let registeredCameraId = json["camera_id"] as? Int ?? cameraId
            print("[WebRTC] Registered as camera \(registeredCameraId)")
            DispatchQueue.main.async {
                self.signalingConnected = true
                self.statusMessage = "Registered as Camera \(registeredCameraId)"
                self.connectionStatus = .connected
            }
            // Now create offer and start streaming
            createOfferAndSend()
            
        case "answer":
            if let sdp = json["sdp"] as? String {
                print("[WebRTC] Received SDP answer")
                handleAnswer(sdp: sdp)
            }
            
        case "ice":
            if let candidate = json["candidate"] as? String,
               let sdpMLineIndex = json["sdpMLineIndex"] as? Int {
                print("[WebRTC] Received ICE candidate")
                handleRemoteICECandidate(candidate: candidate, sdpMLineIndex: Int32(sdpMLineIndex))
            }
            
        case "error":
            let errorMessage = json["message"] as? String ?? "Unknown error"
            print("[WebRTC] Server error: \(errorMessage)")
            DispatchQueue.main.async {
                self.statusMessage = "Error: \(errorMessage)"
                self.connectionStatus = .error(errorMessage)
            }
            
        default:
            print("[WebRTC] Unknown message type: \(type)")
        }
    }
    
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            print("[WebRTC] Failed to encode JSON")
            return
        }
        
        webSocket?.send(.string(text)) { error in
            if let error = error {
                print("[WebRTC] Failed to send message: \(error)")
            }
        }
    }
    
    func disconnectSignaling() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession = nil
        
        DispatchQueue.main.async {
            self.signalingConnected = false
            self.connectionStatus = .disconnected
            self.statusMessage = "Disconnected"
        }
    }
    
    // MARK: - WebRTC Offer/Answer
    private func createOfferAndSend() {
        // Create peer connection if needed
        if peerConnection == nil {
            peerConnection = createPeerConnection()
        }
        
        guard let pc = peerConnection else {
            print("[WebRTC] Failed to create peer connection")
            return
        }
        
        // Add local tracks
        if let videoTrack = localVideoTrack {
            pc.add(videoTrack, streamIds: ["stream0"])
            print("[WebRTC] Added video track to peer connection")
        }
        
        // Create offer
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "false",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )
        
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self, let sdp = sdp else {
                print("[WebRTC] Failed to create offer: \(error?.localizedDescription ?? "unknown")")
                return
            }
            
            pc.setLocalDescription(sdp) { error in
                if let error = error {
                    print("[WebRTC] Failed to set local description: \(error)")
                    return
                }
                
                print("[WebRTC] Sending offer to server")
                self.sendJSON([
                    "type": "offer",
                    "sdp": sdp.sdp
                ])
                
                DispatchQueue.main.async {
                    self.statusMessage = "Offer sent, waiting for answer..."
                }
            }
        }
    }
    
    private func handleAnswer(sdp: String) {
        guard let pc = peerConnection else {
            print("[WebRTC] No peer connection to handle answer")
            return
        }
        
        let answerSDP = RTCSessionDescription(type: .answer, sdp: sdp)
        pc.setRemoteDescription(answerSDP) { [weak self] error in
            if let error = error {
                print("[WebRTC] Failed to set remote description: \(error)")
                DispatchQueue.main.async {
                    self?.statusMessage = "Connection error"
                }
            } else {
                print("[WebRTC] Remote description set successfully")
                DispatchQueue.main.async {
                    self?.statusMessage = "Streaming"
                }
            }
        }
    }
    
    private func handleRemoteICECandidate(candidate: String, sdpMLineIndex: Int32) {
        guard let pc = peerConnection else {
            print("[WebRTC] No peer connection to add ICE candidate")
            return
        }
        
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: nil)
        pc.add(iceCandidate) { error in
            if let error = error {
                print("[WebRTC] Failed to add ICE candidate: \(error)")
            } else {
                print("[WebRTC] Added remote ICE candidate")
            }
        }
    }
    
    // MARK: - Public Methods
    func startStreaming() {
        guard !isStreaming else {
            print("[WebRTC] Already streaming")
            return
        }
        
        DispatchQueue.main.async {
            self.statusMessage = "Starting camera..."
            self.isStreaming = true
        }
        
        // Setup camera first
        setupCamera()
        
        // Then connect to signaling server
        connectSignaling()
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        print("[WebRTC] Stopping stream")
        
        videoCapturer?.stopCapture()
        
        peerConnection?.close()
        peerConnection = nil
        
        disconnectSignaling()
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.connectionStatus = .disconnected
            self.statusMessage = "Stopped"
        }
    }
    
    func setLocalVideoView(_ view: RTCMTLVideoView) {
        localVideoView = view
        if let track = localVideoTrack {
            track.add(view)
        }
    }
    
    func removeLocalVideoView(_ view: RTCMTLVideoView) {
        if let track = localVideoTrack {
            track.remove(view)
        }
        localVideoView = nil
    }
    
    private func cleanup() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        peerConnectionFactory = nil
        RTCCleanupSSL()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCStreamManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTC] Signaling state: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("[WebRTC] Stream added: \(stream.streamId)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("[WebRTC] Stream removed: \(stream.streamId)")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("[WebRTC] Negotiation needed")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTC] ICE connection state: \(newState.rawValue)")
        
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                self.connectionStatus = .connected
                self.statusMessage = "Streaming"
            case .disconnected:
                self.statusMessage = "Disconnected"
            case .failed:
                self.connectionStatus = .error("Connection failed")
                self.statusMessage = "Connection failed"
            case .checking:
                self.statusMessage = "Connecting..."
            default:
                break
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTC] ICE gathering state: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("[WebRTC] Generated ICE candidate")
        
        // Send ICE candidate to server (matching web client format)
        sendJSON([
            "type": "ice",
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex
        ])
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("[WebRTC] Removed \(candidates.count) ICE candidates")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[WebRTC] Data channel opened: \(dataChannel.label)")
    }
}

// MARK: - URLSessionDelegate (for SSL certificate handling)
extension WebRTCStreamManager: URLSessionDelegate, URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept self-signed certificates for development
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            print("[WebRTC] Accepted SSL certificate for \(challenge.protectionSpace.host)")
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[WebRTC] WebSocket connected with protocol: \(`protocol` ?? "none")")
        DispatchQueue.main.async {
            self.signalingConnected = true
            self.statusMessage = "Connected, registering..."
        }
        // Now safe to register
        sendRegister()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("[WebRTC] WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString)")
        DispatchQueue.main.async {
            self.signalingConnected = false
            self.connectionStatus = .disconnected
            self.statusMessage = "Disconnected"
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("[WebRTC] URLSession task error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.signalingConnected = false
                self.connectionStatus = .error("Connection failed")
                self.statusMessage = "Connection failed"
            }
        }
    }
}
