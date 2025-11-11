from flask import Flask, request, jsonify
import json
import numpy as np
from datetime import datetime
import os

app = Flask(__name__)

# Create directory for received images
RECEIVED_DIR = 'received_images'
os.makedirs(RECEIVED_DIR, exist_ok=True)

# Track frame numbers per client
frame_counters = {}

def process_camera_data(metadata, image_data, client_addr):
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
        
        # Get or increment frame number for this client
        if client_id not in frame_counters:
            frame_counters[client_id] = 0
        frame_counters[client_id] += 1
        frame_number = frame_counters[client_id]
        
        # Generate timestamp
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        
        # Save image
        image_filename = f'{RECEIVED_DIR}/frame_{frame_number:04d}_{timestamp}.jpg'
        with open(image_filename, 'wb') as f:
            f.write(image_data)
        print(f"[{client_id}] Saved image: {image_filename}")
        
        # Save metadata
        metadata_filename = f'{RECEIVED_DIR}/frame_{frame_number:04d}_{timestamp}_metadata.json'
        with open(metadata_filename, 'w') as f:
            json.dump(metadata, f, indent=2)
        print(f"[{client_id}] Saved metadata: {metadata_filename}")
        
        # Process and display camera data
        process_camera_data(metadata, image_data, client_id)
        
        return jsonify({
            "status": "received",
            "frame": frame_number,
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

if __name__ == '__main__':
    print(f"Flask server starting on 0.0.0.0:8080")
    print(f"Images will be saved to: {os.path.abspath(RECEIVED_DIR)}")
    print(f"Supports multiple clients simultaneously")
    print(f"Endpoints:")
    print(f"  POST /upload_frame - Upload AR frame with image and metadata")
    print(f"  GET  /health - Health check")
    print()
    app.run(host='0.0.0.0', port=8080, threaded=True, debug=False)
