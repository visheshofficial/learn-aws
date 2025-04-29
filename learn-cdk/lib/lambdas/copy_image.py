import os
import boto3
import logging
import json
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """
    Lambda handler function to copy an image from the source bucket to a destination bucket.
    The destination bucket name is taken from the environment variable DEST_BUCKET.
    """
    
    logger.info(f"Received event: ")
    # message=event['Records'][0]['body']

    # logger.info(f"Received event: {json.dumps(message)}")

    # if not destination_bucket:
    #     logger.error("Environment variable DEST_BUCKET is not set")
    #     raise ValueError("Environment variable DEST_BUCKET is not set")

    # for record in event.get("Records", []):
    #     try:
    #          # Extract the SQS message body
    #         message_body = record["body"]
    #         logger.info(f"Processing SQS message body: {message_body}")

    #         # Parse the S3 event from the message body
    #         s3_event = json.loads(message_body)
    #         for s3_record in s3_event.get("Records", []):
    #             source_bucket = s3_record["s3"]["bucket"]["name"]
    #             source_key = s3_record["s3"]["object"]["key"]
    #             logger.info(f"Processing object {source_key} from bucket {source_bucket}")

    #             # Copy the object to the destination bucket
    #             copy_source = {"Bucket": source_bucket, "Key": source_key}
    #             s3_client.copy_object(
    #                 CopySource=copy_source,
    #                 Bucket=destination_bucket,
    #                 Key=source_key,
    #             )
    #             logger.info(
    #                 f"Successfully copied {source_key} from {source_bucket} to {destination_bucket}"
    #             )

    #     except ClientError as e:
    #         logger.error(
    #             f"Failed to copy object {source_key} from {source_bucket} to {destination_bucket}: {e}"
    #         )
    #     except KeyError as e:
    #         logger.error(f"Malformed event record: {e}")
