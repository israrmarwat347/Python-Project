resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-key"
  public_key = var.ssh_public_key
}

resource "aws_instance" "jenkins" {
  ami                         = var.ami_id
  instance_type               = var.jenkins_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-jenkins", Role = "jenkins" }
}

resource "aws_instance" "k8s" {
  ami                         = var.ami_id
  instance_type               = var.k8s_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  key_name                    = aws_key_pair.deployer.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-k8s", Role = "k8s" }
}
