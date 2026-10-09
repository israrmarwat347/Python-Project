resource "aws_security_group" "jenkins" {
  name        = "${var.project}-jenkins-sg"
  description = "SSH from my IP + Jenkins UI"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-jenkins-sg" }
}

resource "aws_security_group" "k8s" {
  name        = "${var.project}-k8s-sg"
  description = "SSH + app NodePort + Grafana NodePort"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Notes app NodePort
  ingress {
    description = "Notes app NodePort"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Grafana NodePort
  ingress {
    description = "Grafana NodePort"
    from_port   = 30030
    to_port     = 30030
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Prometheus NodePort (optional)
  ingress {
    description = "Prometheus NodePort"
    from_port   = 30090
    to_port     = 30090
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # k3s API (so Jenkins can talk to the cluster inside the VPC)
  ingress {
    description = "k3s API from Jenkins SG"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-k8s-sg" }
}
