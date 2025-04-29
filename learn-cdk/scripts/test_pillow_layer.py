# test_pillow_layer.py
import sys
import os

# Add the layer path to Python's import path
sys.path.append("../lib/layers/pillow/python")

# Now try to import Pillow
try:
    from PIL import Image, ImageDraw, ImageFont

    print("✅ Successfully imported Pillow")

    # Print version to confirm
    print(f"Pillow version: {Image.__version__}")

    # Try some basic Pillow operations
    img = Image.new("RGB", (100, 100), color="red")
    draw = ImageDraw.Draw(img)
    draw.text((10, 10), "Test", fill="white")

    # Save to a temp file to verify it works
    temp_file = "/tmp/test_image.jpg"
    img.save(temp_file)

    # Try to open the saved file
    with Image.open(temp_file) as img2:
        width, height = img2.size
        print(f"✅ Successfully created and opened an image: {width}x{height}")

    print("All tests passed!")

except Exception as e:
    print(f"❌ Error: {str(e)}")
    sys.exit(1)
