//
//  ARViewContainer.swift
//  Image_sender
//
//  Created for ARKit integration
//

import SwiftUI
import RealityKit
import ARKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var sessionManager: ARSessionManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        
        // Configure ARView to use simpler rendering to avoid material warnings
        // Disable advanced features that might trigger the material resolution warning
        arView.renderOptions = [
            .disablePersonOcclusion,
            .disableDepthOfField,
            .disableMotionBlur
        ]
        
        // Set delegate but don't start session yet
        // Session will be started when user taps the "Start AR" button
        arView.session.delegate = sessionManager
        
        // Store reference to ARView in session manager
        sessionManager.setARView(arView)
        
        // Add tap gesture recognizer for moving sphere (host only)
        let tapGesture = UITapGestureRecognizer(target: sessionManager, action: #selector(ARSessionManager.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Session state is managed by ARSessionManager
        // No need to update here as the session is controlled via the manager
    }
}

