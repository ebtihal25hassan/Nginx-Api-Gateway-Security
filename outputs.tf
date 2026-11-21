output "ec2_public_ip" {
  value = aws_instance.nginx.public_ip
}

output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}