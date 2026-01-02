output "alb_dns_name" {
  description = "Application Load Balancer DNS Name"
  value = (
    length(kubernetes_ingress_v1.ingress_alb.status) > 0 &&
    length(kubernetes_ingress_v1.ingress_alb.status[0].load_balancer) > 0 &&
    length(kubernetes_ingress_v1.ingress_alb.status[0].load_balancer[0].ingress) > 0
  ) ? kubernetes_ingress_v1.ingress_alb.status[0].load_balancer[0].ingress[0].hostname : "ALB is still provisioning"
}
