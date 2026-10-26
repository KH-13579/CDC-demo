variable "aws_region" {
  description = "既存リソースがあるリージョン。構築メモ の環境は ap-northeast-1"
  type        = string
  default     = "ap-northeast-1"
}

variable "aurora_security_group_id" {
  description = "Aurora クラスターが実際に使用している Security Group ID（例: sg-xxxxxxxx）。ALB 用 SG とは別なので、AWS コンソールか aws rds describe-db-clusters で Aurora 自身の VpcSecurityGroups を確認してから設定する"
  type        = string
}

variable "confluent_egress_cidrs" {
  description = "Confluent Cloud の Egress IP リスト（Cluster Settings > Networking で取得）。/32 形式で指定する（例: [\"18.xxx.xxx.xxx/32\"]）"
  type        = list(string)
  default     = []
}

variable "developer_cidrs" {
  description = "自分の PC から Aurora:5432 に直接接続するために許可するグローバル IP（/32）。ローカル動作確認が済んだら空リストにして apply すれば閉じられる"
  type        = list(string)
  default     = []
}
