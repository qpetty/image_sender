//
//  WebSocketManager.swift
//  Image_sender
//
//  Manages WebSocket connection to server for remote frame triggering
//
//  Uses Socket.IO-Client-Swift package for Socket.IO communication
//

import Foundation
import Combine
import UIKit
import SocketIO

enum WebSocketConnectionStatus {
    case disconnected
    case connecting
    case connected
    case error(String)
}

class WebSocketManager: ObservableObject {
    @Published var connectionStatus: WebSocketConnectionStatus = .disconnected
    @Published var lastTriggerReceived: Date?
    
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var serverURL: String
    
    var onCaptureTrigger: (() -> Void)?
    
    init(serverIP: String, serverPort: UInt16 = 8080) {
        // Flask-SocketIO uses Socket.IO protocol
        // Using HTTP URL - Socket.IO will upgrade to WebSocket
        self.serverURL = "http://\(serverIP):\(serverPort)"
    }
    
    func connect() {
        guard case .disconnected = connectionStatus else {
            print("[WebSocket] Already connected or connecting")
            return
        }
        
        guard let url = URL(string: serverURL) else {
            DispatchQueue.main.async {
                self.connectionStatus = .error("Invalid server URL: \(self.serverURL)")
            }
            return
        }
        
        DispatchQueue.main.async {
            self.connectionStatus = .connecting
        }
        
        // Configure Socket.IO manager
        let config: SocketIOClientConfiguration = [
            .log(false), // Set to true for debugging
            .compress,
            .forceWebsockets(false), // Allow polling fallback
            .reconnects(true),
            .reconnectAttempts(-1), // Infinite reconnection attempts
            .reconnectWait(2),
            .reconnectWaitMax(10)
        ]
        
        manager = SocketManager(socketURL: url, config: config)
        socket = manager?.defaultSocket
        
        setupEventHandlers()
        
        socket?.connect()
        
        print("[WebSocket] Connecting to: \(serverURL)")
    }
    
    private func setupEventHandlers() {
        guard let socket = socket else { return }
        
        // Handle connection events
        socket.on(clientEvent: .connect) { [weak self] data, ack in
            print("[WebSocket] Connected to server")
            DispatchQueue.main.async {
                self?.connectionStatus = .connected
            }
            
            // Send client_ready event with device name
            socket.emit("client_ready", ["device_name": UIDevice.current.name])
        }
        
        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("[WebSocket] Disconnected from server")
            DispatchQueue.main.async {
                self?.connectionStatus = .disconnected
            }
        }
        
        socket.on(clientEvent: .error) { [weak self] data, ack in
            let errorMessage = data.first as? String ?? "Unknown error"
            print("[WebSocket] Error: \(errorMessage)")
            DispatchQueue.main.async {
                self?.connectionStatus = .error(errorMessage)
            }
        }
        
        socket.on(clientEvent: .reconnect) { [weak self] data, ack in
            print("[WebSocket] Reconnecting...")
            DispatchQueue.main.async {
                self?.connectionStatus = .connecting
            }
        }
        
        // Handle server events
        socket.on("connected") { [weak self] data, ack in
            print("[WebSocket] Server confirmed connection")
            DispatchQueue.main.async {
                self?.connectionStatus = .connected
            }
        }
        
        socket.on("capture_frame") { [weak self] data, ack in
            print("[WebSocket] Received capture_frame trigger")
            DispatchQueue.main.async {
                self?.lastTriggerReceived = Date()
                self?.onCaptureTrigger?()
            }
        }
    }
    
    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        
        DispatchQueue.main.async {
            self.connectionStatus = .disconnected
        }
        
        print("[WebSocket] Disconnected from server")
    }
    
    deinit {
        disconnect()
    }
}

