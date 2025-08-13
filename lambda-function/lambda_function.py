import json
import boto3
from PIL import Image
import io
import os
import urllib.parse

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
        # Initialize S3 client
        s3_client = boto3.client('s3')
        
        # Handle S3 event
        for record in event['Records']:
            # Get bucket and object key from the S3 event
            bucket_name = record['s3']['bucket']['name']
            source_key = urllib.parse.unquote_plus(record['s3']['object']['key'], encoding='utf-8')
            
            print(f"Processing image: {bucket_name}/{source_key}")
            
            # Skip if not in images/ folder
            if not source_key.startswith('images/'):
                print(f"Skipping file not in images/ folder: {source_key}")
                continue
                
            # Skip if already a thumbnail
            if source_key.startswith('thumbnails/'):
                print(f"Skipping thumbnail file: {source_key}")
                continue
            
            # Download image from S3
            response = s3_client.get_object(Bucket=bucket_name, Key=source_key)
            image_data = response['Body'].read()
            
            # Create thumbnail
            thumbnail_data = resize_image(image_data)
            
            # Generate thumbnail key
            thumbnail_key = source_key.replace('images/', 'thumbnails/')
            
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
                'message': 'Thumbnails created successfully',
                'processed_files': len(event['Records'])
            })
        }
        
    except Exception as e:
        print(f"Error processing image: {str(e)}")
        raise e

# For local testing (backwards compatibility)
if __name__ == "__main__":
    test_event = {
        'Records': [{
            's3': {
                'bucket': {'name': 'test-bucket'},
                'object': {'key': 'images/test.jpg'}
            }
        }]
    }
    result = lambda_handler(test_event, None)
    print(result)