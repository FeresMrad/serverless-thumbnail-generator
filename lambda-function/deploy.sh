#!/bin/bash

echo "Building Lambda deployment package..."

# Create clean deployment directory
rm -rf deployment
mkdir deployment

# Copy Lambda function
cp lambda_function.py deployment/

# Install dependencies - remove platform restrictions for now
python -m pip install -r requirements.txt -t deployment/ --upgrade

# Create ZIP file
cd deployment
zip -r ../lambda-function.zip .
cd ..

echo "Deployment package created: lambda-function.zip"

# Show what's in the package
echo "Package contents:"
unzip -l lambda-function.zip | head -10
echo "..."
unzip -l lambda-function.zip | grep -i pil | head -5