# ============================================================================
# 案F: ミニデモ専用 ALB（パスベースルーティング）
# ============================================================================
# 既存の共有 ALB（example-org-alb）には触らず、新規 ALB を作る。
#
# 参照リポジトリの alb.tf は「単一リスナー → 単一ターゲットグループ → EC2:8080」の
# 単純転送で、振り分けは EC2 上の nginx が担っていた。こちらは engineering /
# procurement の 2 つの独立プロセスを別ポートで動かすので、ALB のリスナールールで
# 本物のパスベースルーティングを組む。
#
# 重要: ALB にはパスの書き換え（rewrite）機能が無い。/engineering/foo は
# そのまま EC2:3101 に /engineering/foo として届く。そのためアプリ側を
# BASE_PATH=/engineering でマウントしている（app/*/server.js 参照）。
#
# 費用: ap-northeast-1 の ALB は $0.0243/時間 = 約 $0.58/日、約 $17.5/月（+ LCU 課金）。
# 検証しない期間は terraform destroy で消すのが安い。

# ---- Security Group -------------------------------------------------------
# SG 本体は新規作成する（既存 SG は変更しない）。
# Terraform は新規 SG 作成時に AWS デフォルトの「全許可 egress」を削除するため、
# 必要な egress を個別リソースで明示する。
resource "aws_security_group" "mini_alb" {
  name        = "${local.mini_prefix}-alb-sg"
  description = "mini-cdc-demo ALB security group"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.mini_prefix}-alb-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "mini_alb_http" {
  for_each = toset(var.mini_app_allowed_cidrs)

  security_group_id = aws_security_group.mini_alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "mini-cdc-demo: browser to ALB"
}

resource "aws_vpc_security_group_egress_rule" "mini_alb_to_engineering" {
  security_group_id            = aws_security_group.mini_alb.id
  referenced_security_group_id = var.ec2_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.engineering_port
  to_port                      = var.engineering_port
  description                  = "mini-cdc-demo: ALB to EC2 engineering app"
}

resource "aws_vpc_security_group_egress_rule" "mini_alb_to_procurement" {
  security_group_id            = aws_security_group.mini_alb.id
  referenced_security_group_id = var.ec2_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.procurement_port
  to_port                      = var.procurement_port
  description                  = "mini-cdc-demo: ALB to EC2 procurement app"
}

# 既存 EC2 の SG への追加ルール。個別リソースなので既存ルールは無変更。
resource "aws_vpc_security_group_ingress_rule" "ec2_engineering_from_alb" {
  security_group_id            = var.ec2_security_group_id
  referenced_security_group_id = aws_security_group.mini_alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.engineering_port
  to_port                      = var.engineering_port
  description                  = "mini-cdc-demo: ALB to engineering app"
}

resource "aws_vpc_security_group_ingress_rule" "ec2_procurement_from_alb" {
  security_group_id            = var.ec2_security_group_id
  referenced_security_group_id = aws_security_group.mini_alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.procurement_port
  to_port                      = var.procurement_port
  description                  = "mini-cdc-demo: ALB to procurement app"
}

# ---- ALB ------------------------------------------------------------------
resource "aws_lb" "mini" {
  name               = "${local.mini_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.mini_alb.id]
  subnets            = var.alb_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${local.mini_prefix}-alb"
  }
}

# ---- Target Group x2 ------------------------------------------------------
# ヘルスチェックのパスは BASE_PATH 込み（ALB はパスを書き換えないため）。
resource "aws_lb_target_group" "engineering" {
  name        = "${local.mini_prefix}-eng-tg"
  port        = var.engineering_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = "/engineering/healthz"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${local.mini_prefix}-eng-tg"
  }
}

resource "aws_lb_target_group" "procurement" {
  name        = "${local.mini_prefix}-proc-tg"
  port        = var.procurement_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = "/procurement/healthz"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${local.mini_prefix}-proc-tg"
  }
}

resource "aws_lb_target_group_attachment" "engineering" {
  target_group_arn = aws_lb_target_group.engineering.arn
  target_id        = var.ec2_instance_id
  port             = var.engineering_port
}

resource "aws_lb_target_group_attachment" "procurement" {
  target_group_arn = aws_lb_target_group.procurement.arn
  target_id        = var.ec2_instance_id
  port             = var.procurement_port
}

# ---- Listener + Rules ----------------------------------------------------
# デフォルトは 404 固定レスポンス。/engineering* と /procurement* だけを
# それぞれのターゲットグループへ振り分ける。
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.mini.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "mini-cdc-demo: use /engineering/ or /procurement/"
      status_code  = "404"
    }
  }

  tags = {
    Name = "${local.mini_prefix}-listener-http"
  }
}

resource "aws_lb_listener_rule" "engineering" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.engineering.arn
  }

  condition {
    path_pattern {
      # prefix そのもの（/engineering）と配下（/engineering/...）の両方を拾う
      values = ["/engineering", "/engineering/*"]
    }
  }

  tags = {
    Name = "${local.mini_prefix}-rule-engineering"
  }
}

resource "aws_lb_listener_rule" "procurement" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.procurement.arn
  }

  condition {
    path_pattern {
      values = ["/procurement", "/procurement/*"]
    }
  }

  tags = {
    Name = "${local.mini_prefix}-rule-procurement"
  }
}
