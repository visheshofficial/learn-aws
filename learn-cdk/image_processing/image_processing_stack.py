from aws_cdk import (
    Stack,
    aws_ec2 as ec2,
    aws_lambda as _lambda,
    aws_lambda as lambda_,
    aws_s3 as s3,
    RemovalPolicy,
    Duration,
    CfnOutput,
    aws_sns as sns,
    aws_sns_subscriptions as snss,
    aws_s3_notifications as s3n,
)
from constructs import Construct


class ImageProcessingStack(Stack):

    def __init__(self, scope: Construct, id: str, **kwargs) -> None:
        super().__init__(scope, id, **kwargs)

        # Storage buckets
        upload_bucket = s3.Bucket(
            self,
            "UploadBucket",
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=True,
        )

        processed_bucket = s3.Bucket(
            self,
            "ProcessedBucket",
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=True,
        )

        # Create Pillow Layer
        pillow_layer = lambda_.LayerVersion(
            self,
            "PillowLayer",
            code=lambda_.Code.from_asset("lib/layers/pillow"),
            compatible_runtimes=[lambda_.Runtime.PYTHON_3_13],
            description="Pillow image processing library and dependencies",
        )

        # Image Processing Lambda
        resize_function = _lambda.Function(
            self,
            "ResizeFunction",
            runtime=_lambda.Runtime.PYTHON_3_13,  # Use the appropriate Python runtime
            handler="resize.handler",  # Replace with the actual handler function
            code=_lambda.Code.from_asset("lib/lambdas"),  # Path to your Lambda code
            environment={
                "PROCESSED_BUCKET_NAME": processed_bucket.bucket_name,
            },
            timeout=Duration.seconds(30),
            memory_size=1024,
            layers=[pillow_layer],  # Use the Pillow layer defined earlier
        )

        watermark_function = _lambda.Function(
            self,
            "WatermarkFunction",
            runtime=_lambda.Runtime.PYTHON_3_13,
            handler="watermark.handler",
            code=_lambda.Code.from_asset("lib/lambdas"),
            environment={
                "PROCESSED_BUCKET_NAME": processed_bucket.bucket_name,
            },
            timeout=Duration.seconds(30),
            memory_size=1024,
            layers=[pillow_layer],
            # This Lambda function has a dependency on a third-party API,
            # which is limited to 5 concurrent calls.
            # reserved_concurrent_executions=3
        )

        # Grant necessary permissions
        processed_bucket.grant_read_write(resize_function)
        processed_bucket.grant_read_write(
            watermark_function
        )  # Uncomment if watermarkFunction is defined
        upload_bucket.grant_read(resize_function)
        upload_bucket.grant_read(
            watermark_function
        )  # Uncomment if watermarkFunction is defined

        # Create an SNS topic
        sns_topic = sns.Topic(self, "ImageProcessingTopic")

        upload_bucket.add_event_notification(
            s3.EventType.OBJECT_CREATED, s3n.SnsDestination(sns_topic)
        )

        sns_topic.add_subscription(snss.LambdaSubscription(resize_function))
        sns_topic.add_subscription(snss.LambdaSubscription(watermark_function))

        # Output
        CfnOutput(self, "UploadBucketName", value=upload_bucket.bucket_name)
        CfnOutput(self, "ProcessedBucketName", value=processed_bucket.bucket_name)
