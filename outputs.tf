output "website_url" {
  value = "http://${aws_eip.web_ip.public_ip}"
}

output "cdn_url" {
  value = "https://${aws_cloudfront_distribution.cdn.domain_name}/img.jpg"
}
