from os import path
from aws_cdk import (
    Stack,
    aws_s3 as s3,
    RemovalPolicy,
    CfnOutput,
    aws_sns as sns,
    aws_kms as kms,
    aws_s3_notifications as s3n,
    aws_sqs as sqs,
    aws_sns_subscriptions as subscriptions,
    aws_lambda as _lambda,
    Duration,
    aws_lambda_event_sources as lambda_events
)
from constructs import Construct


class LearnCdkStack(Stack):

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # The code that defines your stack goes here

        # encryption_key = kms.Key(
        #     self,
        #     "data-encryyption-key",
        # )
        upload_bucket = s3.Bucket(
            self,
            "image_upload_bucket",
            auto_delete_objects=True,
            removal_policy=RemovalPolicy.DESTROY,
            # encryption=s3.BucketEncryption.KMS,
            # encryption_key=encryption_key,
        )

        copy_bucket = s3.Bucket(
            self,
            "image_copy_bucket",
            auto_delete_objects=True,
            removal_policy=RemovalPolicy.DESTROY,
            # encryption=s3.BucketEncryption.KMS,
            # encryption_key=encryption_key,
        )

        upload_queue = sqs.Queue(
            self,
            "upload_queue",
            # encryption=sqs.QueueEncryption.KMS,
            # encryption_master_key=encryption_key,
            visibility_timeout=Duration.seconds(90)
        )
        
        # upload_dlq = sqs.DeadLetterQueue(max_receive_count=5, queue=upload_queue)

        # topic_key = kms.Key(
        #     self,
        #     "topic_key",
        # )
        
        upload_topic = sns.Topic(self, "image_upload_topic", 
                                #  master_key=topic_key
                                 )

        upload_bucket.add_event_notification(
            s3.EventType.OBJECT_CREATED, s3n.SnsDestination(upload_topic)
        )

        upload_topic.add_subscription(subscriptions.SqsSubscription(upload_queue))

        image_copy_fn = _lambda.Function(
            self,
            "Function",
            runtime=_lambda.Runtime.PYTHON_3_13,
            handler="copy_image.handler",
            environment={'DEST_BUCKET':copy_bucket.bucket_name},
            code=_lambda.Code.from_asset('lib/lambdas'),
            description="Copies files from received event to a destination bucket configured.",
            timeout=Duration.seconds(60),
            memory_size=512
        )

        image_copy_fn.add_event_source(lambda_events.SqsEventSource(upload_queue))

        upload_bucket.grant_read(image_copy_fn)
        copy_bucket.grant_write(image_copy_fn)

        CfnOutput(self, "Upload Bucket Name", value=upload_bucket.bucket_name)
        CfnOutput(self, "Upload Topic Name", value=upload_topic.topic_name)
