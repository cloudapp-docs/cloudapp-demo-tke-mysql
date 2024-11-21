# 这里定义用到的密码

resource "random_password" "db" {
  length           = 16
  override_special = "_+-&=!@#$%^*()"
}

resource "random_password" "cvm" {
  length           = 16
  override_special = "_+-&=!@#$%^*()"
}

# 这里声明容器集群，查看文档：https://cloud.tencent.com/document/product/1689/90552
resource "tencentcloud_kubernetes_cluster" "tke-cluster" {
  availability_zone   = var.app_target.subnet.zone
  vpc_id              = var.app_target.vpc.id
  subnet_ids          = [var.app_target.subnet.id]
  cluster_cidr        = var.cluster_cidr
  cluster_os          = "tlinux2.4(tkernel4)x86_64"
  cluster_os_type     = "GENERAL"
  cluster_ipvs        = true
  cluster_deploy_type = "MANAGED_CLUSTER"
  network_type        = "GR"
  container_runtime   = "containerd"

  # 后续按规模计算
  cluster_level           = "L20"
  cluster_max_pod_num     = 64
  cluster_max_service_num = 1024

  worker_config {
    password                   = random_password.cvm.result
    availability_zone          = var.app_target.subnet.zone
    subnet_id                  = var.app_target.subnet.id
    img_id                     = var.app_cvm_image.image_id
    instance_type              = var.app_cvm.instance_type
    public_ip_assigned         = false
    internet_max_bandwidth_out = 0
    security_group_ids         = [var.app_sg.security_group.id]
    cam_role_name              = var.cloudapp_cam_role

    instance_charge_type                    = var.charge_type == "PREPAID" ? "PREPAID" : "POSTPAID_BY_HOUR"
    instance_charge_type_prepaid_period     = var.charge_perpaid_period
    instance_charge_type_prepaid_renew_flag = var.charge_perpaid_auto_renew == true ? "NOTIFY_AND_AUTO_RENEW" : "NOTIFY_AND_MANUAL_RENEW"

    count = 1
  }

  labels = {
    "node" : "coding"
  }
}

# 这里声明 mysql，查看文档：https://cloud.tencent.com/document/product/1689/90566

resource "tencentcloud_mysql_instance" "mysql" {
  availability_zone = var.app_target.availability_zone
  vpc_id            = var.app_target.vpc.id
  subnet_id         = var.app_target.subnet.id
  cpu               = 1
  mem_size          = 1000
  volume_size       = 50
  instance_name     = "${var.app_name}-mysql"
  engine_version    = "5.7"
  root_password     = random_password.db.result
  security_groups   = [var.app_sg.security_group.id]
  internet_service  = 1
  slave_deploy_mode = "0"
  slave_sync_mode   = "0"
  intranet_port     = 3306

  charge_type     = var.charge_type
  prepaid_period  = var.charge_perpaid_period
  auto_renew_flag = var.charge_perpaid_auto_renew == true ? 1 : 0
}

# 声明一个 CLB，作为应用访问入口
resource "tencentcloud_clb_instance" "ingress_nginx_clb" {
  network_type    = "OPEN"
  security_groups = [var.app_sg.security_group.id]
  vpc_id          = var.app_target.vpc.id
  subnet_id       = [var.app_target.subnet.id]
}

# 声明一个 Helm 容器编排，查看文档：https://cloud.tencent.com/document/product/1689/90532

resource "cloudapp_helm_app" "app" {
  cluster_id     = tencentcloud_kubernetes_cluster.tke-cluster.id
  chart_src      = "../software/chart"
  chart_username = var.cloudapp_repo_username
  chart_password = var.cloudapp_repo_password
  chart_values = {
    name                         = var.app_name
    cloudappTargetSubnetID       = var.app_target.subnet.id
    cloudappClusterSecurityGroup = var.app_sg.security_group.id

    cloudappImageCredentials = {
      registry = var.cloudapp_repo_server
      username = var.cloudapp_repo_username
      password = var.cloudapp_repo_password
    }
    mysql = {
      host     = tencentcloud_mysql_instance.mysql.intranet_ip
      port     = tencentcloud_mysql_instance.mysql.intranet_port
      user     = "root"
      password = tencentcloud_mysql_instance.mysql.root_password
    }
    cam_role_name = var.cloudapp_cam_role

    service = {
      type = "LoadBalancer"
      annotations = {
        "service.kubernetes.io/tke-existed-lbid" = tencentcloud_clb_instance.ingress_nginx_clb.id
      }
    }
  }
}

output "ingress_nginx_domain" {
  value       = tencentcloud_clb_instance.ingress_nginx_clb.clb_vips[0]
  description = "应用地址，这里提供的是 CLB 的动态域名，仅提供临时访问，请通过 cname 解析到你自己的域名"
}

