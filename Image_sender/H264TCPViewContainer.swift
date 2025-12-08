//
//  H264TCPViewContainer.swift
//  Image_sender
//
//  SwiftUI wrapper for H.264 TCP camera preview using AVCaptureVideoPreviewLayer
//

import SwiftUI
import AVFoundation

/// SwiftUI wrapper for AVCaptureVideoPreviewLayer to display local camera preview for H.264 TCP streaming
struct H264TCPViewContainer: UIViewRepresentable {
    @ObservedObject var streamManager: H264TCPStreamManager
    
    func makeUIView(context: Context) -> H264TCPPreviewView {
        let view = H264TCPPreviewView(frame: .zero)
        view.clipsToBounds = true
        
        // Register the view with the stream manager
        streamManager.setPreviewLayer(view.previewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: H264TCPPreviewView, context: Context) {
        // Update preview layer session when it becomes available
        // This will be called when @Published properties change
        if let session = streamManager.getCaptureSession(), uiView.previewLayer.session == nil {
            uiView.previewLayer.session = session
            print("[H264TCP] Preview layer session set in updateUIView")
        }
    }
    
    static func dismantleUIView(_ uiView: H264TCPPreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

/// Custom UIView that contains an AVCaptureVideoPreviewLayer
class H264TCPPreviewView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    
    override init(frame: CGRect) {
        previewLayer = AVCaptureVideoPreviewLayer()
        previewLayer.videoGravity = .resizeAspectFill
        
        super.init(frame: frame)
        
        layer.addSublayer(previewLayer)
        backgroundColor = .black
    }
    
    required init?(coder: NSCoder) {
        previewLayer = AVCaptureVideoPreviewLayer()
        previewLayer.videoGravity = .resizeAspectFill
        
        super.init(coder: coder)
        
        layer.addSublayer(previewLayer)
        backgroundColor = .black
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

