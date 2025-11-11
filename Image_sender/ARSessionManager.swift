//
//  ARSessionManager.swift
//  Image_sender
//
//  Manages ARKit session and collaborative AR features
//

import Foundation
import Combine
import ARKit
import RealityKit
import MultipeerConnectivity
import UIKit
import CoreImage

class ARSessionManager: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var isHostMode = false
    @Published var isClientMode = false
    @Published var connectedPeers: [MCPeerID] = []
    @Published var statusMessage = "Ready to start AR session"
    @Published var isSynchronized = false
    
    private var arView: ARView?
    private var arSession: ARSession? {
        return arView?.session
    }
    private var sphereAnchor: AnchorEntity?
    private var sphereARAnchor: ARAnchor? // Store reference to ARAnchor for coordinate updates
    private var sphereEntity: ModelEntity?
    private var isSphereSynchronized = false // Track if sphere is synchronized from host
    private var hasReceivedCollaborationData = false
    private var hasReceivedWorldMap = false
    private var hasSentWorldMap = false
    private var sessionStartTime: Date?
    private var multipeerConnectivityService: MultipeerConnectivityService?
    private var sceneUpdateSubscription: Cancellable?
    
    // Server configuration
    private let serverIP = "192.168.4.21"
    private let serverPort: UInt16 = 8080
    
    // Multipeer Connectivity
    // Service type must be 1-15 characters, alphanumeric and hyphens only
    // Must match the NSBonjourServices entry in Info.plist (without the _ and .tcp suffix)
    // Format in Info.plist: "_imagesender-ar._tcp"
    // Format in code: "imagesender-ar"
    private let serviceType = "imagesender-ar"
    private var myPeerID: MCPeerID
    private var multipeerSession: MCSession
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    private var serviceBrowser: MCNearbyServiceBrowser?
    
    override init() {
        // Initialize Multipeer Connectivity
        myPeerID = MCPeerID(displayName: UIDevice.current.name)
        multipeerSession = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        
        super.init()
        
        multipeerSession.delegate = self
    }
    
    func setARView(_ view: ARView) {
        self.arView = view
        setupSynchronizationService()
    }
    
    // Handle tap gestures to place or move sphere (host only)
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        // Only allow placing/moving sphere if we're the host and AR session is running
        guard isHostMode, isSessionRunning, let arView = arView else {
            if isHostMode && !isSessionRunning {
                DispatchQueue.main.async {
                    self.statusMessage = "Start AR session first to place sphere"
                }
            }
            return
        }
        
        let location = gesture.location(in: arView)
        
        // Perform raycast to find planes - try horizontal planes first (most common)
        var hitTestResults = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .horizontal)
        
        // If no horizontal plane found, try vertical planes
        if hitTestResults.isEmpty {
            hitTestResults = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .vertical)
        }
        
        // If still no plane found, try any plane alignment
        if hitTestResults.isEmpty {
            hitTestResults = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any)
        }
        
        // Use the first valid hit result
        if let firstResult = hitTestResults.first {
            // Get the world position from the raycast result
            let worldPosition = simd_float3(
                firstResult.worldTransform.columns.3.x,
                firstResult.worldTransform.columns.3.y,
                firstResult.worldTransform.columns.3.z
            )
            
            // Create transform matrix with the new position
            var transform = matrix_identity_float4x4
            transform.columns.3.x = worldPosition.x
            transform.columns.3.y = worldPosition.y
            transform.columns.3.z = worldPosition.z
            
            // Check if sphere already exists
            if let currentSphereAnchor = sphereAnchor, let currentSphereEntity = sphereEntity {
                // Sphere exists - move it to the new position
                // Remove old anchor and create new one with updated position
                if let oldAnchor = sphereARAnchor {
                    arView.session.remove(anchor: oldAnchor)
                }
                
                let newARAnchor = ARAnchor(name: "sphereAnchor", transform: transform)
                self.sphereARAnchor = newARAnchor
                arView.session.add(anchor: newARAnchor)
                
                // Update the AnchorEntity to use the new ARAnchor
                // Remove old anchor entity and create new one
                arView.scene.removeAnchor(currentSphereAnchor)
                
                let newAnchor = AnchorEntity(anchor: newARAnchor)
                
                // Re-add SynchronizationComponent to the new anchor
                var anchorSync = SynchronizationComponent()
                anchorSync.ownershipTransferMode = .autoAccept
                newAnchor.components[SynchronizationComponent.self] = anchorSync
                
                // Re-add the sphere entity to the new anchor
                // Re-add SynchronizationComponent to sphere if needed
                var sphereSync = SynchronizationComponent()
                sphereSync.ownershipTransferMode = .autoAccept
                currentSphereEntity.components[SynchronizationComponent.self] = sphereSync
                
                newAnchor.addChild(currentSphereEntity)
                
                arView.scene.addAnchor(newAnchor)
                self.sphereAnchor = newAnchor
                
                print("Host: Moved sphere to position: \(worldPosition)")
                DispatchQueue.main.async {
                    self.statusMessage = "Sphere moved to plane"
                }
            } else {
                // Sphere doesn't exist - create it at the tap location
                createSphereAtPosition(transform: transform, worldPosition: worldPosition)
            }
        } else {
            // No plane detected at tap location
            print("Host: Tap did not hit a plane - make sure AR has detected planes")
            DispatchQueue.main.async {
                self.statusMessage = "Tap did not hit a plane - scan the surface first"
            }
        }
    }
    
    private func setupSynchronizationService() {
        guard let arView = arView else { return }
        
        // Create MultipeerConnectivityService for synchronization
        // This bridges our MCSession with RealityKit's synchronization system
        do {
            multipeerConnectivityService = try MultipeerConnectivityService(session: multipeerSession)
            
            // Assign the synchronization service to the scene
            arView.scene.synchronizationService = multipeerConnectivityService
            
            // Subscribe to scene updates to detect when synchronized anchors are added
            sceneUpdateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.handleSceneUpdate()
            }
            
            print("SynchronizationService set up with MultipeerConnectivity")
        } catch {
            print("Error setting up MultipeerConnectivityService: \(error)")
        }
    }
    
    private func handleSceneUpdate() {
        // Client: Check if a synchronized sphere anchor has been received from host
        guard isClientMode, sphereAnchor == nil, let arView = arView else { return }
        
        // Look for anchors in the scene that were synchronized from the host
        // Synchronized anchors are added to the scene automatically by SynchronizationService
        for anchor in arView.scene.anchors {
            if let anchorEntity = anchor as? AnchorEntity,
               !anchorEntity.children.isEmpty,
               let modelEntity = anchorEntity.children.first as? ModelEntity {
                // Check if this is a sphere (has a mesh resource)
                if modelEntity.components[ModelComponent.self]?.mesh != nil {
                    // This is a synchronized anchor with a model from the host
                    self.sphereAnchor = anchorEntity
                    self.sphereEntity = modelEntity
                    self.isSphereSynchronized = true // Mark as synchronized so we don't remove it
                    print("Client: Detected synchronized sphere anchor from host")
                    DispatchQueue.main.async {
                        self.statusMessage = "Sphere synchronized from host"
                        self.updateSphereColor()
                    }
                    break
                }
            }
        }
    }
    
    private func removeSphere() {
        guard let arView = arView else { return }
        
        // Don't remove synchronized spheres - they are managed by SynchronizationService
        if isSphereSynchronized {
            print("Not removing synchronized sphere - managed by SynchronizationService")
            return
        }
        
        // Remove ARAnchor from session if it exists
        if let arAnchor = sphereARAnchor {
            arView.session.remove(anchor: arAnchor)
        }
        
        // Remove anchor entity if it exists (only local anchors)
        if let anchor = sphereAnchor {
            arView.scene.removeAnchor(anchor)
        }
        
        // Clear references
        sphereAnchor = nil
        sphereARAnchor = nil
        sphereEntity = nil
        isSphereSynchronized = false
    }
    
    // Create sphere at a specific position (used when placing via tap)
    private func createSphereAtPosition(transform: simd_float4x4, worldPosition: simd_float3) {
        // Only host creates the sphere - it will be synced to clients via SynchronizationService
        guard isHostMode, let arView = arView else {
            print("Client device: Not creating sphere (will receive from host via sync)")
            return
        }
        
        print("Host device: Creating sphere at position: \(worldPosition)")
        
        // Ensure only one sphere exists - remove any existing sphere first
        removeSphere()
        
        // Create an ARAnchor at the specified position
        // Using ARAnchor ensures proper coordinate system alignment with ARKit
        let arAnchor = ARAnchor(name: "sphereAnchor", transform: transform)
        
        // Store reference to ARAnchor for coordinate updates
        self.sphereARAnchor = arAnchor
        
        // Add the ARAnchor to the session first - this ensures ARKit knows about it
        arView.session.add(anchor: arAnchor)
        
        // Create AnchorEntity from the ARAnchor - this ensures proper coordinate alignment
        // The AnchorEntity will be synchronized via SynchronizationComponent
        let anchor = AnchorEntity(anchor: arAnchor)
        
        // Create a sphere mesh with a visible size (radius reduced by half)
        let sphereMesh = MeshResource.generateSphere(radius: 0.05)
        
        // Create blue material (will be updated by updateSphereColor)
        var material = SimpleMaterial()
        material.color = .init(tint: .blue, texture: nil)
        
        // Create model entity with sphere
        let sphere = ModelEntity(mesh: sphereMesh, materials: [material])
        
        // Add SynchronizationComponent to BOTH the anchor AND the entity
        // This ensures both the anchor's position and the entity are synchronized
        // The anchor's position changes (when moving the sphere) will now sync to clients
        // Set ownership transfer mode to ensure proper synchronization
        var anchorSync = SynchronizationComponent()
        anchorSync.ownershipTransferMode = .autoAccept
        anchor.components[SynchronizationComponent.self] = anchorSync
        
        var sphereSync = SynchronizationComponent()
        sphereSync.ownershipTransferMode = .autoAccept
        sphere.components[SynchronizationComponent.self] = sphereSync
        
        // Add child first, then add anchor to scene
        // This ensures proper synchronization setup
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        
        // Ensure synchronization is properly initialized
        // The anchor position will be synchronized automatically via SynchronizationComponent
        
        self.sphereAnchor = anchor
        self.sphereEntity = sphere
        self.isSphereSynchronized = false // Host creates it, so it's not "synchronized from" anywhere
        
        print("Host: Sphere created at position: \(worldPosition) with SynchronizationComponent")
        DispatchQueue.main.async {
            self.statusMessage = "Sphere placed at tapped location"
        }
        updateSphereColor()
    }
    
    private func setupSphere() {
        // Only host creates the sphere - it will be synced to clients via SynchronizationService
        guard isHostMode else {
            print("Client device: Not creating sphere (will receive from host via sync)")
            return
        }
        
        // Don't create sphere if it already exists (user may have placed it manually)
        if sphereAnchor != nil && sphereEntity != nil {
            print("Host: Sphere already exists, skipping automatic creation at origin")
            // Just ensure synchronization components are properly set
            updateSphereColor()
            return
        }
        
        print("Host device: Creating sphere to sync to clients")
        
        guard let arView = arView else { return }
        
        // Ensure only one sphere exists - remove any existing sphere first
        removeSphere()
        
        // Create an ARAnchor at the origin (0, 0, 0) in the host's coordinate system
        // Using ARAnchor ensures proper coordinate system alignment with ARKit
        // The transform matrix identity means it's at the origin with no rotation
        let arAnchor = ARAnchor(name: "sphereAnchor", transform: matrix_identity_float4x4)
        
        // Store reference to ARAnchor for coordinate updates
        self.sphereARAnchor = arAnchor
        
        // Add the ARAnchor to the session first - this ensures ARKit knows about it
        arView.session.add(anchor: arAnchor)
        
        // Create AnchorEntity from the ARAnchor - this ensures proper coordinate alignment
        // The AnchorEntity will be synchronized via SynchronizationComponent
        let anchor = AnchorEntity(anchor: arAnchor)
        
        // Create a sphere mesh with a visible size (radius reduced by half)
        let sphereMesh = MeshResource.generateSphere(radius: 0.05)
        
        // Create blue material (will be updated by updateSphereColor)
        var material = SimpleMaterial()
        material.color = .init(tint: .blue, texture: nil)
        
        // Create model entity with sphere
        let sphere = ModelEntity(mesh: sphereMesh, materials: [material])
        
        // Add SynchronizationComponent to BOTH the anchor AND the entity
        // This ensures both the anchor's position and the entity are synchronized
        // The anchor's position changes (when moving the sphere) will now sync to clients
        // Set ownership transfer mode to ensure proper synchronization
        var anchorSync = SynchronizationComponent()
        anchorSync.ownershipTransferMode = .autoAccept
        anchor.components[SynchronizationComponent.self] = anchorSync
        
        var sphereSync = SynchronizationComponent()
        sphereSync.ownershipTransferMode = .autoAccept
        sphere.components[SynchronizationComponent.self] = sphereSync
        
        // Add child first, then add anchor to scene
        // This ensures proper synchronization setup
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        
        // Ensure synchronization is properly initialized
        // The anchor position will be synchronized automatically via SynchronizationComponent
        
        self.sphereAnchor = anchor
        self.sphereEntity = sphere
        self.isSphereSynchronized = false // Host creates it, so it's not "synchronized from" anywhere
        
        print("Host: Sphere created at origin (0,0,0) with SynchronizationComponent")
        updateSphereColor()
    }
    
    private func updateSphereColor() {
        guard let sphereEntity = sphereEntity else { return }
        
        // Check if synchronized: peers connected, session running, and collaboration data exchanged
        // For client: also check if sphere anchor exists (received from host)
        let synchronized = !connectedPeers.isEmpty && 
                          isSessionRunning && 
                          (isHostMode || isClientMode) &&
                          hasReceivedCollaborationData &&
                          (isHostMode || sphereAnchor != nil) // Client needs sphere anchor from host
        
        isSynchronized = synchronized
        
        // Update material color
        var material = SimpleMaterial()
        material.color = .init(tint: synchronized ? .green : .blue, texture: nil)
        
        sphereEntity.model?.materials = [material]
    }
    
    func startARSession() {
        guard let arView = arView else {
            statusMessage = "ARView not initialized"
            return
        }
        
        // Check if ARWorldTracking is supported
        guard ARWorldTrackingConfiguration.isSupported else {
            statusMessage = "ARWorldTracking not supported on this device"
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        
        // Use manual environment texturing to avoid material warnings
        // Automatic texturing can trigger the material resolution warning
        config.environmentTexturing = .manual
        
        // Don't enable scene reconstruction as it can cause material warnings
        // Scene reconstruction uses advanced rendering features that may trigger
        // the "Could not resolve material name" warning
        
        // Set world alignment - using .gravity for consistent orientation
        config.worldAlignment = .gravity
        
        // Set up collaborative session
        config.isCollaborationEnabled = true
        
        // Run session with reset to ensure clean state
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        // Remove sphere since anchors were removed
        removeSphere()
        
        // Track session start time (need some mapping time before sending world map)
        sessionStartTime = Date()
        
        isSessionRunning = true
        statusMessage = "AR Session started"
        
        // Host creates sphere when peers connect and world map is sent
        // Client receives sphere via SynchronizationService after world map alignment
        updateSphereColor()
    }
    
    func stopARSession() {
        guard let arView = arView else { return }
        
        arView.session.pause()
        isSessionRunning = false
        sessionStartTime = nil
        statusMessage = "AR Session stopped"
        
        // Remove sphere when session stops
        removeSphere()
        updateSphereColor()
    }
    
    func startAdvertising() {
        guard serviceAdvertiser == nil else {
            statusMessage = "Already advertising"
            return
        }
        
        // Validate service type format (1-15 chars, alphanumeric and hyphens only)
        guard serviceType.count >= 1 && serviceType.count <= 15 else {
            statusMessage = "Invalid service type length"
            return
        }
        
        // Validate service type characters
        let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard serviceType.rangeOfCharacter(from: validCharacters.inverted) == nil else {
            statusMessage = "Invalid service type characters"
            return
        }
        
        print("Starting advertising with service type: '\(serviceType)'")
        print("Expected in Info.plist as: '_\(serviceType)._tcp'")
        
        // Create advertiser with discovery info
        let discoveryInfo = ["device": UIDevice.current.name]
        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        serviceAdvertiser?.delegate = self
        
        // Start advertising with error handling
        serviceAdvertiser?.startAdvertisingPeer()
        
        statusMessage = "Starting advertising..."
    }
    
    func stopAdvertising() {
        serviceAdvertiser?.stopAdvertisingPeer()
        serviceAdvertiser = nil
    }
    
    func startBrowsing() {
        guard serviceBrowser == nil else {
            statusMessage = "Already browsing"
            return
        }
        
        // Validate service type
        guard serviceType.count >= 1 && serviceType.count <= 15 else {
            statusMessage = "Invalid service type"
            return
        }
        
        serviceBrowser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        serviceBrowser?.delegate = self
        serviceBrowser?.startBrowsingForPeers()
        
        statusMessage = "Starting to browse for peers..."
    }
    
    func stopBrowsing() {
        serviceBrowser?.stopBrowsingForPeers()
        serviceBrowser = nil
    }
    
    func startHostMode() {
        // Stop client mode if active
        if isClientMode {
            stopClientMode()
        }
        
        // Start advertising to accept connections
        startAdvertising()
        isHostMode = true
        statusMessage = "Host mode active - waiting for clients to connect"
        
        // Reset flags
        hasReceivedWorldMap = false
        hasSentWorldMap = false
        hasReceivedCollaborationData = false
        
        // If AR session is running and we have peers, send world map
        if isSessionRunning && !connectedPeers.isEmpty {
            attemptToSendWorldMap()
        }
    }
    
    func stopHostMode() {
        stopAdvertising()
        
        if !multipeerSession.connectedPeers.isEmpty {
            multipeerSession.disconnect()
        }
        
        isHostMode = false
        connectedPeers = []
        hasReceivedCollaborationData = false
        hasReceivedWorldMap = false
        hasSentWorldMap = false
        statusMessage = "Host mode stopped"
        
        // Remove sphere when host mode stops
        removeSphere()
        updateSphereColor()
    }
    
    func startClientMode() {
        // Stop host mode if active
        if isHostMode {
            stopHostMode()
        }
        
        // Start browsing to find hosts
        startBrowsing()
        isClientMode = true
        statusMessage = "Client mode active - searching for hosts"
        
        // Remove any local sphere - will receive from host
        removeSphere()
        
        // Reset flags
        hasReceivedWorldMap = false
        hasSentWorldMap = false
        hasReceivedCollaborationData = false
    }
    
    func stopClientMode() {
        stopBrowsing()
        
        if !multipeerSession.connectedPeers.isEmpty {
            multipeerSession.disconnect()
        }
        
        isClientMode = false
        connectedPeers = []
        hasReceivedCollaborationData = false
        hasReceivedWorldMap = false
        hasSentWorldMap = false
        statusMessage = "Client mode stopped"
        
        // Remove sphere when client mode stops
        removeSphere()
        updateSphereColor()
    }
    
    private func attemptToSendWorldMap() {
        // Only send world map if we're in host mode
        guard isHostMode else {
            print("Not sending world map - not in host mode")
            return
        }
        
        // Check if we should send world map
        guard shouldSendWorldMap() else {
            // If session needs more time, schedule a retry
            if let startTime = sessionStartTime, isSessionRunning {
                let sessionDuration = Date().timeIntervalSince(startTime)
                if sessionDuration < 1.0 && !hasSentWorldMap {
                    let waitTime = 1.0 - sessionDuration + 0.5
                    print("Waiting \(waitTime)s for session to gather mapping data before sending world map")
                    DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                        if self.isHostMode && self.shouldSendWorldMap() {
                            self.sendWorldMap()
                        }
                    }
                }
            }
            return
        }
        
        // Small delay to ensure connection is stable, then send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.isHostMode && self.shouldSendWorldMap() {
                self.sendWorldMap()
            }
        }
    }
    
    private func shouldSendWorldMap() -> Bool {
        // Only send if we're in host mode
        guard isHostMode else {
            return false
        }
        
        // Don't send if we've already sent one
        guard !hasSentWorldMap else {
            print("Not sending world map - already sent one")
            return false
        }
        
        // Don't send if session isn't running
        guard isSessionRunning else {
            print("Not sending world map - session not running")
            return false
        }
        
        // Don't send if no peers connected
        guard !connectedPeers.isEmpty else {
            print("Not sending world map - no peers connected")
            return false
        }
        
        // Wait a bit for the session to gather mapping data (at least 1 second)
        if let startTime = sessionStartTime {
            let sessionDuration = Date().timeIntervalSince(startTime)
            guard sessionDuration >= 1.0 else {
                print("Not sending world map - session needs more mapping time (\(sessionDuration)s)")
                return false
            }
        }
        
        return true
    }
    
    private func sendWorldMap() {
        // Only send world map if we're in host mode
        guard isHostMode else {
            print("Skipping world map send - not in host mode")
            return
        }
        
        guard shouldSendWorldMap() else {
            print("Skipping world map send - conditions not met")
            return
        }
        
        guard let arView = arView else { return }
        
        print("Host device sending world map for coordinate alignment")
        
        arView.session.getCurrentWorldMap { worldMap, error in
            guard let map = worldMap else {
                print("Error: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else {
                print("Error: Could not archive world map")
                return
            }
            
            guard self.multipeerSession.connectedPeers.count > 0 else { return }
            
            do {
                try self.multipeerSession.send(data, toPeers: self.multipeerSession.connectedPeers, with: .reliable)
                print("World map sent to \(self.multipeerSession.connectedPeers.count) peer(s) - Host coordinate system established")
                // Mark that we've sent the world map
                DispatchQueue.main.async {
                    self.hasSentWorldMap = true
                    self.hasReceivedCollaborationData = true
                    // Host: Create sphere after sending world map
                    // The sphere will be synchronized to clients via SynchronizationService
                    print("Host: Creating sphere after sending world map")
                    self.setupSphere()
                    self.updateSphereColor()
                }
            } catch {
                print("Error sending world map: \(error.localizedDescription)")
            }
        }
    }
    
    private func receiveWorldMap(_ data: Data) {
        guard let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            print("Error: Could not unarchive world map")
            return
        }
        
        // Mark that we've received a world map (we're now a client, not a host)
        hasReceivedWorldMap = true
        
        print("Client device received world map - aligning to host's coordinate space")
        
        // Remove existing sphere - client will receive sphere from host via SynchronizationService
        removeSphere()
        
        // Reset session with received world map
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        config.isCollaborationEnabled = true
        config.initialWorldMap = worldMap
        config.worldAlignment = .gravity
        
        arView?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        statusMessage = "Receiving world map - waiting for relocalization..."
        
        // Update session start time since we just reset the session
        sessionStartTime = Date()
        
        // Client will receive the sphere from host via SynchronizationService once relocalized
        print("Client: Removed local sphere, will receive synchronized sphere from host")
    }
    
    // MARK: - Server Communication
    func sendFrameToServer() {
        guard let arSession = arSession, let currentFrame = arSession.currentFrame else {
            DispatchQueue.main.async {
                self.statusMessage = "No AR frame available"
            }
            return
        }
        
        guard let sphereARAnchor = sphereARAnchor else {
            DispatchQueue.main.async {
                self.statusMessage = "No sphere anchor found"
            }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Get current interface orientation
            let interfaceOrientation = self.getInterfaceOrientation()
            
            // Extract camera intrinsics
            let camera = currentFrame.camera
            let pixelBuffer = currentFrame.capturedImage
            
            // Get raw image dimensions from pixel buffer
            let rawWidth = CVPixelBufferGetWidth(pixelBuffer)
            let rawHeight = CVPixelBufferGetHeight(pixelBuffer)
            
            // Get UIImage orientation based on interface orientation
            let imageOrientation = self.getImageOrientation(for: interfaceOrientation)
            
            // Transform intrinsics based on orientation
            let intrinsics = camera.intrinsics
            let (adjustedIntrinsics, finalWidth, finalHeight) = self.adjustIntrinsicsForOrientation(
                intrinsics: intrinsics,
                imageWidth: rawWidth,
                imageHeight: rawHeight,
                orientation: interfaceOrientation
            )
            
            let intrinsicsArray = [
                adjustedIntrinsics[0][0], adjustedIntrinsics[0][1], adjustedIntrinsics[0][2],
                adjustedIntrinsics[1][0], adjustedIntrinsics[1][1], adjustedIntrinsics[1][2],
                adjustedIntrinsics[2][0], adjustedIntrinsics[2][1], adjustedIntrinsics[2][2]
            ]
            
            // Calculate camera to sphere extrinsics
            // Camera transform in world coordinates
            let cameraTransform = camera.transform
            
            // Sphere transform in world coordinates
            let sphereTransform = sphereARAnchor.transform
            
            // Calculate relative transform: camera to sphere
            // T_camera_to_sphere = T_sphere^-1 * T_camera
            let sphereTransformInverse = sphereTransform.inverse
            let cameraToSphereTransform = sphereTransformInverse * cameraTransform
            
            // Convert to array (column-major order)
            var extrinsicsArray: [Float] = []
            for col in 0..<4 {
                for row in 0..<4 {
                    extrinsicsArray.append(cameraToSphereTransform[row][col])
                }
            }
            
            // Convert captured image to JPEG with correct orientation
            guard let imageData = self.pixelBufferToJPEG(pixelBuffer: pixelBuffer, orientation: imageOrientation) else {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to convert image to JPEG"
                }
                return
            }
            
            // Create metadata dictionary with adjusted dimensions and intrinsics
            let metadata: [String: Any] = [
                "intrinsics": intrinsicsArray,
                "extrinsics": extrinsicsArray,
                "image_size": imageData.count,
                "image_width": finalWidth,
                "image_height": finalHeight,
                "orientation": self.orientationToString(interfaceOrientation)
            ]
            
            // Send to server
            self.sendToServer(metadata: metadata, imageData: imageData)
        }
    }
    
    // Get current interface orientation
    private func getInterfaceOrientation() -> UIInterfaceOrientation {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return windowScene.interfaceOrientation
        }
        // Fallback to device orientation
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return .portrait // Default fallback
        }
    }
    
    // Convert interface orientation to UIImage orientation
    private func getImageOrientation(for interfaceOrientation: UIInterfaceOrientation) -> UIImage.Orientation {
        switch interfaceOrientation {
        case .portrait:
            return .right // Camera image needs to be rotated 90° clockwise for portrait
        case .portraitUpsideDown:
            return .left // Camera image needs to be rotated 90° counter-clockwise
        case .landscapeLeft:
            return .down // Camera image is already in landscape left orientation
        case .landscapeRight:
            return .up // Camera image needs to be rotated 180°
        default:
            return .right // Default to portrait orientation
        }
    }
    
    // Adjust camera intrinsics matrix based on image orientation
    // ARKit's camera image pixel buffer is typically in landscape orientation (width > height)
    // The intrinsics need to be transformed to match the final oriented image
    private func adjustIntrinsicsForOrientation(
        intrinsics: simd_float3x3,
        imageWidth: Int,
        imageHeight: Int,
        orientation: UIInterfaceOrientation
    ) -> (simd_float3x3, Int, Int) {
        var adjustedIntrinsics = intrinsics
        var finalWidth = imageWidth / 2
        var finalHeight = imageHeight / 2
        
        // Extract intrinsic parameters
        let fx = intrinsics[0][0]  // Focal length in x
        let fy = intrinsics[1][1]  // Focal length in y
        let cx = intrinsics[0][2]  // Principal point x
        let cy = intrinsics[1][2]  // Principal point y
        
        // ARKit's pixel buffer is typically in landscape (width > height)
        // We need to transform intrinsics based on how the image will be displayed
        switch orientation {
        case .portrait, .portraitUpsideDown:
            // Portrait mode: image rotated 90° clockwise
            // Dimensions swap: width becomes height, height becomes width
            finalWidth = imageHeight
            finalHeight = imageWidth
            adjustedIntrinsics = simd_float3x3(
                simd_float3(fx, 0, Float(finalWidth) - cx),
                simd_float3(0, fy, Float(finalHeight) - cy),
                simd_float3(0, 0, 1)
            )
        case .landscapeRight, .landscapeLeft:
            // Landscape right: image rotated 180°
            // Dimensions stay the same, but principal point flips
            finalWidth = imageWidth
            finalHeight = imageHeight
            adjustedIntrinsics = simd_float3x3(
                simd_float3(fx, 0, Float(finalWidth) - cx),
                simd_float3(0, fy, Float(finalHeight) - cy),
                simd_float3(0, 0, 1)
            )
        default:
            // Unknown orientation: use original intrinsics
            adjustedIntrinsics = intrinsics
            finalWidth = imageWidth
            finalHeight = imageHeight
        }
        
        return (adjustedIntrinsics, finalWidth, finalHeight)
    }
    
    // Convert orientation to string for metadata
    private func orientationToString(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeLeft:
            return "landscapeLeft"
        case .landscapeRight:
            return "landscapeRight"
        default:
            return "unknown"
        }
    }
    
    private func pixelBufferToJPEG(pixelBuffer: CVPixelBuffer, orientation: UIImage.Orientation) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        // Use the provided orientation instead of hardcoded .right
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        
        return jpegData
    }
    
    private func sendToServer(metadata: [String: Any], imageData: Data) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: metadata) else {
            DispatchQueue.main.async {
                self.statusMessage = "Failed to serialize metadata"
            }
            return
        }
        
        // Create URL
        guard let url = URL(string: "http://\(serverIP):\(serverPort)/upload_frame") else {
            DispatchQueue.main.async {
                self.statusMessage = "Invalid server URL"
            }
            return
        }
        
        // Create multipart form data request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Build multipart body
        var body = Data()
        
        // Add metadata as JSON
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"metadata\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(jsonData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add image
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        // Send request
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error sending frame: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.statusMessage = "Failed to send: \(error.localizedDescription)"
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.statusMessage = "Invalid server response"
                }
                return
            }
            
            if httpResponse.statusCode == 200 {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String, status == "received" {
                    DispatchQueue.main.async {
                        self.statusMessage = "Frame sent to server successfully"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Frame sent (response received)"
                    }
                }
            } else {
                let errorMessage = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                print("Server error: \(httpResponse.statusCode) - \(errorMessage)")
                DispatchQueue.main.async {
                    self.statusMessage = "Server error: \(httpResponse.statusCode)"
                }
            }
        }
        
        task.resume()
    }
}

// MARK: - ARSessionDelegate
extension ARSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Monitor relocalization status for client devices
        if hasReceivedWorldMap && isClientMode {
            switch frame.worldMappingStatus {
            case .mapped, .extending:
                // Relocalization complete - sphere should be received from host via sync
                if sphereAnchor == nil {
                    // Update status - sphere will appear when synchronized from host
                    DispatchQueue.main.async {
                        self.statusMessage = "Aligned to host - waiting for sphere synchronization"
                        self.hasReceivedCollaborationData = true
                        self.updateSphereColor()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Aligned to host - sphere synchronized"
                        self.hasReceivedCollaborationData = true
                        self.updateSphereColor()
                    }
                }
            case .limited:
                DispatchQueue.main.async {
                    self.statusMessage = "Relocalizing... (limited mapping)"
                }
            case .notAvailable:
                DispatchQueue.main.async {
                    self.statusMessage = "Waiting for relocalization..."
                }
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        // Don't send if no peers connected
        if multipeerSession.connectedPeers.isEmpty {
            return
        }
        
        // Send collaboration data to all connected peers
        // ARSession.CollaborationData conforms to NSSecureCoding and can be archived
        do {
            let encodedData = try NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)
            try multipeerSession.send(encodedData, toPeers: multipeerSession.connectedPeers, with: .reliable)
            // Mark that we've sent collaboration data (session is synchronized)
            DispatchQueue.main.async {
                self.hasReceivedCollaborationData = true
                self.updateSphereColor()
            }
        } catch {
            print("Error sending collaboration data: \(error.localizedDescription)")
        }
    }
}

// MARK: - MCSessionDelegate
extension ARSessionManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.connectedPeers = session.connectedPeers
                
                if self.isHostMode {
                    self.statusMessage = "Client connected: \(peerID.displayName)"
                    print("Host: Client \(peerID.displayName) connected - will send world map and create sphere")
                    // Host: Send world map when client connects
                    if self.isSessionRunning {
                        self.attemptToSendWorldMap()
                    }
                } else if self.isClientMode {
                    self.statusMessage = "Connected to host: \(peerID.displayName)"
                    print("Client: Connected to host \(peerID.displayName) - will receive world map and sphere")
                    // Client: Remove any local sphere (will receive from host)
                    self.removeSphere()
                } else {
                    self.statusMessage = "Connected to \(peerID.displayName)"
                }
                
                self.updateSphereColor()
            case .connecting:
                self.statusMessage = "Connecting to \(peerID.displayName)..."
            case .notConnected:
                self.connectedPeers = session.connectedPeers
                self.statusMessage = "Disconnected from \(peerID.displayName)"
                self.updateSphereColor()
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Try to decode as world map first (world maps are larger and archived)
        if (try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)) != nil {
            // Handle world map
            DispatchQueue.main.async {
                self.receiveWorldMap(data)
            }
            return
        }
        
        // Otherwise, treat as collaboration data
        // ARSession.CollaborationData can be unarchived from Data
        if let collaborationData = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self, from: data) {
            DispatchQueue.main.async {
                guard let arSession = self.arSession else { return }
                arSession.update(with: collaborationData)
                // Mark that we've received collaboration data (session is synchronized)
                self.hasReceivedCollaborationData = true
                
                // Host creates sphere if it doesn't exist yet
                if self.isHostMode && self.sphereAnchor == nil && self.isSessionRunning {
                    print("Host: Creating sphere after receiving collaboration data")
                    self.setupSphere()
                }
                
                self.updateSphereColor()
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used for AR collaboration
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Not used for AR collaboration
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Not used for AR collaboration
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension ARSessionManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            let nsError = error as NSError
            var errorMessage = "Failed to start advertising: \(error.localizedDescription)"
            
            // Provide more specific error messages
            if nsError.domain == "NSNetServicesErrorDomain" || nsError.domain.contains("NetServices") {
                switch nsError.code {
                case -72008:
                    errorMessage = "Service registration failed (code -72008).\nPossible causes:\n1. App needs full reinstall after Info.plist changes\n2. Local network permission not granted\n3. Service type format issue\n\nTry: Delete app, rebuild, reinstall"
                case -72000:
                    errorMessage = "Unknown network error. Check Wi-Fi connection."
                case -72004:
                    errorMessage = "Service name conflict. Restart collaboration."
                case -72007:
                    errorMessage = "Service registration timeout. Check network."
                default:
                    errorMessage = "Network error (\(nsError.code)): \(error.localizedDescription)"
                }
            }
            
            self.statusMessage = errorMessage
            print("Advertising error - Domain: \(nsError.domain), Code: \(nsError.code), Description: \(error.localizedDescription)")
            print("Service type being used: \(self.serviceType)")
            
            // Clean up failed advertiser
            self.serviceAdvertiser = nil
            self.isHostMode = false
        }
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Automatically accept invitations
        DispatchQueue.main.async {
            self.statusMessage = "Received invitation from \(peerID.displayName)"
        }
        invitationHandler(true, multipeerSession)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension ARSessionManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.statusMessage = "Failed to start browsing: \(error.localizedDescription)"
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        // Automatically invite found peers
        browser.invitePeer(peerID, to: multipeerSession, withContext: nil, timeout: 30)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Handle peer lost
    }
}

