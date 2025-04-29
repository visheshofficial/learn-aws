
# Create the directory structure if it doesn't exist
mkdir -p lib/layers/pillow/python

# Install Pillow for Lambda layer
echo "Installing Pillow for AWS Lambda..."
pip install --platform manylinux2014_x86_64 \
    --target=lib/layers/pillow/python \
    --implementation cp \
    --python-version 3.13 \
    --only-binary=:all: --upgrade \
    Pillow

# Check if installation was successful
if [ $? -eq 0 ]; then
    echo "Pillow installation successful!"
    echo "Layer created at: $(pwd)/lib/layers/pillow"
    echo "Layer size: $(du -sh lib/layers/pillow | cut -f1)"
else
    echo "Error: Pillow installation failed!"
    exit 1
fi