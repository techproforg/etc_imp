terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~>3.27"
        }
    }
}

resource aws_vpc "apigee_opdk" {
    cidr_block = var.vpc_cidr
}

resource "aws_internet_gateway" "apigee_opdk" {
    vpc_id      = aws_vpc.apigee_opdk.id
}

resource "aws_subnet" "public" {
    vpc_id                  = aws_vpc.apigee_opdk.id
    availability_zone       = var.public_subnet
    map_public_ip_on_launch = "true"
    cidr_block              = var.subnet_cidr
}

resource "aws_route_table" "public" {
    vpc_id  = aws_vpc.apigee_opdk.id
    route {
        cidr_block  = "0.0.0.0/0"
        gateway_id  = aws_internet_gateway.apigee_opdk.id
    }
}

resource "aws_route_table_association" "public" {
    subnet_id       = aws_subnet.public.id
    route_table_id  = aws_route_table.public.id
}

data "aws_ami" "amazon_2" {
    most_recent = true
    filter { 
        name    = "name"
        values  = ["amzn2-ami-kernel-*-hvm-*-x86_64-gp2"]
    } 
    owners  = ["amazon"]
}

data "aws_ami" "ubuntu" {
    most_recent = true
    filter { 
        name    = "name"
        values  = ["ubuntu-minimal/images/hvm-ssd/ubuntu-focal-20.04-amd64-*"]
    } 
    owners  = ["679593333241"]
}

data "http" "myip" {
    url     = "http://ipv4.icanhazip.com"
}

resource "aws_security_group" "sg" {
    vpc_id      = aws_vpc.apigee_opdk.id
    name        = "public_subnet"
    description = "Connect Public Subnet"

    ingress {
        cidr_blocks = ["${chomp(data.http.myip.response_body)}/32"]
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
    }

    ingress {
        cidr_blocks = ["172.32.0.0/16"]
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "tls_private_key" "pk" {
    algorithm = "RSA"
    rsa_bits  = 4096
}

resource "aws_s3_bucket_object" "file" {
    key     = var.key_name
    bucket  = var.key_storage_bucket
    content = tls_private_key.pk.private_key_pem
}

resource "aws_key_pair" "kp" {
    key_name   = trimsuffix("${var.key_name}", ".pem")
    public_key = tls_private_key.pk.public_key_openssh
    provisioner "local-exec" {
        command = "echo '${tls_private_key.pk.private_key_pem}' > ./testec2.pem"
    }
}

resource "aws_instance" "ec2-nodes" {
    count                   = var.instance_count
    vpc_security_group_ids  = ["${aws_security_group.sg.id}"]
    subnet_id               = aws_subnet.public.id
    ami                     = data.aws_ami.amazon_2.id
#    ami                     = data.aws_ami.ubuntu.id
    instance_type           = var.ec2_instance_type_name
    key_name                = trimsuffix("${var.key_name}", ".pem")
    private_ip              = "${var.ip_list[count.index]}"
    tags = {
        Name = "${var.hostname_list[count.index]}"
    }
}

resource "aws_instance" "ansible-ec2" {
    vpc_security_group_ids  = ["${aws_security_group.sg.id}"]
    subnet_id               = aws_subnet.public.id
    ami                     = data.aws_ami.amazon_2.id
#    ami                     = data.aws_ami.ubuntu.id
    instance_type           = var.ec2_instance_type_name
    key_name                = trimsuffix("${var.key_name}", ".pem")
    private_ip              = "${var.server_ip}"
    depends_on              = [aws_instance.ec2-nodes]
    connection {
        type        = "ssh"
        user        = "ec2-user"
        host        = "${aws_instance.ansible-ec2.public_ip}"
        private_key = "${aws_s3_bucket_object.file.content}"
        timeout     = "1m"
    }

    provisioner "file" {
        source      = "./testec2.pem"
        destination = "/home/ec2-user/testec2.pem"
    }

    provisioner "file" {
        source      = "./ansible.cfg"
        destination = "/tmp/ansible.cfg"
    }

    provisioner "file" {
        source      = "./data/${var.etp_filename}"
        destination = "${var.etp_filename}"
    }

    provisioner "remote-exec" {
        inline = [
            "sudo amazon-linux-extras install ansible2 -y",
            "sudo amazon-linux-extras install nginx1 -y",
            "sudo amazon-linux-extras install epel -y",
            "sudo yum-config-manager --enable epel -y",
            "sudo yum -y update",
            "sudo yum install yum-utils -y",
            "sudo yum install yum-plugin-priorities -y",
            "sudo yum remove libuv -y",
            "sudo yum install libuv -y",
            "sudo yum install nodejs npm -y",
            "sudo yum install git -y",
            "sudo yum install ansible -y",
            "sudo yum install -y gcc-c++ make",
            "mkdir server && cd server",
            "npm install express",
            "sudo echo '[slaves]' >> /tmp/hosts",
            "echo ${format("%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=/home/ec2-user/testec2.pem",aws_instance.ansible-ec2.tags.Name,aws_instance.ansible-ec2.private_ip)} >> /tmp/hosts",
            "for line in ${join(" ", [for instance in aws_instance.ec2-nodes : format("%s,ansible_host=%s,ansible_user=ec2-user,ansible_ssh_private_key_file=/home/ec2-user/testec2.pem",instance.tags.Name,instance.private_ip)])}; do echo $line|tr ',' ' ' >> /tmp/hosts; done",
            "sudo chmod 664 /tmp/hosts",
            "sudo mv /etc/ansible/hosts /etc/ansible/hosts.bkp",
            "sudo mv /tmp/hosts /etc/ansible/hosts",
            "sudo mv /etc/ansible/ansible.cfg /etc/ansible/ansible.cfg.bkp",
            "sudo mv /tmp/ansible.cfg /etc/ansible/ansible.cfg",
            "export NVM_NODEJS_ORG_MIRROR=https://nodejs.org/dist/",
            "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.34.0/install.sh | bash",
            ". ~/.nvm/nvm.sh",
            "nvm install v17.0.0",
            "git clone https://github.com/yuriylesyuk/edge-ops.git",
            "git clone https://github.com/yuriylesyuk/etp.git",
            "npm install -g https://github.com/yuriylesyuk/etp/tarball/master",
            "sudo chmod 600 /home/ec2-user/testec2.pem",
            "cd etp",
            "export OPS_HOME=/home/ec2-user/server/edge-ops/ansible",
            "etp generate diagram /home/ec2-user/${var.etp_filename} /home/ec2-user/${format("%s-diagram.svg",trimsuffix(var.etp_filename, "-topology.json"))}",
            "etp generate portrequest /home/ec2-user/${var.etp_filename} /home/ec2-user/${format("%s-portrequest.csv",trimsuffix(var.etp_filename, "-topology.json"))}",
            "etp generate inventory -u ec2-user -k /home/ec2-user/testec2.pem -d ${trimsuffix(var.etp_filename, "-topology.json")} /home/ec2-user/${var.etp_filename} /home/ec2-user/${format("%s-inventory.html",trimsuffix(var.etp_filename, "-topology.json"))}"
            ]
    }
    tags = {
        Name = "${var.server_name}"
    }
}

#resource "aws_instance" "ansible-ec2" {
#    vpc_security_group_ids  = ["${aws_security_group.sg.id}"]
#    subnet_id               = aws_subnet.public.id
#    ami                     = data.aws_ami.amazon_2.id
#    instance_type           = var.ec2_instance_type_name
#    key_name                = trimsuffix("${var.key_name}", ".pem")
#    depends_on              = [aws_instance.ec2-nodes]
#    connection {
#        type        = "ssh"
#        user        = "ec2-user"
#        host        = "${aws_instance.ansible-ec2.public_ip}"
#        private_key = "${aws_s3_bucket_object.file.content}"
#        timeout     = "1m"
#    }
#    provisioner "file" {
#        source      = "./testec2.pem"
#        destination = "/home/ec2-user/testec2.pem"
#    }
#    provisioner "file" {
#        source      = "./ansible.cfg"
#        destination = "/tmp/ansible.cfg"
#    }
#
#    provisioner "remote-exec" {
#        inline = [
#            "sudo amazon-linux-extras install ansible2 -y",
##            "sudo amazon-linux-extras install nginx1 -y",
#            "sudo amazon-linux-extras install epel -y",
#            "sudo yum -y update",
#            "sudo yum remove libuv -y",
#            "sudo yum install libuv --disableplugin=priorities -y",
#            "sudo yum install nodejs npm --enablerepo=epel -y",
#            "sudo yum install git -y",
#            "sudo yum install ansible -y",
#            "sudo yum install -y gcc-c++ make",
#            "mkdir server && cd server",
#            "npm install express",
#            "sudo echo '[slaves]' >> /tmp/hosts",
#            "b=0;for line in ${join(" ", [for instance in aws_instance.ec2-nodes : format("ansible_host=%s,ansible_user=ec2-user,ansible_ssh_private_key_file=/home/ec2-user/testec2.pem",instance.public_ip)])}; do b=$(($b+1));sudo echo $line|tr ',' ' ' >> /tmp/hosts; done",
#            "sudo chmod 664 /tmp/hosts",
#            "sudo mv /etc/ansible/hosts /etc/ansible/hosts.bkp",
#            "sudo mv /tmp/hosts /etc/ansible/hosts",
#            "sudo mv /etc/ansible/ansible.cfg /etc/ansible/ansible.cfg.bkp",
#            "sudo mv /tmp/ansible.cfg /etc/ansible/ansible.cfg",
#            "export OPS_HOME=/home/ec2-user/server/edge-ops/ansible",
#            "export NVM_NODEJS_ORG_MIRROR=https://nodejs.org/dist/",
#            "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.34.0/install.sh | bash",
#            ". ~/.nvm/nvm.sh",
#            "nvm install v17.0.0",
#            "git clone https://github.com/yuriylesyuk/edge-ops.git",
#            "git clone https://github.com/yuriylesyuk/etp.git"
#            ]
#    }
#    tags = {
#        Name = "ansible-book"
#    }
#}

output "instance_id" {
  description = "ID of the Apigee Server instance"
  value       = aws_instance.ansible-ec2.id
}

output "instance_public_ip" {
  description = "Public IP address of the Apigee Server instance"
  value       = aws_instance.ansible-ec2.public_ip
}

output "aws_ec2_instance_ids" {
  value = "${aws_instance.ec2-nodes.*.id}"
}

output "aws_ec2_instance_public_ips" {
  value = "${aws_instance.ec2-nodes.*.public_ip}"
}

