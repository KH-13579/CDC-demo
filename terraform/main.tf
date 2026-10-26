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

# ============================================================================
# 既存 Aurora の Security Group へのルール追加のみ（SG 本体は管理しない）
# ============================================================================
# aws_security_group（SG 本体）ではなく個別の Ingress ルールリソースを使うため、
# 既存の他のルール（EC2 からの 5432 許可など）には一切影響しない。

# Confluent Cloud のフルマネージドコネクタが 5432 へ到達するためのルール。
resource "aws_vpc_security_group_ingress_rule" "confluent_to_aurora" {
  for_each = toset(var.confluent_egress_cidrs)

  security_group_id = var.aurora_security_group_id
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  description       = "mini-cdc-demo: Confluent Cloud managed connector to Aurora"
}

# 自分の PC から psql / ローカル起動したアプリで Aurora に直接繋ぐためのルール。
# README Step 1・3 が終わったら tfvars から消して apply すれば閉じられる。
# グローバル IP は https://checkip.amazonaws.com/ で確認する（テザリング等で変わる点に注意）。
resource "aws_vpc_security_group_ingress_rule" "developer_to_aurora" {
  for_each = toset(var.developer_cidrs)

  security_group_id = var.aurora_security_group_id
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  description       = "mini-cdc-demo: developer workstation to Aurora"
}
