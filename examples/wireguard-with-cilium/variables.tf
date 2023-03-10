# tflint-ignore: terraform_unused_declarations
variable "enable_example" {
  description = "Enable example to test this blueprint"
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "The name of the cluster"
  type        = string 
  default = "demo-wireguard-with-cilium"
}

variable "region" {
  description = "The AWS region"
  type = string
  default = "eu-central-1"
}

variable "kubernetes_version" {
  description = "The kubernetes version"
  type = string
  default = "1.24"
}

variable "creator_email" {
  description = "The email address for the creator"
  type = string
  default = "demo3@weave.works"
}