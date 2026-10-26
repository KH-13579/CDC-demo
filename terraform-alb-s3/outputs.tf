output "alb_dns_name" {
  description = "ミニデモ ALB の DNS 名"
  value       = aws_lb.mini.dns_name
}

output "engineering_url" {
  description = "engineering アプリの URL（ブラウザで開く）"
  value       = "http://${aws_lb.mini.dns_name}/engineering/"
}

output "procurement_url" {
  description = "procurement アプリの URL（ブラウザで開く）"
  value       = "http://${aws_lb.mini.dns_name}/procurement/"
}

output "alb_security_group_id" {
  description = "ミニデモ ALB の Security Group ID"
  value       = aws_security_group.mini_alb.id
}

output "s3_sink_bucket" {
  description = "S3 Sink Connector の書込先バケット名"
  value       = aws_s3_bucket.sink.bucket
}

output "s3_sink_confluent_role_arn" {
  description = "Confluent Cloud Provider Integration の完了画面に貼る IAM Role ARN"
  value       = aws_iam_role.confluent_s3_sink.arn
}
