import json
import boto3
from PIL import Image
import io
import os

def resize_image(image_data, max_size=(200, 200)):
    """Resize image to thumbnail size while maintaining aspect ratio"""
    image = Image.open(io.BytesIO(image_data))
    
    # Convert to RGB if necessary (handles PNG with transparency)
    if image.mode in ('RGBA', 'LA', 'P'):
        image = image.convert('RGB')
    
    # Create thumbnail
    image.thumbnail(max_size, Image.Resampling.LANCZOS)
    
    # Save to bytes
    output_buffer = io.BytesIO()
    image.save(output_buffer, format='JPEG', quality=85, optimize=True)
    return output_buffer.getvalue()

def lambda_handler(event, context):
    """Main Lambda function handler"""
    try:
        # For now, we'll test with a manual S3 bucket/key
        bucket_name = os.environ.get('S3_BUCKET', 'your-thumbnail-bucket')
        
        # This will be populated by SQS later, for now it's manual
        source_key = event.get('source_key', 'images/test.jpg')
        
        # Initialize S3 client
        s3_client = boto3.client('s3')
        
        print(f"Processing image: {bucket_name}/{source_key}")
        
        # Download image from S3
        response = s3_client.get_object(Bucket=bucket_name, Key=source_key)
        image_data = response['Body'].read()
        
        # Create thumbnail
        thumbnail_data = resize_image(image_data)
        
        # Generate thumbnail key
        thumbnail_key = source_key.replace('images/', 'thumbnails/')
        if not thumbnail_key.startswith('thumbnails/'):
            thumbnail_key = f"thumbnails/{thumbnail_key}"
            
        # Upload thumbnail to S3
        s3_client.put_object(
            Bucket=bucket_name,
            Key=thumbnail_key,
            Body=thumbnail_data,
            ContentType='image/jpeg'
        )
        
        print(f"Thumbnail created: {thumbnail_key}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Thumbnail created successfully',
                'thumbnail_key': thumbnail_key,
                'original_key': source_key
            })
        }
        
    except Exception as e:
        print(f"Error processing image: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e)
            })
        }

# For local testing
if __name__ == "__main__":
    # Test the resize function locally
    test_event = {
        'source_key': 'images/test.jpg'
    }
    result = lambda_handler(test_event, None)
    print(result)
