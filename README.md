# NGINX Custom Headers & API Gateway Security
 
A small AWS lab I built end to end with Terraform: an NGINX reverse proxy on EC2 that adds secret headers to every request, and an API Gateway that decides whether to let the request through, using a Lambda Authorizer.
 
## Overview
 
The idea is simple. NGINX sits in front and forwards any `/api/` request to API Gateway, adding three custom headers on the way. API Gateway then calls a Lambda Authorizer, which reads those headers and returns allow or deny. Only if the answer is allow does the backend Lambda run.
 
The important rule of this lab: **NGINX never decides anything.** It only forwards and injects headers. The authorization decision belongs to API Gateway.
 
I did not click through the console. Everything here (EC2, Security Group, NGINX setup, API, authorizer, Lambdas, IAM, SSM) is created by one `terraform apply`.
 
## Architecture
 
![Architecture diagram](<img width="1280" height="757" alt="5766928218878316712" src="https://github.com/user-attachments/assets/cd0f8b46-cfef-43ba-9035-27660630991b" />)
 
```
Client -> EC2 (NGINX) -> API Gateway -> Lambda Authorizer -> Lambda users-handler
                              ^
              SSM Parameter Store (token, read by NGINX host at boot)
```
 
NGINX adds these headers to every proxied request:
 
| Header | Meaning | Value used |
|---|---|---|
| `X-Environment` | Environment name | `dev` |
| `X-Student-ID` | My student identifier | set in `terraform.tfvars` |
| `X-Internal-Token` | Shared secret checked by the authorizer | never published |
 
**Security boundary.** The API Gateway URL is public, so anyone can call it directly. That means the token is a shared secret, not proof that the request came through NGINX. Traffic between the client and NGINX is plain HTTP, as the assignment asks. For a real system I would put TLS in front.
 
## What Terraform creates (17 resources)
 
| # | Terraform address | Purpose |
|---|---|---|
| 1 | `aws_apigatewayv2_api.api` | HTTP API `secure-api` |
| 2 | `aws_apigatewayv2_stage.default` | `$default` stage, auto deploy |
| 3 | `aws_apigatewayv2_route.get_users` | Route `GET /users`, protected by the authorizer |
| 4 | `aws_apigatewayv2_integration.users` | Lambda proxy integration |
| 5 | `aws_apigatewayv2_authorizer.header_auth` | Lambda REQUEST authorizer |
| 6 | `aws_lambda_function.users` | Backend Lambda |
| 7 | `aws_lambda_function.authorizer` | Authorizer Lambda (token from env variable) |
| 8 | `aws_lambda_permission.users` | Lets API Gateway invoke the backend |
| 9 | `aws_lambda_permission.authorizer` | Lets API Gateway invoke the authorizer |
| 10 | `aws_iam_role.lambda` | Execution role for both Lambdas |
| 11 | `aws_iam_role_policy_attachment.lambda_logs` | CloudWatch logging |
| 12 | `aws_iam_role.ec2` | Role for the EC2 instance |
| 13 | `aws_iam_role_policy.ec2_ssm` | Read access to one SSM parameter only |
| 14 | `aws_iam_instance_profile.ec2` | Attaches the role to the instance |
| 15 | `aws_ssm_parameter.token` | Token stored as `SecureString` |
| 16 | `aws_security_group.web` | HTTP 80 open, SSH 22 from my IP only |
| 17 | `aws_instance.nginx` | Amazon Linux 2023 `t3.micro`, NGINX installed by `user_data` |
 
Region: `us-east-1`.
 
## Project files
 
```
.
├── main.tf                  # all AWS resources
├── variables.tf             # region, student_id, internal_token, my_ip_cidr
├── outputs.tf               # prints ec2_public_ip and api_url
├── user_data.sh.tpl         # boot script: install NGINX, fetch token, write config
├── nginx/api-proxy.conf     # copy of the NGINX config (placeholders, no secrets)
├── lambda/
│   ├── authorizer/lambda_function.py
│   └── users/lambda_function.py
├── docs/                    # diagram and screenshots
├── .gitignore
├── .terraform.lock.hcl
└── README.md
```
 
## How the pieces work
 
**NGINX.** `location /api/` rewrites `/api/users` to `/users`, proxies to the API Gateway host over HTTPS, and sets the three headers with `proxy_set_header`. Because `proxy_set_header` overwrites whatever the client sent, a client cannot fake these headers through NGINX. It also needs `proxy_ssl_server_name on` and the right `Host` header, otherwise API Gateway refuses the connection.
 
**Authorizer.** The Lambda lowercases the header names, then allows the request only if all three checks pass:
 
| Condition | Result |
|---|---|
| All headers valid | Allow, HTTP 200 |
| `X-Environment` is not `dev` | Deny, HTTP 403 |
| `X-Student-ID` missing or empty | Deny, HTTP 403 |
| `X-Internal-Token` does not match | Deny, HTTP 403 |
| Undefined route | HTTP 404 |
 
The expected token comes from the `INTERNAL_TOKEN` environment variable, and the comparison uses `hmac.compare_digest` so timing cannot leak the secret.
 
**API Gateway settings that matter.**
- The authorizer has no identity sources. If I listed the headers there, API Gateway would answer 401 for a missing header before my Lambda even ran, and the "missing student ID" test would return 401 instead of 403.
- There is no `$default` route, so any path other than `GET /users` returns 404.
- Authorizer caching is off (TTL 0) so every test is evaluated fresh.
**Bonus: token in SSM.** The token is stored as a `SecureString`. At boot, the EC2 instance role reads it and writes it into a root-only NGINX file, so the token is not hardcoded in the NGINX configuration or in this repository.
 
## Prerequisites
 
- Terraform and AWS CLI installed
- AWS credentials configured with `aws configure`
- An IAM user or role allowed to create the resources above
Check which account Terraform will use:
 
```powershell
aws sts get-caller-identity
```
 
## Deploy
 
Create `terraform.tfvars` (it is in `.gitignore`, never commit it):
 
```hcl
student_id     = "YOUR-STUDENT-ID"
internal_token = "a-long-random-secret"
my_ip_cidr     = "YOUR.PUBLIC.IP/32"
```
 
Then:
 
```powershell
terraform init
terraform validate
terraform plan      
terraform apply
terraform output     
```
 
Wait about two minutes after `apply` so the boot script can finish installing NGINX.
 
When I am done with the lab:
 
```powershell
terraform destroy
```
 
## Testing
 
Through NGINX the headers are always correct, so the negative tests go **directly to API Gateway**. This also shows that API Gateway is the one making the decision.
 
```powershell
$api   = "https://<api-id>.execute-api.us-east-1.amazonaws.com/users"
$token = Read-Host "Token"     # keeps the secret out of command history
 
# 1) Valid headers through NGINX
curl.exe -i http://<EC2_PUBLIC_IP>/api/users
 
# 1b) Valid headers directly
curl.exe -i $api -H "X-Environment: dev" -H "X-Student-ID: STU12345" -H "X-Internal-Token: $token"
 
# 2) Invalid environment
curl.exe -i $api -H "X-Environment: prod" -H "X-Student-ID: STU12345" -H "X-Internal-Token: $token"
 
# 3) Missing student ID
curl.exe -i $api -H "X-Environment: dev" -H "X-Internal-Token: $token"
 
# 4) Invalid token
curl.exe -i $api -H "X-Environment: dev" -H "X-Student-ID: STU12345" -H "X-Internal-Token: wrong"
 
# 5) Undefined route
curl.exe -i http://<EC2_PUBLIC_IP>/api/doesnotexist
```
 
### Results
 
These are the status codes I actually got when I ran the tests.
 
| # | Test | Expected | Observed |
|---|---|---|---|
| 1 | Valid headers through NGINX | 200 | 200 |
| 1b | Valid headers directly to API Gateway | 200 | 200 |
| 2 | Invalid environment (`prod`) | 403 | 403 |
| 3 | Missing student ID | 403 | 403 |
| 4 | Invalid token | 403 | 403 |
| 5 | Undefined route | 404 | 404 |
 
## Notes
 
This project was prepared as an educational infrastructure-as-code and API authorization exercise.
 
