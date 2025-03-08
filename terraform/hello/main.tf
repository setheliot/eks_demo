terraform {
  required_providers {
    local = {
      source = "hashicorp/local"
    }
  }
}

# Create a file with "Hello, World!" text
resource "local_file" "hello_file" {
  content  = "Hello, World!"
  filename = "hello.txt"
}


output "filename" {
  value = local_file.hello_file.filename
}

