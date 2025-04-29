from aws_cdk import App

from image_processing.image_processing_stack import ImageProcessingStack
from learn_cdk.learn_cdk_stack import LearnCdkStack

app = App()
ImageProcessingStack(app, "ImageProcessingStack", stack_name="Image-Processing-Stack")
# LearnCdkStack(app, "LearnCDKStack")
app.synth()
