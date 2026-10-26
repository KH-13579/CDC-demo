# ============================================================================
# 案F: Confluent Cloud S3 Sink Connector の書込先バケット + 認証用 IAM Role
# ============================================================================
# 参照リポジトリ infra/aws/terraform/s3_sink.tf と同じ構成（バージョニング +
# SSE-S3 + パブリックアクセス全ブロック + ACL 無効）。
# S3 Sink Connector 本体は Terraform 管理外で、Confluent Cloud の UI から手動作成する。
#
# 認証方式は IAM Role + Confluent Provider Integration（IAM User + Access Key は使わない）。
# 理由は組織のクラウド利用規約:
#   1. IAM アクセスキーは 2026年8月から新規作成・更新が制限されている
#      （組織の案内を参照）。aws_iam_access_key を新規作成する設計は
#      このポリシーに抵触するため使えない。
#   2. IAM ロール/ポリシーの作成は「組織の申請ID」を名前の先頭に付与し、
#      かつ「許可の境界」として OrgPermissionBoundary を指定した場合のみ許可される。
# 参照リポジトリでも実際に稼働したのはこの Role + Provider Integration 方式
# （docs/09_journal/2026-06-02-demo-readiness-snapshot.md に実物の
# Provider Integration cspi-xxxxx の記載あり）。
#
# なお Confluent は PassRole 対象（EC2/Lambda/ECS Task/EKS/EventBridge Scheduler/EFS）
# のいずれでもない。クロスアカウントの sts:AssumeRole で完結するため、
# 組織の規約の PassRole 許可表とは別の話（対象外）。

resource "aws_s3_bucket" "sink" {
  bucket = var.s3_sink_bucket_name

  # バージョニング有効なので、destroy 時に aws_s3_bucket_versioning が無いと
  # 旧バージョンが残って削除に失敗する。デモ用の使い捨てバケットなので
  # force_destroy で terraform destroy 時に全バージョンをまとめて消す。
  force_destroy = true

  tags = {
    Name    = var.s3_sink_bucket_name
    Purpose = "ConfluentCloud-S3Sink-Archive"
  }
}

# ACL を無効化（オブジェクト所有者をバケット所有者に強制）。コンソールの
# 「ACL 無効（推奨）」に相当する。
resource "aws_s3_bucket_ownership_controls" "sink" {
  bucket = aws_s3_bucket.sink.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "sink" {
  bucket = aws_s3_bucket.sink.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sink" {
  bucket = aws_s3_bucket.sink.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "sink" {
  bucket = aws_s3_bucket.sink.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---- 組織の許可の境界（IAM ロール作成の必須条件） -----------------------
# 組織の既存ポリシーとして事前に用意されている前提。無ければ apply がここで失敗する。
data "aws_iam_policy" "permission_boundary" {
  name = "OrgPermissionBoundary"
}

# ---- Confluent Cloud Provider Integration が AssumeRole する IAM Role ------
# 必要権限は Confluent 公式ドキュメントの S3 Sink Connector requirements に準拠
# https://docs.confluent.io/cloud/current/connectors/cc-s3-sink.html
resource "aws_iam_role" "confluent_s3_sink" {
  provider = aws.untagged

  name                 = "${local.org_prefix}-confluent-s3-sink-role"
  permissions_boundary = data.aws_iam_policy.permission_boundary.arn

  # Principal / ExternalId は Confluent UI が提示する trust policy の値。
  # IAM は存在しない Principal を拒否するため、ダミー値では apply できない。
  # 先に Confluent UI にこのロールの ARN（名前固定なので事前に分かる）を入力し、
  # 返ってきた値を tfvars に入れてから apply する（README Step 8 参照）。
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.confluent_provider_integration_role_arn
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.confluent_provider_integration_external_id
          }
        }
      },
      {
        Effect = "Allow"
        Principal = {
          AWS = var.confluent_provider_integration_role_arn
        }
        Action = "sts:TagSession"
      },
    ]
  })
}

resource "aws_iam_role_policy" "confluent_s3_sink" {
  provider = aws.untagged

  name = "${local.org_prefix}-confluent-s3-sink-policy"
  role = aws_iam_role.confluent_s3_sink.name

  # Confluent Cloud S3 Sink (Provider Integration) 推奨ポリシーと完全一致
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListAllBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets"]
        Resource = ["arn:aws:s3:::*"]
      },
      {
        Sid    = "BucketLevel"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = [aws_s3_bucket.sink.arn]
      },
      {
        Sid    = "ObjectLevel"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:GetObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = ["${aws_s3_bucket.sink.arn}/*"]
      },
    ]
  })
}
