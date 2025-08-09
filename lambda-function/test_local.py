from lambda_function import resize_image
from PIL import Image
import io
import os

def test_resize_locally():
    """Test image resizing without AWS using real image"""
    
    # Check if the image exists
    image_path = 'demo-assets/discord.jpeg'
    if not os.path.exists(image_path):
        print(f"❌ Image not found: {image_path}")
        print("Make sure discord.jpeg is in the demo-assets folder")
        return
    
    # Read the actual Discord image
    with open(image_path, 'rb') as f:
        image_data = f.read()
    
    print(f"Original image size: {len(image_data)} bytes")
    
    # Test our resize function
    thumbnail_data = resize_image(image_data)
    
    print(f"Thumbnail size: {len(thumbnail_data)} bytes")
    print(f"Size reduction: {((len(image_data) - len(thumbnail_data)) / len(image_data) * 100):.1f}%")
    
    # Save thumbnail to see result
    thumbnail_path = 'demo-assets/discord_thumbnail.jpg'
    with open(thumbnail_path, 'wb') as f:
        f.write(thumbnail_data)
    
    print(f"✅ Thumbnail created successfully: {thumbnail_path}")
    
    # Show dimensions for verification
    original = Image.open(image_path)
    thumbnail = Image.open(thumbnail_path)
    
    print(f"Original dimensions: {original.size}")
    print(f"Thumbnail dimensions: {thumbnail.size}")

if __name__ == "__main__":
    test_resize_locally()
