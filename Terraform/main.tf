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

module "vpc" {
  source = "./modules/vpc"
  region = var.region
}


resource "aws_lb" "alb" {
  name               = "microservice1-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnet_ids
  security_groups    = [module.vpc.alb_sg_id]

  tags = {
    Name = "microservice1-alb"
  }
}

resource "aws_lb_target_group" "tg" {
  name        = "microservice1-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }

  tags = {
    Name = "microservice1-tg"
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

  tags = {
    Name = "microservice1-listener"
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

  tags = {
    Name = "ecsTaskRole"
  }
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
      }
    ]
  })
}

# --- ECS Cluster ---
resource "aws_ecs_cluster" "cluster" {
  name = "microservices-cluster"

  tags = {
    Name = "microservices-cluster"
  }
}

resource "aws_sqs_queue" "queue" {
  name = "microservice-queue"

  tags = {
    Name = "microservice-queue"
  }
}

resource "aws_s3_bucket" "bucket" {
  bucket        = "microservice-data-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "microservice-data-bucket"
  }
}

resource "aws_ssm_parameter" "auth_token" {
  name  = "/microservice1/token"
  type  = "SecureString"
  value = var.producer_token

  tags = {
    Name = "microservice1-auth-token"
  }
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
    name = "microservice1"
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
        value = var.region
      },
      {
        name  = "TOKEN_PARAM"
        value = aws_ssm_parameter.auth_token.name
      }
    ]
  }])

  tags = {
    Name = "microservice1-task"
  }
}

resource "aws_ecs_service" "microservice1" {
  name            = "microservice1-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.microservice1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.public_subnet_ids
    assign_public_ip = true
    security_groups  = [module.vpc.alb_sg_id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "microservice1"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.listener]

  tags = {
    Name = "microservice1-service"
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
    name = "microservice2"
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
        value = var.region
      }
    ]
  }])

  tags = {
    Name = "microservice2-task"
  }
}

# Microservice 2 ECS Service (runs continuously)
resource "aws_ecs_service" "microservice2" {
  name            = "microservice2-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.microservice2.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.public_subnet_ids
    assign_public_ip = true
    security_groups  = [module.vpc.alb_sg_id]
  }

  tags = {
    Name = "microservice2-service"
  }
}


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
