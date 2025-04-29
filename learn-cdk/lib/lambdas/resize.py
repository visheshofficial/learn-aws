import os
import json
import boto3
from PIL import Image
from io import BytesIO

s3_client = boto3.client("s3")
PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET_NAME"]


def handler(event, context):
    message = event["Records"][0]["Sns"]["Message"]
    sns_message_json = json.loads(message)

    print("Record as JSON:", json.dumps(sns_message_json["Records"][0]))
    record = sns_message_json["Records"][0]

    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"].replace("%3A", ":").replace("+", " ")

    # Get the image from S3
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        image_content = response["Body"].read()
    except Exception as e:
        print(f"Error getting object from S3: {e}")
        raise Exception("No image data received from S3")

    # Process image using Pillow
    try:
        with Image.open(BytesIO(image_content)) as img:
            # Create a white background of the target size
            background = Image.new("RGB", (800, 600), (255, 255, 255, 255))

            # Resize the image to fit within 800x600 while preserving aspect ratio
            img.thumbnail((800, 600))

            # Calculate position to center the image
            position = ((800 - img.width) // 2, (600 - img.height) // 2)

            # Paste the resized image onto the white background
            background.paste(img, position)

            # Save to buffer
            buffer = BytesIO()
            background.save(buffer, format="JPEG")
            buffer.seek(0)
    except Exception as e:
        print(f"Error processing image: {e}")
        raise e

    # Upload resized image
    resized_key = f"resized-{key}"
    try:
        s3_client.put_object(
            Bucket=PROCESSED_BUCKET,
            Key=resized_key,
            Body=buffer,
            ContentType="image/jpeg",
        )
    except Exception as e:
        print(f"Error uploading processed image: {e}")
        raise e

    return {
        "message": "Image resized successfully",
        "bucket": PROCESSED_BUCKET,
        "key": resized_key,
    }
