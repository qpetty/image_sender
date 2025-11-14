from flask import Flask, request, jsonify
from flask_socketio import SocketIO, emit, disconnect
import json
import numpy as np
from datetime import datetime
import os
import threading
import sys
import re
import requests

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*")

# Create directory for received images
RECEIVED_DIR = 'received_images'
os.makedirs(RECEIVED_DIR, exist_ok=True)

# Track frame numbers per client
frame_counters = {}

# Track WebSocket connected clients
connected_clients = set()
last_trigger_time = None

# Map client IP addresses to WebSocket session IDs
# Format: {ip_address: websocket_session_id}
client_ip_to_session_id = {}

# Track pending captures: {capture_id: set of client_ids that should respond}
pending_captures = {}
# Track which clients have responded for each capture: {capture_id: set of client_ids that have responded}
capture_responses = {}
# Track image paths for each capture: {capture_id: list of dicts with image_path, depth_path, metadata_path}
capture_image_paths = {}
# Lock for thread-safe access to capture tracking
capture_lock = threading.Lock()

# URL for the process endpoint
PROCESS_ENDPOINT = 'http://127.0.0.1:8081/process'

def process_camera_data(metadata, image_data, depth_data, client_addr):
    """Process and display camera intrinsics and extrinsics."""
    print("\n" + "="*60)
    print(f"Received AR Frame Data from {client_addr}")
    print("="*60)
    
    # Extract intrinsics
    if 'intrinsics' in metadata:
        intrinsics = metadata['intrinsics']
        print("\nCamera Intrinsics:")
        if isinstance(intrinsics, list):
            # If it's a flat list, reshape to 3x3
            if len(intrinsics) == 9:
                intrinsics_matrix = np.array(intrinsics).reshape(3, 3)
                print(f"  fx: {intrinsics_matrix[0, 0]:.4f}")
                print(f"  fy: {intrinsics_matrix[1, 1]:.4f}")
                print(f"  cx: {intrinsics_matrix[0, 2]:.4f}")
                print(f"  cy: {intrinsics_matrix[1, 2]:.4f}")
                print(f"\nFull matrix:\n{intrinsics_matrix}")
            else:
                print(f"  Raw: {intrinsics}")
        elif isinstance(intrinsics, dict):
            print(f"  fx: {intrinsics.get('fx', 'N/A')}")
            print(f"  fy: {intrinsics.get('fy', 'N/A')}")
            print(f"  cx: {intrinsics.get('cx', 'N/A')}")
            print(f"  cy: {intrinsics.get('cy', 'N/A')}")
        else:
            print(f"  {intrinsics}")
    
    # Extract extrinsics
    if 'extrinsics' in metadata:
        extrinsics = metadata['extrinsics']
        print("\nCamera Extrinsics (4x4 transformation matrix):")
        if isinstance(extrinsics, list):
            # If it's a flat list, reshape to 4x4
            if len(extrinsics) == 16:
                extrinsics_matrix = np.array(extrinsics).reshape(4, 4)
                print(f"\nRotation (3x3):\n{extrinsics_matrix[:3, :3]}")
                print(f"\nTranslation:\n{extrinsics_matrix[:3, 3]}")
                print(f"\nFull matrix:\n{extrinsics_matrix}")
            else:
                print(f"  Raw: {extrinsics}")
        elif isinstance(extrinsics, dict):
            if 'rotation' in extrinsics and 'translation' in extrinsics:
                print(f"  Rotation: {extrinsics['rotation']}")
                print(f"  Translation: {extrinsics['translation']}")
            else:
                print(f"  {extrinsics}")
        else:
            print(f"  {extrinsics}")
    
    # Image info
    print(f"\nImage size: {len(image_data)} bytes")
    if 'image_width' in metadata and 'image_height' in metadata:
        print(f"Image dimensions: {metadata['image_width']}x{metadata['image_height']}")

    depth_info = metadata.get('depth_info') or metadata.get('depth')
    if depth_data:
        print("\nDepth Map:")
        print(f"  Size: {len(depth_data)} bytes")
        if isinstance(depth_info, dict):
            width = depth_info.get('width')
            height = depth_info.get('height')
            bytes_per_row = depth_info.get('bytes_per_row')
            pixel_format = depth_info.get('pixel_format', 'unknown')
            units = depth_info.get('units', 'meters')
            depth_type = depth_info.get('type', 'sceneDepth')
            print(f"  Type: {depth_type}")
            if width and height:
                print(f"  Dimensions: {width}x{height} (bytes/row: {bytes_per_row})")
            print(f"  Format: {pixel_format} | Units: {units}")
            if 'confidence_available' in depth_info:
                print(f"  Confidence map available: {depth_info['confidence_available']}")

            try:
                if width and height:
                    bytes_per_element = depth_info.get('bytes_per_element', 4)
                    expected_elements = width * height
                    expected_size = expected_elements * bytes_per_element

                    if len(depth_data) >= expected_size:
                        depth_array = np.frombuffer(depth_data, dtype=np.float32, count=expected_elements)
                        depth_array = depth_array.reshape((height, width))
                        finite_depth = depth_array[np.isfinite(depth_array)]
                        if finite_depth.size > 0:
                            print(f"  Depth range: {float(finite_depth.min()):.3f}m - {float(finite_depth.max()):.3f}m")
                            print(f"  Depth mean: {float(finite_depth.mean()):.3f}m")
                    else:
                        print(f"  Warning: Depth data size ({len(depth_data)}) smaller than expected ({expected_size})")
            except Exception as exc:
                print(f"  Failed to compute depth statistics: {exc}")
        else:
            print("  Depth metadata unavailable; skipping detailed analysis")
    else:
        print("\nDepth Map: not provided")
    
    print("="*60 + "\n")

@app.route('/upload_frame', methods=['POST'])
def upload_frame():
    """Handle AR frame upload with image and camera data."""
    client_addr = request.remote_addr
    client_id = f"{client_addr}:{request.environ.get('REMOTE_PORT', 'unknown')}"
    
    try:
        # Get JSON metadata from form data
        if 'metadata' not in request.form:
            return jsonify({"status": "error", "message": "No metadata provided"}), 400
        
        metadata = json.loads(request.form.get('metadata'))
        
        # Get image file
        if 'image' not in request.files:
            return jsonify({"status": "error", "message": "No image file provided"}), 400
        
        image_file = request.files['image']
        if image_file.filename == '':
            return jsonify({"status": "error", "message": "Empty image file"}), 400
        
        image_data = image_file.read()
        depth_file = request.files.get('depth')
        depth_data = None

        if depth_file and depth_file.filename:
            depth_data = depth_file.read()
            if not depth_data:
                depth_data = None
        
        # Get WebSocket session ID from IP address mapping (this is the unique Socket.IO session ID)
        websocket_session_id = client_ip_to_session_id.get(client_addr)
        client_device_name = metadata.get("client_id", client_id)
        
        # Use WebSocket session ID if available, otherwise use device name
        identifier_to_use = websocket_session_id if websocket_session_id else client_device_name
        
        # Sanitize client identifier for filesystem use (replace spaces and special chars with underscores)
        sanitized_client_id = re.sub(r'[^\w\-_\.]', '_', identifier_to_use)
        # Remove multiple consecutive underscores
        sanitized_client_id = re.sub(r'_+', '_', sanitized_client_id)
        # Remove leading/trailing underscores
        sanitized_client_id = sanitized_client_id.strip('_')
        # If empty after sanitization, use server client_id
        if not sanitized_client_id:
            sanitized_client_id = client_id.replace(':', '_')
        
        # Get or increment frame number for this client
        # Use WebSocket session ID for tracking if available, otherwise use server client_id
        tracking_id = websocket_session_id if websocket_session_id else client_id
        if tracking_id not in frame_counters:
            frame_counters[tracking_id] = 0
        frame_counters[tracking_id] += 1
        frame_number = frame_counters[tracking_id]
        
        # Generate timestamp
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        
        # Save image with client identifier in filename
        image_filename = f'{RECEIVED_DIR}/frame_{sanitized_client_id}_{frame_number:04d}_{timestamp}.jpg'
        with open(image_filename, 'wb') as f:
            f.write(image_data)
        print(f"[{client_id}] Saved image: {image_filename}")

        depth_filename = None
        if depth_data is not None:
            depth_filename = f'{RECEIVED_DIR}/frame_{sanitized_client_id}_{frame_number:04d}_{timestamp}_depth.bin'
            with open(depth_filename, 'wb') as f:
                f.write(depth_data)
            print(f"[{client_id}] Saved depth map: {depth_filename}")
        
        # Save metadata (include saved file references)
        metadata_to_save = dict(metadata)
        extrinsics = metadata_to_save.get("extrinsics")
        if isinstance(extrinsics, list):
            try:
                extrinsics_matrix = np.array(extrinsics).reshape(4, 4)
                print("update extrinsics before saving")
                metadata_to_save["extrinsics"] = extrinsics_matrix.flatten(order='F').tolist()
            except ValueError:
                # Leave as-is if the list cannot be reshaped (unexpected length)
                pass
        
        # Add server-side client identifier (IP:port) to metadata
        # Client-provided identifier is already in metadata as "client_id"
        server_info = metadata_to_save.get("_server")
        if not isinstance(server_info, dict):
            server_info = {}
        server_info["image_file"] = os.path.basename(image_filename)
        if depth_filename:
            server_info["depth_file"] = os.path.basename(depth_filename)
        server_info["server_client_id"] = client_id  # Server-generated identifier (IP:port)
        metadata_to_save["_server"] = server_info

        metadata_filename = f'{RECEIVED_DIR}/frame_{sanitized_client_id}_{frame_number:04d}_{timestamp}_metadata.json'
        with open(metadata_filename, 'w') as f:
            json.dump(metadata_to_save, f, indent=2)
        print(f"[{client_id}] Saved metadata: {metadata_filename}")
        
        # Process and display camera data
        process_camera_data(metadata_to_save, image_data, depth_data, client_id)
        
        # Check if this frame is part of a pending capture
        capture_id = metadata.get('capture_id')
        if capture_id and capture_id in pending_captures:
            with capture_lock:
                # Mark this client as having responded
                if capture_id not in capture_responses:
                    capture_responses[capture_id] = set()
                capture_responses[capture_id].add(tracking_id)
                
                # Store image paths for this capture (using absolute paths)
                if capture_id not in capture_image_paths:
                    capture_image_paths[capture_id] = []
                
                image_path_data = {
                    'image_path': os.path.abspath(image_filename),
                    'metadata_path': os.path.abspath(metadata_filename)
                }
                if depth_filename:
                    image_path_data['depth_path'] = os.path.abspath(depth_filename)
                capture_image_paths[capture_id].append(image_path_data)
                
                # Check if all expected clients have responded
                expected_clients = pending_captures[capture_id]
                responded_clients = capture_responses[capture_id]
                
                if responded_clients.issuperset(expected_clients):
                    # All clients have responded, call the process endpoint
                    print(f"\n[Capture {capture_id}] All {len(expected_clients)} client(s) have responded. Calling /process endpoint...")
                    
                    # Prepare the request data with image paths
                    request_data = {
                        'capture_id': capture_id,
                        'images': capture_image_paths[capture_id]
                    }
                    
                    try:
                        response = requests.post(PROCESS_ENDPOINT, json=request_data, timeout=10)
                        print(f"[Process] Response status: {response.status_code}")
                        if response.status_code == 200:
                            print(f"[Process] Successfully called /process endpoint with {len(capture_image_paths[capture_id])} image(s)")
                        else:
                            print(f"[Process] Warning: /process returned status {response.status_code}")
                    except requests.exceptions.RequestException as e:
                        print(f"[Process] Error calling /process endpoint: {e}")
                    
                    # Clean up tracking for this capture
                    del pending_captures[capture_id]
                    del capture_responses[capture_id]
                    del capture_image_paths[capture_id]
                else:
                    remaining = len(expected_clients) - len(responded_clients)
                    print(f"[Capture {capture_id}] {len(responded_clients)}/{len(expected_clients)} clients responded ({remaining} remaining)")
        
        return jsonify({
            "status": "received",
            "frame": frame_number,
            "depth_saved": depth_filename is not None,
            "message": "Frame uploaded successfully"
        })
        
    except json.JSONDecodeError as e:
        print(f"[{client_id}] Error parsing JSON metadata: {e}")
        return jsonify({"status": "error", "message": f"Invalid JSON: {str(e)}"}), 400
    except Exception as e:
        print(f"[{client_id}] Error processing frame: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok", "message": "Server is running"})

# WebSocket event handlers
@socketio.on('connect')
def handle_connect():
    """Handle WebSocket client connection."""
    client_id = request.sid
    client_ip = request.remote_addr
    connected_clients.add(client_id)
    # Map IP address to WebSocket session ID
    client_ip_to_session_id[client_ip] = client_id
    print(f"\n[WebSocket] Client connected: {client_id} (IP: {client_ip})")
    print(f"[WebSocket] Total connected clients: {len(connected_clients)}")
    emit('connected', {'status': 'connected', 'client_id': client_id})

@socketio.on('disconnect')
def handle_disconnect():
    """Handle WebSocket client disconnection."""
    client_id = request.sid
    client_ip = request.remote_addr
    connected_clients.discard(client_id)
    # Remove IP mapping if it matches this session
    if client_ip in client_ip_to_session_id and client_ip_to_session_id[client_ip] == client_id:
        del client_ip_to_session_id[client_ip]
    
    # Clean up any pending captures that expected this client
    with capture_lock:
        captures_to_remove = []
        for capture_id, expected_clients in pending_captures.items():
            if client_id in expected_clients:
                expected_clients.discard(client_id)
                # If no clients left to wait for, remove the capture
                if len(expected_clients) == 0:
                    captures_to_remove.append(capture_id)
        
        for capture_id in captures_to_remove:
            if capture_id in pending_captures:
                del pending_captures[capture_id]
            if capture_id in capture_responses:
                del capture_responses[capture_id]
            if capture_id in capture_image_paths:
                del capture_image_paths[capture_id]
    
    print(f"\n[WebSocket] Client disconnected: {client_id}")
    print(f"[WebSocket] Total connected clients: {len(connected_clients)}")

@socketio.on_error_default
def default_error_handler(e):
    """Handle Socket.IO errors."""
    print(f"[WebSocket] Error: {e}")
    import traceback
    traceback.print_exc()

@socketio.on('client_ready')
def handle_client_ready(data):
    """Handle client ready message."""
    client_id = request.sid
    device_name = data.get('device_name', 'Unknown')
    print(f"[WebSocket] Client ready: {device_name} ({client_id})")
    # Ensure client is in connected_clients set
    if client_id not in connected_clients:
        connected_clients.add(client_id)
        print(f"[WebSocket] Added client to connected set: {client_id}")
        print(f"[WebSocket] Total connected clients: {len(connected_clients)}")

def keyboard_input_thread():
    """Background thread to listen for keyboard input and trigger captures."""
    print("\n" + "="*60)
    print("WebSocket Remote Trigger Active")
    print("Press ENTER to trigger frame capture on all connected devices")
    print("="*60 + "\n")
    
    while True:
        try:
            # Read a line from stdin (blocks until Enter is pressed)
            line = sys.stdin.readline()
            if line.strip() == '' or line.strip() == '\n':
                # Enter key pressed
                if len(connected_clients) > 0:
                    global last_trigger_time
                    last_trigger_time = datetime.now()
                    # Create a unique capture ID based on timestamp
                    capture_id = last_trigger_time.strftime('%Y%m%d_%H%M%S_%f')
                    trigger_data = {
                        'timestamp': last_trigger_time.isoformat(),
                        'capture_id': capture_id
                    }
                    print(f"\n[Trigger] Broadcasting capture_frame to {len(connected_clients)} client(s)...")
                    print(f"[Trigger] Capture ID: {capture_id}")
                    print(f"[Trigger] Connected clients: {list(connected_clients)}")
                    
                    # Track which clients should respond to this capture
                    with capture_lock:
                        pending_captures[capture_id] = set(connected_clients)
                        capture_responses[capture_id] = set()
                    
                    # Emit to each connected client individually to ensure all receive it
                    # This is more reliable than relying on broadcast behavior from background threads
                    clients_list = list(connected_clients)  # Create a copy to avoid modification during iteration
                    for client_id in clients_list:
                        socketio.emit('capture_frame', trigger_data, to=client_id)
                        print(f"[Trigger] Sent to client: {client_id}")
                    print(f"[Trigger] Capture command sent at {last_trigger_time.strftime('%H:%M:%S')}")
                    print(f"[Trigger] Waiting for {len(connected_clients)} client(s) to respond...")
                else:
                    print("\n[Trigger] No clients connected. Waiting for connections...")
        except (EOFError, KeyboardInterrupt):
            print("\n[Keyboard] Stopping keyboard input thread...")
            break
        except Exception as e:
            print(f"\n[Keyboard] Error in keyboard thread: {e}")
            import traceback
            traceback.print_exc()

if __name__ == '__main__':
    print(f"Flask server starting on 0.0.0.0:8080")
    print(f"WebSocket server starting on 0.0.0.0:8080")
    print(f"Images will be saved to: {os.path.abspath(RECEIVED_DIR)}")
    print(f"Supports multiple clients simultaneously")
    print(f"Endpoints:")
    print(f"  POST /upload_frame - Upload AR frame with image and metadata")
    print(f"  GET  /health - Health check")
    print(f"  WebSocket /socket.io - WebSocket connection for remote triggering")
    print()
    
    # Start keyboard input thread
    keyboard_thread = threading.Thread(target=keyboard_input_thread, daemon=True)
    keyboard_thread.start()
    
    # Run SocketIO server (which includes Flask)
    socketio.run(app, host='0.0.0.0', port=8080, debug=False, allow_unsafe_werkzeug=True)
