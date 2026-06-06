import sys
import numpy as np
from PIL import Image

def process_image(img_path, out_path, target_width, target_height):
    img = Image.open(img_path).convert('L') # Grayscale
    img = img.resize((target_width, target_height), Image.Resampling.LANCZOS)
    
    # img array shape is (target_height, target_width)
    img_array = np.array(img, dtype=np.float32)
    
    # Normalize to 0..1
    img_array /= 255.0
    
    # Optional: apply a non-linear scaling (e.g. gamma correction) so faint stars are audible but don't overwhelm
    img_array = np.power(img_array, 2.0)
    
    # Row 0 is top of image (high freq). We want bin 0 in our output to be low freq (bottom of image).
    # So we flip the image vertically.
    img_array = np.flipud(img_array)
    
    # Output needs to be read column by column.
    # Shape after transpose: (target_width, target_height)
    img_col_major = img_array.T
    
    # Save as raw float32
    img_col_major.tofile(out_path)
    print(f"Processed {img_path} -> {out_path} (shape: {img_col_major.shape})")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python preprocess.py <in_image> <out_raw>")
        sys.exit(1)
    
    process_image(sys.argv[1], sys.argv[2], 1000, 83)
