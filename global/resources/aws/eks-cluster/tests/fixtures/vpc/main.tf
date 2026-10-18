# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
variable "name" { type = any }
variable "cidr" { type = any }
variable "azs" { type = any }
variable "private_subnets" { type = any }
variable "public_subnets" { type = any }
variable "enable_nat_gateway" { type = any }
variable "single_nat_gateway" { type = any }
variable "enable_dns_hostnames" { type = any }
variable "enable_flow_log" { type = any }
variable "create_flow_log_cloudwatch_iam_role" { type = any }
variable "create_flow_log_cloudwatch_log_group" { type = any }
variable "public_subnet_tags" { type = any }
variable "private_subnet_tags" { type = any }
variable "tags" { type = any }
output "vpc_id" { value = "vpc-0123456789abcdef0" }
output "private_subnets" { value = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1", "subnet-0123456789abcdef2"] }
output "public_subnets" { value = ["subnet-0123456789abcdef3", "subnet-0123456789abcdef4", "subnet-0123456789abcdef5"] }
