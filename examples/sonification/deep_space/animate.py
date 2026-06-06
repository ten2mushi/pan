import sys
import numpy as np
from PIL import Image, ImageDraw
import subprocess

def create_animation(img_path, audio_path, out_mp4):
    print("Loading image...")
    original = Image.open(img_path).convert('RGB')
    W = 1000
    H = int(original.height * W / original.width)
    if H % 2 != 0:
        H += 1
    img = original.resize((W, H), Image.Resampling.LANCZOS)
    
    gray_img = img.convert('L')
    gray_array = np.array(gray_img, dtype=np.float32) / 255.0
    gray_array = np.power(gray_array, 2.0)
    
    fps = 48000 / 1024.0
    
    cmd = [
        'ffmpeg', '-y', '-f', 'rawvideo', '-vcodec', 'rawvideo',
        '-s', f'{W}x{H}', '-pix_fmt', 'rgb24', '-r', str(fps),
        '-i', '-', '-i', audio_path,
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '23',
        '-c:a', 'aac', '-b:a', '192k',
        '-pix_fmt', 'yuv420p', '-shortest', out_mp4
    ]
    
    print("Starting render...")
    process = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    
    scale = 80.0
    
    for c in range(W):
        frame = img.copy()
        draw = ImageDraw.Draw(frame)
        
        points = []
        for y in range(H):
            spike = gray_array[y, c] * scale
            points.append((c + spike, y))
            
        draw.line(points, fill='white', width=2)
        
        process.stdin.write(frame.tobytes())
        
        if c % 100 == 0:
            print(f"Rendered frame {c}/{W}")
            
    process.stdin.close()
    process.wait()
    print(f"Animation saved to {out_mp4}")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python animate.py <in_image> <in_wav> <out_mp4>")
        sys.exit(1)
        
    create_animation(sys.argv[1], sys.argv[2], sys.argv[3])
