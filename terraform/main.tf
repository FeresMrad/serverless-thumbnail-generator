terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "thumbnail-generator"
}

# S3 bucket for images and thumbnails
resource "aws_s3_bucket" "thumbnail_bucket" {
  bucket = "${var.project_name}-bucket-${random_string.bucket_suffix.result}"
}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# S3 bucket versioning
resource "aws_s3_bucket_versioning" "thumbnail_bucket" {
  bucket = aws_s3_bucket.thumbnail_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SQS queue for S3 notifications
resource "aws_sqs_queue" "thumbnail_queue" {
  name                      = "${var.project_name}-thumbnail-queue"
  message_retention_seconds = 1209600 # 14 days
  visibility_timeout_seconds = 300    # 5 minutes (should be >= Lambda timeout)
  
  # Configure redrive policy for DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.thumbnail_dlq.arn
    maxReceiveCount     = 3
  })
}

# Dead Letter Queue for failed messages
resource "aws_sqs_queue" "thumbnail_dlq" {
  name                      = "${var.project_name}-thumbnail-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# SQS queue policy to allow S3 to send messages
resource "aws_sqs_queue_policy" "thumbnail_queue_policy" {
  queue_url = aws_sqs_queue.thumbnail_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.thumbnail_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.thumbnail_bucket.arn
          }
        }
      }
    ]
  })
}

# Build Lambda deployment package with dependencies
resource "null_resource" "lambda_build" {
  triggers = {
    # Rebuild when function code or requirements change
    lambda_code  = filemd5("../lambda-function/lambda_function.py")
    requirements = filemd5("../lambda-function/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<EOF
cd ../lambda-function
echo "Building Lambda deployment package..."

# Create clean deployment directory
rm -rf deployment
mkdir deployment

# Copy Lambda function
cp lambda_function.py deployment/

# Install dependencies using Docker for Linux compatibility
docker run --rm -v "$PWD":/var/task \
  public.ecr.aws/lambda/python:3.13 \
  /bin/bash -c "cd /var/task && pip install -r requirements.txt -t deployment/" 2>/dev/null || \
  python -m pip install -r requirements.txt -t deployment/ --upgrade

echo "Lambda package built successfully"
EOF
  }
}

# Create ZIP file of the complete Lambda package
data "archive_file" "lambda_package" {
  type        = "zip"
  source_dir  = "../lambda-function/deployment"
  output_path = "../lambda-function/lambda-deployment.zip"
  
  depends_on = [null_resource.lambda_build]
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda to access S3
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "${var.project_name}-lambda-s3-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.thumbnail_bucket.arn}/*"
        ]
      }
    ]
  })
}

# IAM policy for Lambda to access SQS
resource "aws_iam_role_policy" "lambda_sqs_policy" {
  name = "${var.project_name}-lambda-sqs-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          aws_sqs_queue.thumbnail_queue.arn,
          aws_sqs_queue.thumbnail_dlq.arn
        ]
      }
    ]
  })
}

# IAM policy for Lambda CloudWatch Logs (Basic Execution Role)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# IAM policy for X-Ray tracing
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
  role       = aws_iam_role.lambda_role.name
}

# IAM policy for Lambda to send custom CloudWatch metrics
resource "aws_iam_role_policy" "lambda_cloudwatch_metrics" {
  name = "${var.project_name}-lambda-cloudwatch-metrics"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "ThumbnailGenerator"
          }
        }
      }
    ]
  })
}

# Lambda function with X-Ray tracing enabled
resource "aws_lambda_function" "thumbnail_generator" {
  filename      = data.archive_file.lambda_package.output_path
  function_name = "${var.project_name}-thumbnail-generator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.13"
  timeout       = 60  # Increased for better tracing
  memory_size   = 512

  # Detect code changes automatically
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  # Enable X-Ray tracing
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.thumbnail_bucket.bucket
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_s3_policy,
    aws_iam_role_policy.lambda_sqs_policy,
    aws_iam_role_policy.lambda_cloudwatch_metrics,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_xray,
    data.archive_file.lambda_package,
  ]
}

# Lambda event source mapping for SQS
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.thumbnail_queue.arn
  function_name    = aws_lambda_function.thumbnail_generator.arn
  batch_size       = 1
  enabled          = true
}

# S3 bucket notification to send to SQS
resource "aws_s3_bucket_notification" "thumbnail_trigger" {
  bucket = aws_s3_bucket.thumbnail_bucket.id

  queue {
    queue_arn     = aws_sqs_queue.thumbnail_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "images/"
  }

  depends_on = [aws_sqs_queue_policy.thumbnail_queue_policy]
}

# CloudWatch Dashboard for monitoring
resource "aws_cloudwatch_dashboard" "thumbnail_dashboard" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["ThumbnailGenerator", "ThumbnailsGenerated", "FunctionName", aws_lambda_function.thumbnail_generator.function_name],
            [".", "ThumbnailErrors", ".", "."],
            [".", "FatalErrors", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Thumbnail Generation Success/Error Rate"
          period  = 300
          stat    = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["ThumbnailGenerator", "ProcessingTime", "FunctionName", aws_lambda_function.thumbnail_generator.function_name]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Average Processing Time"
          period  = 300
          stat    = "Average"
          yAxis = {
            left = {
              min = 0
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 6
        height = 6

        properties = {
          metrics = [
            ["ThumbnailGenerator", "CompressionRatio", "FunctionName", aws_lambda_function.thumbnail_generator.function_name]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Compression Ratio"
          period  = 300
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 12
        width  = 6
        height = 6

        properties = {
          metrics = [
            ["ThumbnailGenerator", "OriginalFileSizeMB", "FunctionName", aws_lambda_function.thumbnail_generator.function_name]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Original File Size (MB)"
          period  = 300
          stat    = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.thumbnail_generator.function_name],
            [".", "Invocations", ".", "."],
            [".", "Errors", ".", "."],
            [".", "Throttles", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Lambda Function Metrics"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 24
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfVisibleMessages", "QueueName", aws_sqs_queue.thumbnail_queue.name],
            [".", "NumberOfMessagesSent", ".", "."],
            [".", "NumberOfMessagesReceived", ".", "."],
            [".", "NumberOfMessagesDeleted", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "SQS Queue Metrics"
          period  = 300
        }
      }
    ]
  })
}

# CloudWatch Log Group with retention
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.thumbnail_generator.function_name}"
  retention_in_days = 14
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.project_name}-high-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ThumbnailErrors"
  namespace           = "ThumbnailGenerator"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "This metric monitors thumbnail generation error rate"
  
  dimensions = {
    FunctionName = aws_lambda_function.thumbnail_generator.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${var.project_name}-lambda-high-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Average"
  threshold           = "30000"  # 30 seconds
  alarm_description   = "This metric monitors lambda function duration"
  
  dimensions = {
    FunctionName = aws_lambda_function.thumbnail_generator.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "sqs_dlq_messages" {
  alarm_name          = "${var.project_name}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfVisibleMessages"
  namespace           = "AWS/SQS"
  period              = "300"
  statistic           = "Average"
  threshold           = "0"
  alarm_description   = "This metric monitors messages in the dead letter queue"
  
  dimensions = {
    QueueName = aws_sqs_queue.thumbnail_dlq.name
  }
}

# Outputs
output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.thumbnail_bucket.bucket
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.thumbnail_generator.function_name
}

output "sqs_queue_url" {
  description = "URL of the SQS queue"
  value       = aws_sqs_queue.thumbnail_queue.url
}

output "sqs_dlq_url" {
  description = "URL of the Dead Letter Queue"
  value       = aws_sqs_queue.thumbnail_dlq.url
}

output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.thumbnail_dashboard.dashboard_name}"
}

output "xray_traces_url" {
  description = "URL to X-Ray traces"
  value       = "https://${var.aws_region}.console.aws.amazon.com/xray/home?region=${var.aws_region}#/traces"
}

output "deployment_info" {
  description = "Information about the deployment"
  value = {
    lambda_package_size = data.archive_file.lambda_package.output_size
    source_code_hash    = data.archive_file.lambda_package.output_base64sha256
    xray_tracing        = "enabled"
    custom_metrics      = "enabled"
    dashboard_created   = aws_cloudwatch_dashboard.thumbnail_dashboard.dashboard_name
  }
}