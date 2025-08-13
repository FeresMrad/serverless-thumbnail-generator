import json
import boto3
from PIL import Image
import io
import os
import urllib.parse
import time
from datetime import datetime
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch boto3 to enable X-Ray tracing
patch_all()

# Initialize clients outside handler for connection reuse
s3_client = boto3.client('s3')
cloudwatch = boto3.client('cloudwatch')

@xray_recorder.capture('resize_image')
def resize_image(image_data, max_size=(200, 200)):
    """Resize image to thumbnail size while maintaining aspect ratio"""
    start_time = time.time()
    
    try:
        image = Image.open(io.BytesIO(image_data))
        original_size = image.size
        
        # Add metadata to X-Ray trace
        xray_recorder.put_metadata('original_size', {
            'width': original_size[0],
            'height': original_size[1]
        })
        
        # Convert to RGB if necessary (handles PNG with transparency)
        if image.mode in ('RGBA', 'LA', 'P'):
            image = image.convert('RGB')
            xray_recorder.put_annotation('converted_to_rgb', True)
        
        # Create thumbnail
        image.thumbnail(max_size, Image.Resampling.LANCZOS)
        final_size = image.size
        
        # Save to bytes
        output_buffer = io.BytesIO()
        image.save(output_buffer, format='JPEG', quality=85, optimize=True)
        thumbnail_data = output_buffer.getvalue()
        
        # Add more metadata
        processing_time = time.time() - start_time
        compression_ratio = len(image_data) / len(thumbnail_data)
        
        xray_recorder.put_metadata('processing_details', {
            'final_size': {'width': final_size[0], 'height': final_size[1]},
            'processing_time_seconds': processing_time,
            'original_size_bytes': len(image_data),
            'thumbnail_size_bytes': len(thumbnail_data),
            'compression_ratio': compression_ratio
        })
        
        xray_recorder.put_annotation('processing_time_ms', int(processing_time * 1000))
        
        return thumbnail_data, {
            'processing_time': processing_time,
            'original_size': original_size,
            'final_size': final_size,
            'compression_ratio': compression_ratio,
            'original_size_bytes': len(image_data),
            'thumbnail_size_bytes': len(thumbnail_data)
        }
        
    except Exception as e:
        xray_recorder.put_annotation('resize_error', str(e))
        print(f"ERROR: Image resize failed: {str(e)}")
        raise

@xray_recorder.capture('upload_thumbnail')
def upload_thumbnail_to_s3(bucket_name, thumbnail_key, thumbnail_data):
    """Upload thumbnail to S3 with tracing"""
    start_time = time.time()
    
    try:
        s3_client.put_object(
            Bucket=bucket_name,
            Key=thumbnail_key,
            Body=thumbnail_data,
            ContentType='image/jpeg',
            Metadata={
                'generated-by': 'thumbnail-lambda',
                'generated-at': datetime.utcnow().isoformat()
            }
        )
        
        upload_time = time.time() - start_time
        xray_recorder.put_annotation('upload_time_ms', int(upload_time * 1000))
        xray_recorder.put_metadata('upload_details', {
            'upload_time_seconds': upload_time,
            'file_size_bytes': len(thumbnail_data)
        })
        
        return upload_time
        
    except Exception as e:
        xray_recorder.put_annotation('upload_error', str(e))
        print(f"ERROR: S3 upload failed: {str(e)}")
        raise

@xray_recorder.capture('download_from_s3')
def download_from_s3(bucket_name, source_key):
    """Download image from S3 with tracing"""
    start_time = time.time()
    
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=source_key)
        image_data = response['Body'].read()
        
        download_time = time.time() - start_time
        xray_recorder.put_annotation('download_time_ms', int(download_time * 1000))
        xray_recorder.put_metadata('download_details', {
            'download_time_seconds': download_time,
            'file_size_bytes': len(image_data)
        })
        
        return image_data, download_time
        
    except Exception as e:
        xray_recorder.put_annotation('download_error', str(e))
        print(f"ERROR: S3 download failed: {str(e)}")
        raise

def send_custom_metrics(metrics_data):
    """Send custom metrics to CloudWatch"""
    try:
        metric_data = []
        
        # Thumbnail generation success metric
        metric_data.append({
            'MetricName': 'ThumbnailsGenerated',
            'Value': 1,
            'Unit': 'Count',
            'Dimensions': [
                {'Name': 'FunctionName', 'Value': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}
            ]
        })
        
        # Processing time metric
        if 'total_processing_time' in metrics_data:
            metric_data.append({
                'MetricName': 'ProcessingTime',
                'Value': metrics_data['total_processing_time'],
                'Unit': 'Seconds',
                'Dimensions': [
                    {'Name': 'FunctionName', 'Value': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}
                ]
            })
        
        # Compression ratio metric
        if 'compression_ratio' in metrics_data:
            metric_data.append({
                'MetricName': 'CompressionRatio',
                'Value': metrics_data['compression_ratio'],
                'Unit': 'None',
                'Dimensions': [
                    {'Name': 'FunctionName', 'Value': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}
                ]
            })
        
        # File size metrics
        if 'original_size_mb' in metrics_data:
            metric_data.append({
                'MetricName': 'OriginalFileSizeMB',
                'Value': metrics_data['original_size_mb'],
                'Unit': 'None',
                'Dimensions': [
                    {'Name': 'FunctionName', 'Value': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}
                ]
            })
        
        # Send metrics in batches (CloudWatch limit is 20 per request)
        cloudwatch.put_metric_data(
            Namespace='ThumbnailGenerator',
            MetricData=metric_data
        )
        
        print(f"INFO: Sent {len(metric_data)} custom metrics to CloudWatch")
        
    except Exception as e:
        print(f"ERROR: Failed to send custom metrics: {str(e)}")
        # Don't fail the entire function if metrics fail

@xray_recorder.capture('lambda_handler')
def lambda_handler(event, context):
    """Main Lambda function handler for SQS events with full observability"""
    function_start_time = time.time()
    
    try:
        # Add trace annotations
        xray_recorder.put_annotation('function_name', context.function_name)
        xray_recorder.put_annotation('function_version', context.function_version)
        xray_recorder.put_annotation('request_id', context.aws_request_id)
        
        processed_files = []
        total_files = 0
        successful_files = 0
        failed_files = 0
        
        print(f"INFO: Processing {len(event['Records'])} SQS records")
        
        # Handle SQS records
        for sqs_record in event['Records']:
            # Parse the SQS message body (contains S3 event)
            s3_event = json.loads(sqs_record['body'])
            
            # Process each S3 record in the message
            for s3_record in s3_event['Records']:
                total_files += 1
                file_start_time = time.time()
                
                # Get bucket and object key from the S3 event
                bucket_name = s3_record['s3']['bucket']['name']
                source_key = urllib.parse.unquote_plus(s3_record['s3']['object']['key'], encoding='utf-8')
                
                print(f"INFO: Processing image {total_files}: {bucket_name}/{source_key}")
                
                # Add file-specific annotations
                xray_recorder.put_annotation('current_file', source_key)
                xray_recorder.put_annotation('bucket_name', bucket_name)
                
                # Skip if not in images/ folder
                if not source_key.startswith('images/'):
                    print(f"INFO: Skipping file not in images/ folder: {source_key}")
                    continue
                    
                # Skip if already a thumbnail
                if source_key.startswith('thumbnails/'):
                    print(f"INFO: Skipping thumbnail file: {source_key}")
                    continue
                
                try:
                    # Download image from S3
                    image_data, download_time = download_from_s3(bucket_name, source_key)
                    
                    # Create thumbnail
                    thumbnail_data, resize_metrics = resize_image(image_data)
                    
                    # Generate thumbnail key
                    thumbnail_key = source_key.replace('images/', 'thumbnails/')
                    
                    # Upload thumbnail to S3
                    upload_time = upload_thumbnail_to_s3(bucket_name, thumbnail_key, thumbnail_data)
                    
                    # Calculate total processing time for this file
                    file_processing_time = time.time() - file_start_time
                    
                    # Prepare metrics data
                    metrics_data = {
                        'total_processing_time': file_processing_time,
                        'compression_ratio': resize_metrics['compression_ratio'],
                        'original_size_mb': resize_metrics['original_size_bytes'] / (1024 * 1024)
                    }
                    
                    # Send custom metrics
                    send_custom_metrics(metrics_data)
                    
                    processed_files.append({
                        'source_key': source_key,
                        'thumbnail_key': thumbnail_key,
                        'processing_time_seconds': file_processing_time,
                        'download_time_seconds': download_time,
                        'resize_time_seconds': resize_metrics['processing_time'],
                        'upload_time_seconds': upload_time,
                        'compression_ratio': resize_metrics['compression_ratio'],
                        'original_size_bytes': resize_metrics['original_size_bytes'],
                        'thumbnail_size_bytes': resize_metrics['thumbnail_size_bytes']
                    })
                    
                    successful_files += 1
                    
                    print(f"SUCCESS: Thumbnail created in {file_processing_time:.2f}s: {thumbnail_key}")
                    print(f"METRICS: Download: {download_time:.2f}s, Resize: {resize_metrics['processing_time']:.2f}s, Upload: {upload_time:.2f}s")
                    print(f"METRICS: Compression: {resize_metrics['compression_ratio']:.2f}x, Original: {resize_metrics['original_size_bytes']} bytes, Thumbnail: {resize_metrics['thumbnail_size_bytes']} bytes")
                    
                except Exception as file_error:
                    failed_files += 1
                    print(f"ERROR: Failed to process file {source_key}: {str(file_error)}")
                    
                    # Send error metric
                    try:
                        cloudwatch.put_metric_data(
                            Namespace='ThumbnailGenerator',
                            MetricData=[{
                                'MetricName': 'ThumbnailErrors',
                                'Value': 1,
                                'Unit': 'Count',
                                'Dimensions': [
                                    {'Name': 'FunctionName', 'Value': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}
                                ]
                            }]
                        )
                    except:
                        pass  # Don't fail if metrics fail
                    
                    # Continue processing other files, don't fail the entire batch
                    continue
        
        # Calculate total function execution time
        total_execution_time = time.time() - function_start_time
        
        # Add final annotations
        xray_recorder.put_annotation('total_files_processed', total_files)
        xray_recorder.put_annotation('successful_files', successful_files)
        xray_recorder.put_annotation('failed_files', failed_files)
        xray_recorder.put_annotation('total_execution_time_ms', int(total_execution_time * 1000))
        
        print(f"SUMMARY: Processed {total_files} files in {total_execution_time:.2f}s - {successful_files} successful, {failed_files} failed")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Thumbnails processed successfully via SQS',
                'processed_files': processed_files,
                'total_processed': successful_files,
                'total_files': total_files,
                'failed_files': failed_files,
                'total_execution_time_seconds': total_execution_time
            })
        }
        
    except Exception as e:
        print(f"ERROR: Fatal error processing SQS messages: {str(e)}")
        xray_recorder.put_annotation('fatal_error', str(e))
        
        # Send error metric
        try:
            cloudwatch.put_metric_data(
                Namespace='ThumbnailGenerator',
                MetricData=[{
                    'MetricName': 'FatalErrors',
                    'Value': 1,
                    'Unit': 'Count',
                    'Dimensions': [
                        {'Name': 'FunctionName', 'Value': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown')}
                    ]
                }]
            )
        except:
            pass
        
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
    
    class MockContext:
        function_name = 'test-function'
        function_version = '$LATEST'
        aws_request_id = 'test-request-id'
    
    result = lambda_handler(test_event, MockContext())
    print(result)