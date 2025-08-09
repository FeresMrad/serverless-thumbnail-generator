#!/bin/bash

echo "Building Lambda deployment package with Docker..."

# Create clean deployment directory
rm -rf deployment
mkdir deployment

# Copy Lambda function
cp lambda_function.py deployment/

# Use Amazon Linux container to install dependencies
docker run --rm -v "$PWD":/var/task \
  public.ecr.aws/lambda/python:3.13 \
  /bin/bash -c "cd /var/task && pip install -r requirements.txt -t deployment/"

# Create ZIP file
cd deployment
zip -r ../lambda-function.zip .
cd ..

echo "Deployment package created: lambda-function.zip"
