//
//  ContentView.swift
//  Image_sender
//
//  Created by Quinton on 11/10/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = ARSessionManager()
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
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
                    .padding(.top, 10)
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
