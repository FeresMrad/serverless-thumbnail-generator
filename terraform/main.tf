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
    status = var.enable_versioning ? "Enabled" : "Disabled"
  }
}

# SQS queue for S3 notifications
resource "aws_sqs_queue" "thumbnail_queue" {
  name                       = "${var.project_name}-thumbnail-queue"
  message_retention_seconds  = var.sqs_message_retention_days * 86400
  visibility_timeout_seconds = var.sqs_visibility_timeout
  
  # Configure redrive policy for DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.thumbnail_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

# Dead Letter Queue for failed messages
resource "aws_sqs_queue" "thumbnail_dlq" {
  name                      = "${var.project_name}-thumbnail-dlq"
  message_retention_seconds = var.sqs_message_retention_days * 86400
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
  count      = var.enable_xray_tracing ? 1 : 0
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
  runtime       = var.lambda_runtime
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size

  # Detect code changes automatically
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  # Enable X-Ray tracing conditionally
  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  environment {
    variables = {
      S3_BUCKET            = aws_s3_bucket.thumbnail_bucket.bucket
      THUMBNAIL_MAX_WIDTH  = var.thumbnail_max_size.width
      THUMBNAIL_MAX_HEIGHT = var.thumbnail_max_size.height
      THUMBNAIL_QUALITY    = var.thumbnail_quality
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_s3_policy,
    aws_iam_role_policy.lambda_sqs_policy,
    aws_iam_role_policy.lambda_cloudwatch_metrics,
    aws_iam_role_policy_attachment.lambda_basic,
    data.archive_file.lambda_package,
  ]
}

# Lambda event source mapping for SQS
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.thumbnail_queue.arn
  function_name    = aws_lambda_function.thumbnail_generator.arn
  batch_size       = 1  # Keep this hardcoded - architectural decision for image processing
  enabled          = true
}

# S3 bucket notification to send to SQS
resource "aws_s3_bucket_notification" "thumbnail_trigger" {
  bucket = aws_s3_bucket.thumbnail_bucket.id

  queue {
    queue_arn     = aws_sqs_queue.thumbnail_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "images/"  # Keep hardcoded - core design decision
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
  retention_in_days = var.log_retention_days
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
  threshold           = var.error_rate_threshold
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
  threshold           = var.lambda_duration_threshold_ms
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
  threshold           = "0"  # Keep hardcoded - you always want to know about DLQ messages
  alarm_description   = "This metric monitors messages in the dead letter queue"
  
  dimensions = {
    QueueName = aws_sqs_queue.thumbnail_dlq.name
  }
}