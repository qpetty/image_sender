//
//  ContentView.swift
//  Image_sender
//
//  Created by Quinton on 11/10/25.
//

import SwiftUI

/// App mode enum for switching between ARKit, WebRTC, RTMP, SRT, and H.264 TCP streaming
enum AppMode: String, CaseIterable {
    case arkit = "ARKit"
    case webrtc = "WebRTC"
    case rtmp = "RTMP"
    case srt = "SRT"
    case h264tcp = "H.264"
}

struct ContentView: View {
    @StateObject private var sessionManager = ARSessionManager()
    @StateObject private var webrtcManager = WebRTCStreamManager()
    @StateObject private var rtmpManager = RTMPStreamManager()
    @StateObject private var srtManager = SRTStreamManager()
    @StateObject private var h264tcpManager = H264TCPStreamManager()
    @State private var currentMode: AppMode = .arkit
    @State private var showServerSettings = false
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                // Main content based on mode
                switch currentMode {
                case .arkit:
                    arkitView(isLandscape: isLandscape, geometry: geometry)
                case .webrtc:
                    webrtcView(isLandscape: isLandscape, geometry: geometry)
                case .rtmp:
                    rtmpView(isLandscape: isLandscape, geometry: geometry)
                case .srt:
                    srtView(isLandscape: isLandscape, geometry: geometry)
                case .h264tcp:
                    h264tcpView(isLandscape: isLandscape, geometry: geometry)
                }
                
                // Mode Switcher (top center)
                VStack {
                    modeSwitcher
                        .padding(.top, 10)
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Mode Switcher
    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(AppMode.allCases, id: \.self) { mode in
                Button(action: {
                    switchMode(to: mode)
                }) {
                    Text(mode.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(currentMode == mode ? .white : .white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(currentMode == mode ? Color.blue : Color.clear)
                }
            }
        }
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
    }
    
    private func switchMode(to newMode: AppMode) {
        guard newMode != currentMode else { return }
        
        // Stop current mode
        switch currentMode {
        case .arkit:
            if sessionManager.isSessionRunning {
                sessionManager.stopARSession()
            }
        case .webrtc:
            if webrtcManager.isStreaming {
                webrtcManager.stopStreaming()
            }
        case .rtmp:
            if rtmpManager.isStreaming {
                rtmpManager.stopStreaming()
            }
        case .srt:
            if srtManager.isStreaming {
                srtManager.stopStreaming()
            }
        case .h264tcp:
            if h264tcpManager.isStreaming {
                h264tcpManager.stopStreaming()
            }
        }
        
        currentMode = newMode
    }
    
    // MARK: - WebRTC View
    @ViewBuilder
    private func webrtcView(isLandscape: Bool, geometry: GeometryProxy) -> some View {
        ZStack {
            // Camera Preview
            WebRTCViewContainer(streamManager: webrtcManager)
                .edgesIgnoringSafeArea(.all)
            
            // Overlay UI
            VStack {
                Spacer()
                    .frame(height: 50) // Space for mode switcher
                
                // Status indicators and settings button
                HStack {
                    // Connection status
                    HStack(spacing: 8) {
                        Circle()
                            .fill(webrtcStatusColor)
                            .frame(width: 10, height: 10)
                        Text(webrtcStatusText)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    // Settings button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showServerSettings.toggle()
                        }
                    }) {
                        Image(systemName: showServerSettings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    .disabled(webrtcManager.isStreaming)
                    .opacity(webrtcManager.isStreaming ? 0.5 : 1.0)
                    
                    // Signaling status
                    if webrtcManager.isStreaming {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(webrtcManager.signalingConnected ? Color.green : Color.yellow)
                                .frame(width: 8, height: 8)
                            Text(webrtcManager.signalingConnected ? "Signal OK" : "Connecting...")
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // Server settings panel
                if showServerSettings {
                    VStack(spacing: 12) {
                        Text("Signaling Server")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        HStack(spacing: 8) {
                            // Host input
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Host")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("192.168.1.100", text: $webrtcManager.serverHost)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .keyboardType(.numbersAndPunctuation)
                            }
                            .frame(maxWidth: .infinity)
                            
                            // Port input
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Port")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("8080", text: $webrtcManager.serverPort)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .keyboardType(.numberPad)
                            }
                            .frame(width: 80)
                        }
                        
                        // Secure connection toggle
                        HStack {
                            Toggle(isOn: $webrtcManager.useSecureConnection) {
                                HStack(spacing: 6) {
                                    Image(systemName: webrtcManager.useSecureConnection ? "lock.fill" : "lock.open")
                                        .font(.caption)
                                    Text(webrtcManager.useSecureConnection ? "WSS (Secure)" : "WS (Insecure)")
                                        .font(.caption)
                                }
                                .foregroundColor(webrtcManager.useSecureConnection ? .green : .orange)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: .green))
                        }
                        
                        // Camera ID selector
                        HStack {
                            Text("Camera ID")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Picker("Camera", selection: $webrtcManager.cameraId) {
                                Text("Camera 0").tag(0)
                                Text("Camera 1").tag(1)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 160)
                        }
                        
                        // Current server display
                        let scheme = webrtcManager.useSecureConnection ? "wss" : "ws"
                        Text("→ \(scheme)://\(webrtcManager.serverHost):\(webrtcManager.serverPort) (cam \(webrtcManager.cameraId))")
                            .font(.caption2)
                            .foregroundColor(webrtcManager.useSecureConnection ? .green : .orange)
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                Spacer()
                
                // Status message
                Text(webrtcManager.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                
                // Control button
                Button(action: {
                    // Hide keyboard if showing
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    // Hide settings when starting stream
                    if !webrtcManager.isStreaming {
                        showServerSettings = false
                    }
                    
                    if webrtcManager.isStreaming {
                        webrtcManager.stopStreaming()
                    } else {
                        webrtcManager.startStreaming()
                    }
                }) {
                    VStack {
                        Image(systemName: webrtcManager.isStreaming ? "video.slash.fill" : "video.fill")
                            .font(.system(size: 28))
                        Text(webrtcManager.isStreaming ? "Stop Stream" : "Start Stream")
                            .font(.caption)
                    }
                    .frame(width: 100, height: 70)
                    .background(webrtcManager.isStreaming ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.bottom, 30)
            }
        }
        .onTapGesture {
            // Dismiss keyboard when tapping outside
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    // MARK: - RTMP View
    @ViewBuilder
    private func rtmpView(isLandscape: Bool, geometry: GeometryProxy) -> some View {
        ZStack {
            // Camera Preview
            RTMPViewContainer(streamManager: rtmpManager)
                .edgesIgnoringSafeArea(.all)
            
            // Overlay UI
            VStack {
                Spacer()
                    .frame(height: 50) // Space for mode switcher
                
                // Status indicators and settings button
                HStack {
                    // Connection status
                    HStack(spacing: 8) {
                        Circle()
                            .fill(rtmpStatusColor)
                            .frame(width: 10, height: 10)
                        Text(rtmpStatusText)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    // Settings button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showServerSettings.toggle()
                        }
                    }) {
                        Image(systemName: showServerSettings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    .disabled(rtmpManager.isStreaming)
                    .opacity(rtmpManager.isStreaming ? 0.5 : 1.0)
                    
                    // Connection indicator
                    if rtmpManager.isStreaming {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(rtmpManager.isConnected ? Color.green : Color.yellow)
                                .frame(width: 8, height: 8)
                            Text(rtmpManager.isConnected ? "Connected" : "Connecting...")
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // Server settings panel
                if showServerSettings {
                    VStack(spacing: 12) {
                        Text("RTMP Server")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        // RTMP URL input
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RTMP URL")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                            TextField("rtmp://server:1935/live", text: $rtmpManager.rtmpURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 14, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                        }
                        
                        // Stream key input
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stream Key")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                            TextField("stream", text: $rtmpManager.streamKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 14, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        
                        // Bitrate settings
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Video Bitrate (kbps)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Picker("Video", selection: $rtmpManager.videoBitrate) {
                                    Text("2000").tag(2000)
                                    Text("4000").tag(4000)
                                    Text("6000").tag(6000)
                                    Text("8000").tag(8000)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Audio (kbps)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Picker("Audio", selection: $rtmpManager.audioBitrate) {
                                    Text("64").tag(64)
                                    Text("128").tag(128)
                                    Text("192").tag(192)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            .frame(width: 120)
                        }
                        
                        // Current server display
                        let displayURL = rtmpManager.rtmpURL.hasSuffix("/") 
                            ? "\(rtmpManager.rtmpURL)\(rtmpManager.streamKey)" 
                            : "\(rtmpManager.rtmpURL)/\(rtmpManager.streamKey)"
                        Text("→ \(displayURL)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                Spacer()
                
                // Status message
                Text(rtmpManager.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                
                // Control button
                Button(action: {
                    // Hide keyboard if showing
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    // Hide settings when starting stream
                    if !rtmpManager.isStreaming {
                        showServerSettings = false
                    }
                    
                    if rtmpManager.isStreaming {
                        rtmpManager.stopStreaming()
                    } else {
                        rtmpManager.startStreaming()
                    }
                }) {
                    VStack {
                        Image(systemName: rtmpManager.isStreaming ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 28))
                        Text(rtmpManager.isStreaming ? "Stop Stream" : "Start Stream")
                            .font(.caption)
                    }
                    .frame(width: 100, height: 70)
                    .background(rtmpManager.isStreaming ? Color.red : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.bottom, 30)
            }
        }
        .onTapGesture {
            // Dismiss keyboard when tapping outside
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    // MARK: - SRT View
    @ViewBuilder
    private func srtView(isLandscape: Bool, geometry: GeometryProxy) -> some View {
        ZStack {
            // Camera Preview
            SRTViewContainer(streamManager: srtManager)
                .edgesIgnoringSafeArea(.all)
            
            // Overlay UI
            VStack {
                Spacer()
                    .frame(height: 50) // Space for mode switcher
                
                // Status indicators and settings button
                HStack {
                    // Connection status
                    HStack(spacing: 8) {
                        Circle()
                            .fill(srtStatusColor)
                            .frame(width: 10, height: 10)
                        Text(srtStatusText)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    // Settings button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showServerSettings.toggle()
                        }
                    }) {
                        Image(systemName: showServerSettings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    .disabled(srtManager.isStreaming)
                    .opacity(srtManager.isStreaming ? 0.5 : 1.0)
                    
                    // Connection indicator
                    if srtManager.isStreaming {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(srtManager.isConnected ? Color.green : Color.yellow)
                                .frame(width: 8, height: 8)
                            Text(srtManager.isConnected ? "Connected" : "Connecting...")
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // Server settings panel
                if showServerSettings {
                    VStack(spacing: 12) {
                        Text("SRT Server")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        // Host and Port row
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Host")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("192.168.1.100", text: $srtManager.serverHost)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .keyboardType(.numbersAndPunctuation)
                            }
                            .frame(maxWidth: .infinity)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Port")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("9000", text: $srtManager.serverPort)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .keyboardType(.numberPad)
                            }
                            .frame(width: 80)
                        }
                        
                        // Stream ID and Passphrase row
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Stream ID (optional)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("stream_name", text: $srtManager.streamId)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                            .frame(maxWidth: .infinity)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Passphrase")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                SecureField("optional", text: $srtManager.passphrase)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                            }
                            .frame(width: 120)
                        }
                        
                        // Current server display
                        let displayURL = "srt://\(srtManager.serverHost):\(srtManager.serverPort)"
                        Text("→ \(displayURL)")
                            .font(.caption2)
                            .foregroundColor(.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                Spacer()
                
                // Status message
                Text(srtManager.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                
                // Control button
                Button(action: {
                    // Hide keyboard if showing
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    // Hide settings when starting stream
                    if !srtManager.isStreaming {
                        showServerSettings = false
                    }
                    
                    if srtManager.isStreaming {
                        srtManager.stopStreaming()
                    } else {
                        srtManager.startStreaming()
                    }
                }) {
                    VStack {
                        Image(systemName: srtManager.isStreaming ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                            .font(.system(size: 28))
                        Text(srtManager.isStreaming ? "Stop Stream" : "Start Stream")
                            .font(.caption)
                    }
                    .frame(width: 100, height: 70)
                    .background(srtManager.isStreaming ? Color.red : Color.cyan)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.bottom, 30)
            }
        }
        .onTapGesture {
            // Dismiss keyboard when tapping outside
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    // MARK: - H.264 TCP View
    @ViewBuilder
    private func h264tcpView(isLandscape: Bool, geometry: GeometryProxy) -> some View {
        ZStack {
            // Camera Preview
            H264TCPViewContainer(streamManager: h264tcpManager)
                .edgesIgnoringSafeArea(.all)
            
            // Overlay UI
            VStack {
                Spacer()
                    .frame(height: 50) // Space for mode switcher
                
                // Status indicators and settings button
                HStack {
                    // Connection status
                    HStack(spacing: 8) {
                        Circle()
                            .fill(h264tcpStatusColor)
                            .frame(width: 10, height: 10)
                        Text(h264tcpStatusText)
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    // Settings button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showServerSettings.toggle()
                        }
                    }) {
                        Image(systemName: showServerSettings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    .disabled(h264tcpManager.isStreaming)
                    .opacity(h264tcpManager.isStreaming ? 0.5 : 1.0)
                    
                    // Stats indicator when streaming
                    if h264tcpManager.isStreaming {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(h264tcpManager.isConnected ? Color.green : Color.yellow)
                                .frame(width: 8, height: 8)
                            Text("\(h264tcpManager.framesSent) frames")
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // Server settings panel
                if showServerSettings {
                    VStack(spacing: 12) {
                        Text("H.264 TCP Server")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        // Host and Port row
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("GStreamer Host")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("192.168.1.100", text: $h264tcpManager.serverHost)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .keyboardType(.numbersAndPunctuation)
                            }
                            .frame(maxWidth: .infinity)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Port")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                TextField("5000", text: $h264tcpManager.serverPort)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .font(.system(size: 14, design: .monospaced))
                                    .keyboardType(.numberPad)
                            }
                            .frame(width: 80)
                        }
                        
                        // Bitrate and keyframe settings
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Video Bitrate (kbps)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Picker("Bitrate", selection: $h264tcpManager.videoBitrate) {
                                    Text("2000").tag(2000)
                                    Text("4000").tag(4000)
                                    Text("6000").tag(6000)
                                    Text("8000").tag(8000)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Keyframe")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Picker("Keyframe", selection: $h264tcpManager.keyframeInterval) {
                                    Text("15").tag(15)
                                    Text("30").tag(30)
                                    Text("60").tag(60)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            .frame(width: 120)
                        }
                        
                        // GStreamer pipeline hint
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GStreamer receiver (MPEG-TS):")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                            Text("tcpserversrc port=\(h264tcpManager.serverPort) ! tsdemux ! h264parse ! avdec_h264 ! autovideosink")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.green)
                                .lineLimit(2)
                        }
                        
                        // Current server display
                        Text("→ tcp://\(h264tcpManager.serverHost):\(h264tcpManager.serverPort)")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                Spacer()
                
                // Status message and stats
                VStack(spacing: 8) {
                    Text(h264tcpManager.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                    
                    if h264tcpManager.isStreaming {
                        let mbSent = Double(h264tcpManager.bytesSent) / 1_000_000.0
                        Text(String(format: "%.2f MB sent", mbSent))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)
                
                // Control button
                Button(action: {
                    // Hide keyboard if showing
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    // Hide settings when starting stream
                    if !h264tcpManager.isStreaming {
                        showServerSettings = false
                    }
                    
                    if h264tcpManager.isStreaming {
                        h264tcpManager.stopStreaming()
                    } else {
                        h264tcpManager.startStreaming()
                    }
                }) {
                    VStack {
                        Image(systemName: h264tcpManager.isStreaming ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                        Text(h264tcpManager.isStreaming ? "Stop Stream" : "Start Stream")
                            .font(.caption)
                    }
                    .frame(width: 100, height: 70)
                    .background(h264tcpManager.isStreaming ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.bottom, 30)
            }
        }
        .onTapGesture {
            // Dismiss keyboard when tapping outside
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    private var h264tcpStatusColor: Color {
        switch h264tcpManager.connectionStatus {
        case .streaming:
            return .green
        case .connected:
            return .blue
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var h264tcpStatusText: String {
        switch h264tcpManager.connectionStatus {
        case .streaming:
            return "Streaming"
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Ready"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    private var rtmpStatusColor: Color {
        switch rtmpManager.connectionStatus {
        case .publishing:
            return .green
        case .connected:
            return .blue
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var rtmpStatusText: String {
        switch rtmpManager.connectionStatus {
        case .publishing:
            return "Publishing"
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Ready"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    private var srtStatusColor: Color {
        switch srtManager.connectionStatus {
        case .publishing:
            return .green
        case .connected:
            return .blue
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var srtStatusText: String {
        switch srtManager.connectionStatus {
        case .publishing:
            return "Publishing"
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Ready"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    private var webrtcStatusColor: Color {
        switch webrtcManager.connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }
    
    private var webrtcStatusText: String {
        switch webrtcManager.connectionStatus {
        case .connected:
            return "Streaming"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Ready"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
    
    // MARK: - ARKit View
    @ViewBuilder
    private func arkitView(isLandscape: Bool, geometry: GeometryProxy) -> some View {
        ZStack {
            // AR View
            ARViewContainer(sessionManager: sessionManager)
                .edgesIgnoringSafeArea(.all)
            
            // Camera to Sphere Distance (top left corner)
            if let distance = sessionManager.cameraToSphereDistance {
                VStack {
                    HStack {
                        Text(String(format: "%.2f m", distance))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(6)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 50) // Account for mode switcher
                .padding(.leading, 10)
            }
            
            // Control Panel
            if isLandscape {
                    // Landscape layout: buttons on right side
                    HStack {
                        Spacer()
                        
                        VStack {
                            // WebSocket Status (top right)
                            VStack(spacing: 5) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(webSocketStatusColor(sessionManager.webSocketStatus))
                                        .frame(width: 10, height: 10)
                                    Text(webSocketStatusText(sessionManager.webSocketStatus))
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                                
                                if let lastTrigger = sessionManager.lastRemoteTrigger {
                                    Text("Last trigger: \(formatTime(lastTrigger))")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                        .background(Color.black.opacity(0.6))
                                        .cornerRadius(6)
                                }
                            }
                            .padding(.top, 10)
                            
                            Spacer()
                            
                            // Status Message
                            Text(sessionManager.statusMessage)
                                .padding()
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .padding(.horizontal)
                            
                            // Control Buttons - 2 columns in landscape
                            HStack(spacing: 15) {
                                // Left Column
                                VStack(spacing: 15) {
                                    // AR Session Button
                                    Button(action: {
                                        if sessionManager.isSessionRunning {
                                            sessionManager.stopARSession()
                                        } else {
                                            sessionManager.startARSession()
                                        }
                                    }) {
                                        VStack {
                                            Image(systemName: sessionManager.isSessionRunning ? "camera.fill" : "camera")
                                                .font(.system(size: 25))
                                            Text(sessionManager.isSessionRunning ? "Stop AR" : "Start AR")
                                                .font(.caption)
                                        }
                                        .frame(width: 85, height: 65)
                                        .background(sessionManager.isSessionRunning ? Color.red : Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    
                                    // Make Host Button
                                    Button(action: {
                                        if sessionManager.isHostMode {
                                            sessionManager.stopHostMode()
                                        } else {
                                            sessionManager.startHostMode()
                                        }
                                    }) {
                                        VStack {
                                            Image(systemName: sessionManager.isHostMode ? "server.rack" : "server.rack")
                                                .font(.system(size: 25))
                                            Text(sessionManager.isHostMode ? "Stop Host" : "Make Host")
                                                .font(.caption)
                                        }
                                        .frame(width: 85, height: 65)
                                        .background(sessionManager.isHostMode ? Color.orange : Color.purple)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    .disabled(sessionManager.isClientMode) // Disable if client mode is active
                                }
                                
                                // Right Column
                                VStack(spacing: 15) {
                                    // Make Client Button
                                    Button(action: {
                                        if sessionManager.isClientMode {
                                            sessionManager.stopClientMode()
                                        } else {
                                            sessionManager.startClientMode()
                                        }
                                    }) {
                                        VStack {
                                            Image(systemName: sessionManager.isClientMode ? "laptopcomputer" : "laptopcomputer")
                                                .font(.system(size: 25))
                                            Text(sessionManager.isClientMode ? "Stop Client" : "Make Client")
                                                .font(.caption)
                                        }
                                        .frame(width: 85, height: 65)
                                        .background(sessionManager.isClientMode ? Color.orange : Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    .disabled(sessionManager.isHostMode) // Disable if host mode is active
                                    
                                    // Send to Server Button
                                    Button(action: {
                                        sessionManager.sendFrameToServer()
                                    }) {
                                        VStack {
                                            Image(systemName: "arrow.up.circle.fill")
                                                .font(.system(size: 25))
                                            Text("Send to Server")
                                                .font(.caption)
                                        }
                                        .frame(width: 85, height: 65)
                                        .background(Color.cyan)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    .disabled(!sessionManager.isSessionRunning) // Disable if AR session not running
                                }
                            }
                            .padding(.trailing, 20)
                            .padding(.bottom, 20)
                            
                            // Connected Peers Info
                            if !sessionManager.connectedPeers.isEmpty {
                                Text("Connected: \(sessionManager.connectedPeers.count) peer(s)")
                                    .padding()
                                    .background(Color.blue.opacity(0.7))
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                    .padding(.horizontal)
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                } else {
                    // Portrait layout: buttons inline at bottom
                    VStack {
                        // WebSocket Status (top of screen)
                        VStack(spacing: 5) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(webSocketStatusColor(sessionManager.webSocketStatus))
                                    .frame(width: 10, height: 10)
                                Text(webSocketStatusText(sessionManager.webSocketStatus))
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                            
                            if let lastTrigger = sessionManager.lastRemoteTrigger {
                                Text("Last trigger: \(formatTime(lastTrigger))")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(6)
                            }
                        }
                        .padding(.top, 10)
                        
                        Spacer()
                        
                        // Status Message
                        Text(sessionManager.statusMessage)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                        
                        // Control Buttons - Horizontal in portrait
                        HStack(spacing: 15) {
                            // AR Session Button
                            Button(action: {
                                if sessionManager.isSessionRunning {
                                    sessionManager.stopARSession()
                                } else {
                                    sessionManager.startARSession()
                                }
                            }) {
                                VStack {
                                    Image(systemName: sessionManager.isSessionRunning ? "camera.fill" : "camera")
                                        .font(.system(size: 25))
                                    Text(sessionManager.isSessionRunning ? "Stop AR" : "Start AR")
                                        .font(.caption)
                                }
                                .frame(width: 85, height: 65)
                                .background(sessionManager.isSessionRunning ? Color.red : Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            
                            // Make Host Button
                            Button(action: {
                                if sessionManager.isHostMode {
                                    sessionManager.stopHostMode()
                                } else {
                                    sessionManager.startHostMode()
                                }
                            }) {
                                VStack {
                                    Image(systemName: sessionManager.isHostMode ? "server.rack" : "server.rack")
                                        .font(.system(size: 25))
                                    Text(sessionManager.isHostMode ? "Stop Host" : "Make Host")
                                        .font(.caption)
                                }
                                .frame(width: 85, height: 65)
                                .background(sessionManager.isHostMode ? Color.orange : Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(sessionManager.isClientMode) // Disable if client mode is active
                            
                            // Make Client Button
                            Button(action: {
                                if sessionManager.isClientMode {
                                    sessionManager.stopClientMode()
                                } else {
                                    sessionManager.startClientMode()
                                }
                            }) {
                                VStack {
                                    Image(systemName: sessionManager.isClientMode ? "laptopcomputer" : "laptopcomputer")
                                        .font(.system(size: 25))
                                    Text(sessionManager.isClientMode ? "Stop Client" : "Make Client")
                                        .font(.caption)
                                }
                                .frame(width: 85, height: 65)
                                .background(sessionManager.isClientMode ? Color.orange : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(sessionManager.isHostMode) // Disable if host mode is active
                            
                            // Send to Server Button
                            Button(action: {
                                sessionManager.sendFrameToServer()
                            }) {
                                VStack {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 25))
                                    Text("Send to Server")
                                        .font(.caption)
                                }
                                .frame(width: 85, height: 65)
                                .background(Color.cyan)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(!sessionManager.isSessionRunning) // Disable if AR session not running
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        
                        // Connected Peers Info
                        if !sessionManager.connectedPeers.isEmpty {
                            Text("Connected: \(sessionManager.connectedPeers.count) peer(s)")
                                .padding()
                                .background(Color.blue.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .padding(.horizontal)
                                .padding(.bottom, 10)
                        }
                    }
                }
        }
    }
    
    // Helper functions for WebSocket status display
    private func webSocketStatusColor(_ status: WebSocketConnectionStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        case .error:
            return .orange
        }
    }
    
    private func webSocketStatusText(_ status: WebSocketConnectionStatus) -> String {
        switch status {
        case .connected:
            return "WebSocket: Connected"
        case .connecting:
            return "WebSocket: Connecting..."
        case .disconnected:
            return "WebSocket: Disconnected"
        case .error(let message):
            return "WebSocket: Error - \(message)"
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

#Preview {
    ContentView()
}
