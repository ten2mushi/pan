import sys
import numpy as np
import pandas as pd
from PIL import Image, ImageDraw, ImageFont, ImageEnhance
import subprocess
import random

def create_crt_overlay(W, H):
    overlay = Image.new('RGBA', (W, H), (0,0,0,0))
    draw = ImageDraw.Draw(overlay)
    # Scanlines
    for y in range(0, H, 3):
        draw.line([(0, y), (W, y)], fill=(0, 0, 0, 60), width=1)
    
    # Vignette
    pixels = overlay.load()
    cx, cy = W/2, H/2
    max_dist = np.sqrt(cx*cx + cy*cy)
    for y in range(H):
        for x in range(W):
            dist = np.sqrt((x-cx)**2 + (y-cy)**2)
            v = (dist / max_dist) ** 2
            alpha = int(v * 180)
            if alpha > 0:
                current_alpha = pixels[x, y][3]
                pixels[x, y] = (0, 0, 0, max(current_alpha, alpha))
    return overlay

def draw_grid(draw, W, H, frame_idx):
    vp_y = int(H * 0.7) # Vanishing point
    # Vertical converging lines
    for x_off in range(-3000, 3000, 150):
        bottom_x = x_off + W/2
        draw.line([(W/2, vp_y), (bottom_x, H)], fill=(255, 0, 127, 20), width=1)
    
    # Horizontal scrolling lines
    z_offset = (frame_idx * 0.03) % 1.0
    for i in range(12):
        z = (i + z_offset) / 12.0
        if z <= 0: continue
        y = vp_y + (H - vp_y) * (z ** 2)
        alpha = int(255 * z)
        draw.line([(0, y), (W, y)], fill=(255, 0, 127, alpha // 4), width=1)

class ParticleSystem:
    def __init__(self):
        self.particles = [] # [x, y, vx, vy, life, max_life, color]
        
    def spawn(self, x, y, count, color):
        for _ in range(count):
            vx = random.uniform(-4, 0) # fly backwards
            vy = random.uniform(-5, 5)
            life = random.uniform(10, 30)
            self.particles.append([x, y, vx, vy, life, life, color])
            
    def update_and_draw(self, draw):
        alive = []
        for p in self.particles:
            p[0] += p[2]
            p[1] += p[3]
            p[2] *= 0.95 # friction
            p[3] += 0.2  # gravity
            p[4] -= 1
            if p[4] > 0:
                alpha = int(255 * (p[4] / p[5]))
                r, g, b = p[6]
                draw.rectangle([p[0], p[1], p[0]+2, p[1]+2], fill=(r,g,b,alpha))
                alive.append(p)
        self.particles = alive

def create_animation(csv_path, audio_path, out_mp4, ticker, period):
    print("Loading data...")
    df = pd.read_csv(csv_path)
    
    # If the preprocessor was updated recently, it has Open/High/Low/Close
    # If it was an old CSV without it, fallback to Price as all 4.
    if 'Open' in df.columns:
        o, h, l, c = df['Open'].values, df['High'].values, df['Low'].values, df['Close'].values
    else:
        o = h = l = c = df['Price'].values
        
    volume = df['Volume'].values
    dates = df['Date'].values
    
    start_date = pd.to_datetime(dates[0]).strftime('%d/%m/%y')
    end_date = pd.to_datetime(dates[-1]).strftime('%d/%m/%y')
    
    # Normalize Volume (log scale)
    log_vol = np.log1p(volume)
    min_v, max_v = np.min(log_vol), np.max(log_vol)
    norm_vol = (log_vol - min_v) / (max_v - min_v + 1e-9)
    
    # Volatility
    volatility = h - l
    min_volat, max_volat = np.min(volatility), np.max(volatility)
    norm_volat = (volatility - min_volat) / (max_volat - min_volat + 1e-9)
    
    W, H = 1280, 720
    fps = 48000.0 / 4096.0
    
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
    
    margin_top, margin_bottom = 120, 80
    margin_x = 60
    min_p, max_p = np.min(l), np.max(h)
    
    usable_W = W - 2 * margin_x
    usable_H = H - margin_top - margin_bottom
    
    # Pre-render the static candlesticks chart
    chart_layer = Image.new('RGBA', (W, H), (0,0,0,0))
    chart_draw = ImageDraw.Draw(chart_layer)
    
    candle_w = max(1, int((usable_W / len(o)) * 0.7))
    
    points = [] # For drawing a faint connecting line underneath
    
    for i in range(len(o)):
        x = margin_x + (i / (len(o) - 1)) * usable_W
        y_o = H - margin_bottom - ((o[i] - min_p) / (max_p - min_p)) * usable_H
        y_h = H - margin_bottom - ((h[i] - min_p) / (max_p - min_p)) * usable_H
        y_l = H - margin_bottom - ((l[i] - min_p) / (max_p - min_p)) * usable_H
        y_c = H - margin_bottom - ((c[i] - min_p) / (max_p - min_p)) * usable_H
        
        points.append((x, y_c))
        
        # Bullish (Up) = Cyan, Bearish (Down) = Magenta
        is_up = c[i] >= o[i]
        color = (0, 255, 255, 200) if is_up else (255, 0, 127, 200)
        glow_color = (0, 255, 255, 50) if is_up else (255, 0, 127, 50)
        
        # Draw high-low wick
        chart_draw.line([(x, y_l), (x, y_h)], fill=color, width=1)
        # Draw open-close body
        top = min(y_o, y_c)
        bot = max(y_o, y_c)
        if abs(bot - top) < 1: bot = top + 1
        
        chart_draw.rectangle([x - candle_w/2, top, x + candle_w/2, bot], fill=color)
        # Add glow
        chart_draw.rectangle([x - candle_w, top - 2, x + candle_w, bot + 2], fill=glow_color)

    # Pre-render CRT overlay
    crt_overlay = create_crt_overlay(W, H)
    
    # Title Font
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Monaco.ttf", size=36)
    except OSError:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", size=36)
        except OSError:
            try:
                font = ImageFont.load_default(size=36)
            except TypeError:
                font = ImageFont.load_default()
                
    title = f"{ticker} [{start_date} - {end_date}]"
    
    particles = ParticleSystem()
    
    for i in range(len(o)):
        frame = Image.new('RGBA', (W, H), color=(15, 15, 21, 255))
        draw = ImageDraw.Draw(frame)
        
        # 1. Draw animated Grid
        draw_grid(draw, W, H, i)
        
        # 2. Add static chart
        frame.alpha_composite(chart_layer)
        
        # 3. Audio-Reactive Playhead & Particles
        x = margin_x + (i / (len(o) - 1)) * usable_W
        y_c = H - margin_bottom - ((c[i] - min_p) / (max_p - min_p)) * usable_H
        
        # Volatility triggers particles
        if norm_volat[i] > 0.4:
            count = int(norm_volat[i] * 15)
            particles.spawn(x, y_c, count, (255, 255, 0)) # Yellow sparks
            
        particles.update_and_draw(draw)
        
        # Playhead width and intensity based on volume
        ph_width = 2 + int(norm_vol[i] * 6)
        ph_alpha = 150 + int(norm_vol[i] * 105)
        
        draw.line([(x, margin_top/2), (x, H - margin_bottom/2)], fill=(0, 255, 255, ph_alpha), width=ph_width)
        
        # 4. Title
        draw.text((margin_x, 40), title, fill=(255, 255, 255, 200), font=font)
        
        # 5. Composite CRT scanlines
        frame.alpha_composite(crt_overlay)
        
        # Write to ffmpeg
        try:
            process.stdin.write(frame.convert('RGB').tobytes())
        except BrokenPipeError:
            break
            
        if i % 100 == 0:
            print(f"Rendered frame {i}/{len(o)}")
            
    process.stdin.close()
    process.wait()
    print(f"Animation saved to {out_mp4}")

if __name__ == "__main__":
    if len(sys.argv) != 6:
        print("Usage: python animate.py <in_csv> <in_wav> <out_mp4> <ticker> <period>")
        sys.exit(1)
        
    create_animation(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
