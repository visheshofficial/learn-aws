#!/usr/bin/env python3
import os
import sys
import boto3
import uuid
from pathlib import Path

def upload_file():
    # Parse command line arguments
    if len(sys.argv) != 2:
        print("Usage: python upload-image.py <bucketName>")
        sys.exit(1)
    
    UPLOAD_BUCKET_NAME = sys.argv[1]
    
    # Get the file path
    FILE_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "img.png")
    
    # Generate a unique identifier
    unique_id = str(uuid.uuid4())
    
    # Create the object key
    OBJECT_KEY = f"uploads/{unique_id}-{os.path.basename(FILE_PATH)}"
    
    # Create S3 client
    s3_client = boto3.client('s3', region_name='eu-central-1')
    
    try:
        # Open the file and upload to S3
        with open(FILE_PATH, 'rb') as file_data:
            response = s3_client.put_object(
                Bucket=UPLOAD_BUCKET_NAME,
                Key=OBJECT_KEY,
                Body=file_data,
                ContentType='image/png'
            )
        
        # Extract the ETag
        etag = response.get('ETag', '').strip('"')
        
        # Print upload confirmation and details
        image_location = f"https://{UPLOAD_BUCKET_NAME}.s3.amazonaws.com/{OBJECT_KEY}"
        result = {
            "ImageLocation": image_location,
            "Etag": etag
        }
        
        print("File uploaded successfully:", result)
        return result
        
    except Exception as error:
        print(f"Error uploading file: {error}")
        sys.exit(1)

if __name__ == "__main__":
    upload_file()