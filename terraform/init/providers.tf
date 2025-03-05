
# AWS Provider
# Region does not matter since this module only creates IAM resources which are global.

provider "aws" {
  region = "us-east-1"
}
