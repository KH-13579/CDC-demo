# ============================================================================
# 案F: ALB + S3 Sink バケット（検証するときだけ apply する単位）
# ============================================================================
# ../terraform/（Aurora の SG ルール）とは state を分けている。
# 理由: ALB は約 $0.58/日の時間課金なので「検証時だけ apply して destroy」したい。
# 同じ state に入れていると destroy で Aurora の SG ルールまで消え、
# Confluent Cloud のコネクタが Aurora に届かなくなってしまう。

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # 構築メモ の既存リソースと同じタグ体系に揃える（コスト按分・棚卸し用）。
  default_tags {
    tags = {
      Project   = "Confluent-Demo"
      ManagedBy = "terraform"
      Component = "mini-cdc-demo"
    }
  }
}

# IAM Role 用。組織の権限に iam:TagRole が無く、default_tags 付きだと CreateRole が
# AccessDenied（iam:TagRole）になるため、タグを付けないプロバイダを分ける。
provider "aws" {
  alias  = "untagged"
  region = var.aws_region
}

locals {
  mini_prefix = "mini-cdc-demo"

  # 組織の申請ID。組織の規約でIAM Role/Policyの名前は先頭にこれを付ける必要がある。
  # 既存の共有リソース（example-org-alb 等、構築メモ 参照）と同じ値。
  org_prefix = "example-org"
}
