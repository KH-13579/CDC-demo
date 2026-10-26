variable "aws_region" {
  description = "既存リソースがあるリージョン。構築メモ の環境は ap-northeast-1"
  type        = string
  default     = "ap-northeast-1"
}

# ----------------------------------------------------------------------------
# ALB（ミニ専用の新規 ALB。既存共有 ALB は変更しない）
# ----------------------------------------------------------------------------

variable "vpc_id" {
  description = "既存 EC2 / Aurora がある VPC の ID。ALB と Target Group をこの VPC に作る"
  type        = string
}

variable "alb_subnet_ids" {
  description = "ALB を配置するサブネット ID のリスト。ALB は「異なる AZ の 2 サブネット以上」が必須で、インターネット向けにするには Internet Gateway へのルートを持つ（= パブリック）サブネットである必要がある。aws ec2 describe-subnets で AZ とルートテーブルを確認してから設定する"
  type        = list(string)

  validation {
    condition     = length(var.alb_subnet_ids) >= 2
    error_message = "ALB には異なる AZ の 2 サブネット以上が必要です。"
  }
}

variable "ec2_instance_id" {
  description = "アプリを動かす既存 EC2 のインスタンス ID（構築メモ の記録では i-0123456789abcdef0）"
  type        = string
}

variable "ec2_security_group_id" {
  description = "既存 EC2 が実際に使用している Security Group ID。この SG に「ALB SG からの 3101/3102 許可」を追加ルールとして足す（既存ルールは変更しない）"
  type        = string
}

variable "mini_app_allowed_cidrs" {
  description = "ALB の HTTP:80 に接続を許可する送信元 CIDR（自分のグローバル IP や組織のネットワーク）。0.0.0.0/0 は使わない"
  type        = list(string)
}

variable "engineering_port" {
  description = "EC2 上で engineering アプリが listen するポート。既存の epc-* コンテナ（8080 等）と衝突しない値"
  type        = number
  default     = 3101
}

variable "procurement_port" {
  description = "EC2 上で procurement アプリが listen するポート"
  type        = number
  default     = 3102
}

# ----------------------------------------------------------------------------
# S3 Sink
# ----------------------------------------------------------------------------

variable "s3_sink_bucket_name" {
  description = "Confluent Cloud S3 Sink Connector の書込先バケット名。S3 のバケット名はグローバルで一意なので既存と衝突しない名前にする（例: example-mini-cdc-sink）。Confluent クラスターと同じリージョンである必要がある"
  type        = string
}

# IAM User + Access Key は使わない（2026年8月からアクセスキー新規作成が組織の規約で
# 制限されているため）。代わりに IAM Role + Confluent Provider Integration を使う。
# 手順: (1) Confluent Cloud UI で Provider Integration (AWS) を開始し、作成予定のロール ARN
# （arn:aws:iam::<自アカウントID>:role/example-org-confluent-s3-sink-role）を入力
# (2) 提示された trust policy の Principal / ExternalId を下記変数に設定して apply
# (3) Confluent UI に戻って Provider Integration を完了させる（README Step 8 参照）。

variable "confluent_provider_integration_role_arn" {
  description = "Confluent Cloud Provider Integration が AssumeRole 元として使う IAM Role ARN。Confluent UI が提示する trust policy の Principal（例: arn:aws:iam::<Confluentの AWS アカウントID>:role/cspi-xxxxx）"
  type        = string
}

variable "confluent_provider_integration_external_id" {
  description = "Confluent Cloud が AssumeRole 時に渡す ExternalId。Confluent UI が提示する trust policy の sts:ExternalId"
  type        = string
}
