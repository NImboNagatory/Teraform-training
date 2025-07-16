
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version = ">= 1.2.0"
}

resource "aws_instance" "web" {
  count         = 2
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name

  user_data = file("script/install_web.sh")

  tags = {
    Name = "web-server-${count.index}"
  }
}


resource "aws_eip" "web_ip" {
  instance = aws_instance.web1.id
}

resource "aws_s3_bucket" "bucket" {
  bucket = "my-web-assets-bucket-${random_id.bucket_id.hex}"
}

resource "random_id" "bucket_id" {
  byte_length = 4
}

resource "aws_s3_bucket_object" "image" {
  bucket = aws_s3_bucket.bucket.bucket
  key = "img.jpg"
  source = "img.jpg"
  content_type = "image/jpeg"
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id   = "S3Origin"
  }
  enabled = true

  default_cache_behavior {
    viewer_protocol_policy = "redirect-to-https"
    target_origin_id = "S3Origin"

    allowed_methods = ["GET", "HEAD"]
    cached_methods = ["GET", "HEAD"]

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


