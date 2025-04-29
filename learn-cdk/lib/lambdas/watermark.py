import os
import json
import boto3
from PIL import Image, ImageDraw, ImageFont
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
        # Open the image
        with Image.open(BytesIO(image_content)) as img:
            # Create a copy of the image to work with
            watermarked = img.copy()

            # Create a drawing context
            draw = ImageDraw.Draw(watermarked)

            # Use default font since custom fonts might not be available in Lambda
            try:
                # Try to use a system font if available
                font = ImageFont.truetype("arial.ttf", 80)
            except IOError:
                # Fallback to default font if the specific one isn't available
                font = ImageFont.load_default()

            # Add watermark text
            watermark_text = "Watermark"
            text_position = (40, 40)  # Top-left corner with padding

            # Draw the text with a light gray color similar to #d1d5db
            draw.text(text_position, watermark_text, font=font, fill=(209, 213, 219))

            # Save to buffer
            buffer = BytesIO()
            if watermarked.mode == "RGBA":
                # Convert RGBA to RGB to remove the alpha channel
                watermarked = watermarked.convert("RGB")
            watermarked.save(buffer, format="JPEG")
            buffer.seek(0)

    except Exception as e:
        print(f"Error processing image: {e}")
        raise e

    # Upload watermarked image
    watermarked_key = f"watermarked-{key}"
    try:
        s3_client.put_object(
            Bucket=PROCESSED_BUCKET,
            Key=watermarked_key,
            Body=buffer,
            ContentType="image/jpeg",
        )
    except Exception as e:
        print(f"Error uploading processed image: {e}")
        raise e

    return {
        "message": "Watermark added successfully",
        "bucket": PROCESSED_BUCKET,
        "key": watermarked_key,
    }
