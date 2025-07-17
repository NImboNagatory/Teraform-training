terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version= ">= 1.2.0"
}

provider "aws" {
  region = "eu-north-1"
}

data "aws_region" "current" {}

resource "random_id" "bucket_id" {
  byte_length = 4
}

resource "aws_s3_bucket" "bucket" {
  bucket = "my-web-assets-bucket-${random_id.bucket_id.hex}"
}

resource "aws_s3_object" "image" {
  bucket       = aws_s3_bucket.bucket.bucket
  key          = "terraform-man-of-automation.png"
  source       = "images/terraform-man-of-automation.png"
  content_type = "image/png"
}


resource "aws_cloudfront_origin_access_control" "oac" {
  name = "s3-oac-access"
  description = "Access control for S3 via CloudFront"
  origin_access_control_origin_type = "s3"
  signing_behavior = "always"
  signing_protocol = "sigv4"
}


resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled = true

  default_cache_behavior {
    viewer_protocol_policy = "redirect-to-https"
    target_origin_id = "S3Origin"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "allow_cloudfront_oac" {
  bucket = aws_s3_bucket.bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "AllowCloudFrontServicePrincipalReadOnly",
        Effect = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action = "s3:GetObject",
        Resource = "${aws_s3_bucket.bucket.arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.cdn.id}"
          }
        }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}


locals {
  ha_group_name = "ha-eip-demo"
  master_priority = 150           
  backup_priority = 100           
}


resource "aws_eip" "ha_vip" {
  vpc = true
  tags = {
    Name = "ha-vip"
  }
}


resource "aws_iam_role" "ec2_s3_role" {
  name = "ec2-s3-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "ec2-s3-access-policy"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.bucket.arn}/*"
      },
      {
        Effect = "Allow",
        Action = [
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress",
          "ec2:DescribeAddresses",
          "ec2:DescribeInstances"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-s3-instance-profile"
  role = aws_iam_role.ec2_s3_role.name
}


resource "aws_security_group" "web_sg" {
  name_prefix = "web-sg"
  description = "Web/SSH + VRRP between HA nodes"

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "VRRP keepalived"
    from_port = 0
    to_port = 0
    protocol = "112"
    self = true
  }

  ingress {
    description = "Allow ICMP ping for diagnostics"
    from_port = -1
    to_port = -1
    protocol = "icmp"
    self = true
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_key_pair" "deployer" {
  key_name = "my-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}

resource "null_resource" "always_run" {
  triggers = {
    timestamp = timestamp()
  }
}

resource "aws_instance" "web1" {
  ami = var.ami
  instance_type = var.instance_type
  key_name = aws_key_pair.deployer.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = templatefile("install_ha_web.sh.tpl", {
    bucket = aws_s3_bucket.bucket.bucket,
    cdn_domain = aws_cloudfront_distribution.cdn.domain_name,
    node_state = "MASTER",
    node_priority = local.master_priority,
    eip_allocation_id = aws_eip.ha_vip.id,
    ha_group_name = local.ha_group_name,
    region = data.aws_region.current.name,
    LOCAL_INSTANCE_ID = ""
  })

  tags = {
    Name    = "WebServer1"
    HAGroup = local.ha_group_name
    Role    = "MASTER"
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by = [null_resource.always_run]
  }
}

resource "aws_instance" "web2" {
  ami = var.ami
  instance_type = var.instance_type
  key_name = aws_key_pair.deployer.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  user_data = templatefile("install_ha_web.sh.tpl", {
    bucket = aws_s3_bucket.bucket.bucket,
    cdn_domain = aws_cloudfront_distribution.cdn.domain_name,
    node_state = "BACKUP",
    node_priority = local.master_priority,
    eip_allocation_id = aws_eip.ha_vip.id,
    ha_group_name = local.ha_group_name,
    region = data.aws_region.current.name,
    LOCAL_INSTANCE_ID = ""
  })

  tags = {
    Name = "WebServer2"
    HAGroup = local.ha_group_name
    Role = "BACKUP"
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by = [null_resource.always_run]
  }
}


output "ha_vip_public_ip" {
  description = "Floating Elastic IP for the HA pair"
  value = aws_eip.ha_vip.public_ip
}

output "web1_private_ip" {
  value = aws_instance.web1.private_ip
}

output "web1_public_ip" {
  value = aws_instance.web1.public_ip
}

output "web2_private_ip" {
  value = aws_instance.web2.private_ip
}

output "web2_public_ip" {
  value = aws_instance.web2.public_ip
}