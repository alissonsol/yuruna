# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Workloads bind these NodePorts; the load balancer exists before any Helm deployment.
locals {
  ingress_ports = {
    http  = { listener = 80, node = 30080 }
    https = { listener = 443, node = 30443 }
  }
}

resource "aws_eip" "frontend" {
  count  = 3
  domain = "vpc"
  tags   = local.tags
}

resource "aws_security_group" "ingress" {
  name_prefix = "${local.name}-ingress-"
  description = "Public HTTP and HTTPS ingress load balancer"
  vpc_id      = module.vpc.vpc_id

  dynamic "ingress" {
    for_each = local.ingress_ports
    content {
      from_port   = ingress.value.listener
      to_port     = ingress.value.listener
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 30080
    to_port     = 30443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = local.tags
}

resource "aws_lb" "ingress" {
  name_prefix                      = "yrn-"
  load_balancer_type               = "network"
  internal                         = false
  ip_address_type                  = "ipv4"
  enable_cross_zone_load_balancing = true
  security_groups                  = [aws_security_group.ingress.id]

  dynamic "subnet_mapping" {
    for_each = { for index in range(3) : index => index }
    content {
      subnet_id     = module.vpc.public_subnets[subnet_mapping.value]
      allocation_id = aws_eip.frontend[subnet_mapping.value].id
    }
  }

  tags = local.tags
}

resource "aws_lb_target_group" "ingress" {
  for_each    = local.ingress_ports
  name_prefix = "yrn-"
  port        = each.value.node
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = module.vpc.vpc_id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  lifecycle { create_before_destroy = true }
  tags = local.tags
}

resource "aws_lb_listener" "ingress" {
  for_each          = local.ingress_ports
  load_balancer_arn = aws_lb.ingress.arn
  port              = each.value.listener
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress[each.key].arn
  }
}

resource "aws_autoscaling_attachment" "ingress" {
  for_each               = local.ingress_ports
  autoscaling_group_name = module.eks.eks_managed_node_groups["default"].node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.ingress[each.key].arn
}

resource "aws_security_group_rule" "ingress_nodes" {
  for_each                 = local.ingress_ports
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = each.value.node
  to_port                  = each.value.node
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = aws_security_group.ingress.id
}

output "frontendIp" {
  description = "First static ingress IPv4 address; frontendIps contains all availability zones."
  value       = aws_eip.frontend[0].public_ip
  depends_on  = [aws_lb.ingress, aws_lb_listener.ingress, aws_autoscaling_attachment.ingress]
}

output "frontendIps" {
  description = "Static ingress IPv4 addresses, one per availability zone."
  value       = aws_eip.frontend[*].public_ip
}

output "hostname" {
  description = "Application ingress DNS name, distinct from the Kubernetes API endpoint."
  value       = aws_lb.ingress.dns_name
}
