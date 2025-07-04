provider "aws" {
  region     = var.region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

terraform {
  backend "s3" {
    bucket         = "PLACEHOLDER"
    key            = "terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = "PLACEHOLDER"
    encrypt        = true
  }
}


# --- Networking ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.20.0/24"
  availability_zone       = "${var.region}c"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "route" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "rta_az1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "rta_az2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.rt.id
}

# --- Security Group ---
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow HTTP to ALB"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ALB ---
resource "aws_lb" "alb" {
  name               = "microservice1-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
  security_groups    = [aws_security_group.alb_sg.id]
}

resource "aws_lb_target_group" "tg" {
  name        = "microservice1-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# --- IAM Role for ECS Tasks ---
resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_policy" {
  name = "ecs-basic-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "ssm:GetParameter"
        ],
        Resource = aws_ssm_parameter.auth_token.arn
      },
      # ADD THESE TWO NEW STATEMENTS BELOW
      {
        Effect = "Allow",
        Action = [
          "servicediscovery:RegisterInstance",
          "servicediscovery:DeregisterInstance",
          "servicediscovery:Get*",
          "servicediscovery:List*",
        ],
        Resource = "*" # Consider scoping this down to specific service ARNs if needed
      },
      {
        Effect = "Allow",
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientRootAccess",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeFileSystems"
        ],
        Resource = aws_efs_file_system.monitoring_efs.arn
      }
    ]
  })
}

# --- ECS ---
resource "aws_ecs_cluster" "cluster" {
  name = "microservices-cluster"
}

resource "aws_sqs_queue" "queue" {
  name = "microservice-queue"
}

resource "aws_s3_bucket" "bucket" {
  bucket        = "microservice-data-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_ssm_parameter" "auth_token" {
  name  = "/microservice1/token"
  type  = "SecureString"
  value = var.producer_token
}

resource "aws_ecs_task_definition" "microservice1" {
  family                   = "microservice1-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name  = "microservice1"
    image = "${var.dockerhub_username}/microservice1:placeholder"
    portMappings = [{
      containerPort = 80
      hostPort      = 80
      protocol      = "tcp"
    }],
    environment = [
      {
        name  = "SQS_QUEUE_URL"
        value = aws_sqs_queue.queue.id
      },
      {
        name  = "AWS_REGION"
        value = "${var.region}-1"
      },
      {
        name  = "TOKEN_PARAM"
        value = aws_ssm_parameter.auth_token.name
      }
    ]
  }])
}

resource "aws_ecs_service" "microservice1" {
  name             = "microservice1-service"
  cluster          = aws_ecs_cluster.cluster.id
  task_definition  = aws_ecs_task_definition.microservice1.arn
  desired_count    = 1
  launch_type      = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.alb_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "microservice1"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.listener]

  # ADD THIS BLOCK for Cloud Map registration
  service_registries {
    registry_arn = aws_service_discovery_service.producer_cloudmap_service.arn
    port         = 80 # Producer container's HTTP port
  }
}

# Microservice 2 Task Definition
resource "aws_ecs_task_definition" "microservice2" {
  family                   = "microservice2-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name  = "microservice2"
    image = "${var.dockerhub_username}/microservice2:placeholder"
    environment = [
      {
        name  = "SQS_QUEUE_URL"
        value = aws_sqs_queue.queue.id
      },
      {
        name  = "S3_BUCKET_NAME"
        value = aws_s3_bucket.bucket.bucket
      },
      {
        name  = "AWS_REGION"
        value = "${var.region}-1"
      }
    ]
  }])
}

# Microservice 2 ECS Service (runs continuously)
resource "aws_ecs_service" "microservice2" {
  name            = "microservice2-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.microservice2.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.alb_sg.id]
  }
}

# --- BEGIN MONITORING INFRASTRUCTURE (Producer, Prometheus, Grafana) ---

# --- AWS Cloud Map for Service Discovery ---
resource "aws_service_discovery_http_namespace" "microservices_namespace" {
  name        = "my-ecs-microservices" # Ensure this matches your prometheus.yml
  description = "HTTP Namespace for Microservices in ECS for Monitoring"
}

resource "aws_service_discovery_service" "producer_cloudmap_service" {
  name        = "producer-service" # This name is used in prometheus.yml
  description = "Cloud Map service for the Producer microservice"
  dns_config {
    namespace_id = aws_service_discovery_http_namespace.microservices_namespace.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

# --- EFS for Persistent Storage (Prometheus & Grafana) ---
resource "aws_efs_file_system" "monitoring_efs" {
  creation_token   = "monitoring-efs-fs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true
  tags = {
    Name = "MonitoringEFS"
  }
}

resource "aws_efs_mount_target" "az1" {
  file_system_id  = aws_efs_file_system.monitoring_efs.id
  subnet_id       = aws_subnet.public_az1.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_efs_mount_target" "az2" {
  file_system_id  = aws_efs_file_system.monitoring_efs.id
  subnet_id       = aws_subnet.public_az2.id
  security_groups = [aws_security_group.efs_sg.id]
}

resource "aws_security_group" "efs_sg" {
  name        = "efs-access-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow EFS access from ECS tasks"
  ingress {
    from_port   = 2049 # NFS port
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# --- Prometheus Resources ---
resource "aws_iam_role" "prometheus_task_role" {
  name = "prometheusTaskRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "prometheus_policy" {
  name = "prometheus-policy"
  role = aws_iam_role.prometheus_task_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "ec2:DescribeNetworkInterfaces",
          "cloudmap:ListServices",
          "cloudmap:ListNamespaces",
          "cloudmap:ListInstances",
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientRootAccess",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeFileSystems"
        ],
        Resource = aws_efs_file_system.monitoring_efs.arn
      }
    ]
  })
}

resource "aws_security_group" "prometheus_sg" {
  name        = "prometheus-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow Prometheus UI/API access within the VPC and EFS access"
  ingress {
    from_port   = 9090 # Prometheus UI/API port
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "prometheus_task" {
  family                   = "prometheus-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.prometheus_task_role.arn
  task_role_arn            = aws_iam_role.prometheus_task_role.arn
  volume {
    name = "prometheus-data"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.monitoring_efs.id
      root_directory = "/prometheus"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.prometheus_ap.id
        iam             = "ENABLED"
      }
    }
  }
  container_definitions = jsonencode([{
    name        = "prometheus",
    image       = "${var.dockerhub_username}/prometheus:placeholder",
    cpu         = 512,
    memory      = 1024,
    portMappings = [{ containerPort = 9090, hostPort = 9090, protocol = "tcp" }],
    mountPoints = [{ sourceVolume = "prometheus-data", containerPath = "/prometheus", readOnly = false }],
    environment = [{ name = "AWS_REGION", value = var.region }],
    logConfiguration = { logDriver = "awslogs", options = { "awslogs-group" = "/ecs/prometheus", "awslogs-region" = var.region, "awslogs-stream-prefix" = "prometheus" } }
  }])
}

resource "aws_efs_access_point" "prometheus_ap" {
  file_system_id = aws_efs_file_system.monitoring_efs.id
  posix_user { # Corrected block syntax
    gid = 65534
    uid = 65534
  }
  root_directory { # Corrected block syntax
    path = "/prometheus"
    creation_info {
      owner_gid   = 65534
      owner_uid   = 65534
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "prometheus_log_group" {
  name              = "/ecs/prometheus"
  retention_in_days = 7
}

resource "aws_ecs_service" "prometheus_service" {
  name            = "prometheus-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.prometheus_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.prometheus_sg.id, aws_security_group.efs_sg.id]
  }
  depends_on = [aws_efs_mount_target.az1, aws_efs_mount_target.az2, aws_efs_access_point.prometheus_ap]
}

# --- Grafana Resources ---
resource "aws_iam_role" "grafana_task_role" {
  name = "grafanaTaskRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_policy" {
  name = "grafana-policy"
  role = aws_iam_role.grafana_task_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientRootAccess",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeFileSystems"
        ],
        Resource = aws_efs_file_system.monitoring_efs.arn
      }
    ]
  })
}

resource "aws_security_group" "grafana_sg" {
  name        = "grafana-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow Grafana UI access and EFS access"
  ingress {
    from_port   = 3000 # Grafana UI default port
    to_port     = 3000
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Allow from ALB
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_task_definition" "grafana_task" {
  family                   = "grafana-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.grafana_task_role.arn
  task_role_arn            = aws_iam_role.grafana_task_role.arn
  volume {
    name = "grafana-data"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.monitoring_efs.id
      root_directory = "/grafana"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.grafana_ap.id
        iam             = "ENABLED"
      }
    }
  }
  container_definitions = jsonencode([{
    name        = "grafana",
    image       = "grafana/grafana:latest",
    cpu         = 256,
    memory      = 512,
    portMappings = [{ containerPort = 3000, hostPort = 3000, protocol = "tcp" }],
    mountPoints = [{ sourceVolume = "grafana-data", containerPath = "/var/lib/grafana", readOnly = false }],
    environment = [
      { name = "GF_PATHS_PROVISIONING", value = "/etc/grafana/provisioning" },
      { name = "GF_AUTH_ANONYMOUS_ENABLED", value = "true" }, # NOT for production, for simplicity
      { name = "GF_AUTH_ANONYMOUS_ORG_ROLE", value = "Viewer" },
      { name = "GF_SERVER_ROOT_URL", value = "http://localhost:3000" }
    ],
    logConfiguration = { logDriver = "awslogs", options = { "awslogs-group" = "/ecs/grafana", "awslogs-region" = var.region, "awslogs-stream-prefix" = "grafana" } }
  }])
}

resource "aws_efs_access_point" "grafana_ap" {
  file_system_id = aws_efs_file_system.monitoring_efs.id
  posix_user { # Corrected block syntax
    gid = 65534
    uid = 65534
  }
  root_directory { # Corrected block syntax
    path = "/grafana"
    creation_info {
      owner_gid   = 65534
      owner_uid   = 65534
      permissions = "0755"
    }
  }
}

resource "aws_cloudwatch_log_group" "grafana_log_group" {
  name              = "/ecs/grafana"
  retention_in_days = 7
}

resource "aws_lb_target_group" "grafana_tg" {
  name        = "grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check { # Corrected block syntax
    path                = "/api/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "grafana_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 3001 # Choose an available ALB port for Grafana
  protocol          = "HTTP"
  default_action { # Corrected block syntax
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana_tg.arn
  }
}

resource "aws_ecs_service" "grafana_service" {
  name            = "grafana-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.grafana_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.grafana_sg.id, aws_security_group.efs_sg.id]
  }
  load_balancer { # Corrected block syntax
    target_group_arn = aws_lb_target_group.grafana_tg.arn
    container_name   = "grafana"
    container_port   = 3000
  }
  depends_on = [
    aws_efs_mount_target.az1,
    aws_efs_mount_target.az2,
    aws_efs_access_point.grafana_ap,
    aws_lb_listener.grafana_listener
  ]
}

# --- Outputs ---
output "alb_dns_name" {
  value       = aws_lb.alb.dns_name
  description = "URL of the load balancer for Microservice 1"
}

output "sqs_queue_url" {
  description = "SQS Queue URL for microservice"
  value       = aws_sqs_queue.queue.id
}

output "s3_bucket_name" {
  description = "S3 Bucket"
  value       = aws_s3_bucket.bucket.bucket
}
