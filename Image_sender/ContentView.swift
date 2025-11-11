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
        ZStack {
            // AR View
            ARViewContainer(sessionManager: sessionManager)
                .edgesIgnoringSafeArea(.all)
            
            // Control Panel
            VStack {
                Spacer()
                
                // Status Message
                Text(sessionManager.statusMessage)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.horizontal)
                
                // Control Buttons
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
                                .font(.system(size: 30))
                            Text(sessionManager.isSessionRunning ? "Stop AR" : "Start AR")
                                .font(.caption)
                        }
                        .frame(width: 100, height: 80)
                        .background(sessionManager.isSessionRunning ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                    
                    // Host/Client Buttons
                    HStack(spacing: 20) {
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
                                    .font(.system(size: 30))
                                Text(sessionManager.isHostMode ? "Stop Host" : "Make Host")
                                    .font(.caption)
                            }
                            .frame(width: 100, height: 80)
                            .background(sessionManager.isHostMode ? Color.orange : Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(15)
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
                                    .font(.system(size: 30))
                                Text(sessionManager.isClientMode ? "Stop Client" : "Make Client")
                                    .font(.caption)
                            }
                            .frame(width: 100, height: 80)
                            .background(sessionManager.isClientMode ? Color.orange : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(15)
                        }
                        .disabled(sessionManager.isHostMode) // Disable if host mode is active
                    }
                    
                    // Send to Server Button
                    Button(action: {
                        sessionManager.sendFrameToServer()
                    }) {
                        VStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                            Text("Send to Server")
                                .font(.caption)
                        }
                        .frame(width: 100, height: 80)
                        .background(Color.cyan)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                    .disabled(!sessionManager.isSessionRunning) // Disable if AR session not running
                }
                .padding(.bottom, 30)
                
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

#Preview {
    ContentView()
}
