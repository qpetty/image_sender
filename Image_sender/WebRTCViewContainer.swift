//
//  WebRTCViewContainer.swift
//  Image_sender
//
//  SwiftUI wrapper for WebRTC camera preview
//

import SwiftUI
import WebRTC

/// SwiftUI wrapper for RTCMTLVideoView to display local camera preview
struct WebRTCViewContainer: UIViewRepresentable {
    let streamManager: WebRTCStreamManager
    
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.videoContentMode = .scaleAspectFill
        videoView.clipsToBounds = true
        
        // Register the view with the stream manager
        streamManager.setLocalVideoView(videoView)
        
        return videoView
    }
    
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // Update if needed
    }
    
    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
        // Note: We can't easily access streamManager here to remove the view
        // The stream manager will handle cleanup when it's deallocated
    }
}

/// A view that shows the WebRTC camera preview with controls
struct WebRTCStreamView: View {
    @ObservedObject var streamManager: WebRTCStreamManager
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera Preview
                WebRTCViewContainer(streamManager: streamManager)
                    .edgesIgnoringSafeArea(.all)
                
                // Overlay UI
                VStack {
                    // Status bar at top
                    HStack {
                        // Connection status indicator
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(statusText)
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        
                        Spacer()
                        
                        // Signaling status
                        if streamManager.isStreaming {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(streamManager.signalingConnected ? Color.green : Color.yellow)
                                    .frame(width: 8, height: 8)
                                Text(streamManager.signalingConnected ? "Signal: OK" : "Signal: ...")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 16)
                    
                    Spacer()
                    
                    // Status message
                    Text(streamManager.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                    
                    // Control buttons
                    HStack(spacing: 20) {
                        // Start/Stop streaming button
                        Button(action: {
                            if streamManager.isStreaming {
                                streamManager.stopStreaming()
                            } else {
                                streamManager.startStreaming()
                            }
                        }) {
                            VStack {
                                Image(systemName: streamManager.isStreaming ? "video.slash.fill" : "video.fill")
                                    .font(.system(size: 28))
                                Text(streamManager.isStreaming ? "Stop" : "Start")
                                    .font(.caption)
                            }
                            .frame(width: 90, height: 70)
                            .background(streamManager.isStreaming ? Color.red : Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch streamManager.connectionStatus {
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
    
    private var statusText: String {
        switch streamManager.connectionStatus {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
}

