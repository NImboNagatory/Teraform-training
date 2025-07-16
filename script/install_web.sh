#!/bin/bash
sudo apt update
sudo apt install -y nginx
echo "<html><body><h1>Test Page</h1><img src='https://${aws_cloudfront_distribution.cdn.domain_name}/img.jpg'></body></html>" > /var/www/html/index.html
sudo systemctl enable nginx
sudo systemctl restart nginx
