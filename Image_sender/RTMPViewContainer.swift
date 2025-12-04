//
//  RTMPViewContainer.swift
//  Image_sender
//
//  SwiftUI wrapper for RTMP camera preview using HaishinKit 2.x
//

import SwiftUI
import AVFoundation
import HaishinKit

/// SwiftUI wrapper for MTHKView to display local camera preview for RTMP streaming
struct RTMPViewContainer: UIViewRepresentable {
    let streamManager: RTMPStreamManager
    
    func makeUIView(context: Context) -> MTHKView {
        let view = MTHKView(frame: .zero)
        view.videoGravity = .resizeAspectFill
        view.clipsToBounds = true
        
        // Register the view with the stream manager
        Task { @MainActor in
            streamManager.setPreviewView(view)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: MTHKView, context: Context) {
        // Update if needed
    }
    
    static func dismantleUIView(_ uiView: MTHKView, coordinator: ()) {
        // Cleanup handled by stream manager
    }
}
