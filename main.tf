terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive" }
  }
}

provider "aws" {
  region = var.region
}

# ---------- Lambda: zip the code ----------
data "archive_file" "users" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/users"
  output_path = "${path.module}/users.zip"
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/authorizer"
  output_path = "${path.module}/authorizer.zip"
}

# ---------- Lambda IAM role (shared) ----------
resource "aws_iam_role" "lambda" {
  name = "lab-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---------- Lambda functions ----------
resource "aws_lambda_function" "users" {
  function_name    = "users-handler"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.users.output_path
  source_code_hash = data.archive_file.users.output_base64sha256
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "header-authorizer"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  environment {
    variables = {
      INTERNAL_TOKEN = var.internal_token
    }
  }
}

# ---------- API Gateway (HTTP API) ----------
resource "aws_apigatewayv2_api" "api" {
  name          = "secure-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "users" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.users.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "header_auth" {
  api_id                            = aws_apigatewayv2_api.api.id
  name                              = "header-authorizer"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
  # identity_sources intentionally omitted → missing header gives 403, not 401
}

resource "aws_apigatewayv2_route" "get_users" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "GET /users"
  target             = "integrations/${aws_apigatewayv2_integration.users.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.header_auth.id
}

# no $default route → undefined paths return 404

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

# ---------- Permissions for API Gateway to invoke Lambdas ----------
resource "aws_lambda_permission" "users" {
  statement_id  = "apigw-invoke-users"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.users.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "apigw-invoke-authorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.header_auth.id}"
}

# ---------- Bonus: token in SSM Parameter Store ----------
resource "aws_ssm_parameter" "token" {
  name  = "/lab/internal-token"
  type  = "SecureString"
  value = var.internal_token
}

# ---------- EC2 role (read the token from SSM) ----------
resource "aws_iam_role" "ec2" {
  name = "lab-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_ssm" {
  name = "read-internal-token"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = aws_ssm_parameter.token.arn
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "lab-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------- Security Group ----------
resource "aws_security_group" "web" {
  name        = "lab-nginx-sg"
  description = "HTTP and SSH"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- EC2 + NGINX ----------
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "nginx" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    api_host   = replace(aws_apigatewayv2_api.api.api_endpoint, "https://", "")
    student_id = var.student_id
    region     = var.region
  })
  user_data_replace_on_change = true

  depends_on = [aws_ssm_parameter.token, aws_iam_role_policy.ec2_ssm]

  tags = { Name = "nginx-proxy" }
}