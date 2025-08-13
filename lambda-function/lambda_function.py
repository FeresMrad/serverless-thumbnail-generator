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
    """Main Lambda function handler for SQS events"""
    try:
        # Initialize S3 client
        s3_client = boto3.client('s3')
        
        processed_files = []
        
        # Handle SQS records
        for sqs_record in event['Records']:
            # Parse the SQS message body (contains S3 event)
            s3_event = json.loads(sqs_record['body'])
            
            # Process each S3 record in the message
            for s3_record in s3_event['Records']:
                # Get bucket and object key from the S3 event
                bucket_name = s3_record['s3']['bucket']['name']
                source_key = urllib.parse.unquote_plus(s3_record['s3']['object']['key'], encoding='utf-8')
                
                print(f"Processing image from SQS: {bucket_name}/{source_key}")
                
                # Skip if not in images/ folder
                if not source_key.startswith('images/'):
                    print(f"Skipping file not in images/ folder: {source_key}")
                    continue
                    
                # Skip if already a thumbnail
                if source_key.startswith('thumbnails/'):
                    print(f"Skipping thumbnail file: {source_key}")
                    continue
                
                try:
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
                    
                    processed_files.append({
                        'source_key': source_key,
                        'thumbnail_key': thumbnail_key
                    })
                    
                    print(f"Thumbnail created successfully: {thumbnail_key}")
                    
                except Exception as file_error:
                    print(f"Error processing file {source_key}: {str(file_error)}")
                    # Continue processing other files, don't fail the entire batch
                    continue
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Thumbnails processed successfully via SQS',
                'processed_files': processed_files,
                'total_processed': len(processed_files)
            })
        }
        
    except Exception as e:
        print(f"Error processing SQS messages: {str(e)}")
        # Re-raise the exception so SQS will retry or send to DLQ
        raise e

# For local testing (backwards compatibility)
if __name__ == "__main__":
    # Test with SQS event format
    test_event = {
        'Records': [{
            'body': json.dumps({
                'Records': [{
                    's3': {
                        'bucket': {'name': 'test-bucket'},
                        'object': {'key': 'images/test.jpg'}
                    }
                }]
            })
        }]
    }
    result = lambda_handler(test_event, None)
    print(result)