output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "SSH / UI (port 8080) of the Jenkins instance"
}

output "k8s_public_ip" {
  value       = aws_instance.k8s.public_ip
  description = "SSH / app NodePort / Grafana NodePort target"
}

output "s3_artifacts_bucket" {
  value       = aws_s3_bucket.artifacts.bucket
  description = "Bucket name to store Jenkins build artifacts"
}
