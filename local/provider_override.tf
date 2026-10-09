# Copy this into terraform/ as `provider_override.tf` to redirect to LocalStack.
# (Only when practicing locally. Delete before real AWS use.)
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  endpoints {
    s3  = "http://localhost:4566"
    ec2 = "http://localhost:4566"
    iam = "http://localhost:4566"
  }
}
