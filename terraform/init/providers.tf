
# AWS Provider
# Region does not matter since this module only creates IAM resources which are global.

provider "aws" {
  region = "eusc-de-east-1"

  endpoints {
    iam = "https://iam.eusc-de-east-1.amazonaws.eu"
  }
}