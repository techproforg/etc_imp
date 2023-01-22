variable "key_storage_bucket" {
    type = string
    default = "apigee-opdk-proj"

}

variable "public_subnet" {
    type    = string
    default = "us-east-1a"
}

variable "ec2_instance_type_name" {
    type    = string
    default = "t2.nano"
}

variable "key_name" {
    type    = string
    default = "testec2.pem"
}

variable "vpc_cidr" {
  type        = string
  description = "The IP range to use for the VPC"
  default     = "172.32.0.0/16"
}

variable "subnet_cidr" {
  type        = string
  description = "The IP range to use for the VPC"
  default     = "172.32.0.0/20"
}

variable "instance_count" {
    type    = number
    default = 5
}

variable "ip_list" {
    type    = list
    default = ["172.32.0.12", "172.32.0.13", "172.32.0.14", "172.32.0.15", "172.32.0.16"]
}

variable "server_ip" {
    type    = string
    default = "172.32.0.11"
}

variable "hostname_list" {
    type    = list
    default = ["n02", "n03", "n04", "n05", "n06"]
}

variable "server_name" {
    type    = string
    default = "n01"
}

variable "etp_filename" {
    type    = string
    default = "exco-qa-1dc-5n-1sn-topology.json"
}
