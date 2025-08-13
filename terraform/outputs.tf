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
  value       = var.enable_xray_tracing ? "https://${var.aws_region}.console.aws.amazon.com/xray/home?region=${var.aws_region}#/traces" : "X-Ray tracing is disabled"
}

output "deployment_info" {
  description = "Information about the deployment"
  value = {
    lambda_package_size = data.archive_file.lambda_package.output_size
    source_code_hash    = data.archive_file.lambda_package.output_base64sha256
    xray_tracing        = var.enable_xray_tracing ? "enabled" : "disabled"
    custom_metrics      = "enabled"
    dashboard_created   = aws_cloudwatch_dashboard.thumbnail_dashboard.dashboard_name
  }
}