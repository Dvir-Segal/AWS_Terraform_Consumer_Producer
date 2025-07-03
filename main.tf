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
  availability_zone       = "us-west-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.20.0/24"
  availability_zone       = "us-west-1c"
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
        value = "us-west-1"
      },
      {
        name  = "TOKEN_PARAM"
        value = aws_ssm_parameter.auth_token.name
      }
    ]
  }])
}

resource "aws_ecs_service" "microservice1" {
  name            = "microservice1-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.microservice1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.alb_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "microservice1"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.listener]
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
        value = "us-west-1"
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

