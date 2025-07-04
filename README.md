# AWS ECS Producer-Consumer Microservices

This project deploys a **Producer-Consumer microservices architecture** on **AWS ECS Fargate** using **Terraform** and automates the pipeline with **GitHub Actions**.

## 🚀 Overview

* **Producer (Microservice 1):** A **RESTful Flask app** receiving requests via an **ALB**. It validates a token (from **SSM**) and sends data to **SQS**.

* **Consumer (Microservice 2):** An **SQS-driven service** that pulls messages and uploads them to an **S3 bucket**.

* **Infrastructure:** All AWS resources (VPC, ECS, ALB, SQS, S3, SSM) are provisioned by **Terraform**.

* **Automation:** **GitHub Actions** manage CI/CD.

## 📋 Prerequisites

* **AWS Account** (configured AWS CLI)

* **Terraform CLI** (v1.12.2)

* **GitHub** & **Docker Hub** accounts

## ⚙️ Setup & Deployment

### 1. AWS Backend Setup

* Create an **S3 bucket** (e.g., `my-tf-state-bucket`).

* Create a **DynamoDB table** (e.g., `my-tf-locks`) with `LockID` (String) as primary key.

* Update `Terraform/main.tf` backend block:

    ```terraform
    terraform {
      backend "s3" {
        bucket         = "my-tf-state-bucket" # <--- REPLACE
        key            = "terraform.tfstate"
        region         = "us-west-1"
        dynamodb_table = "my-tf-locks"      # <--- REPLACE
        encrypt        = true
      }
    }
    ```

### 2. GitHub Secrets

Add the following **repository secrets**:

* `AWS_ACCESS_KEY_ID`

* `AWS_SECRET_ACCESS_KEY`

* `DOCKERHUB_USERNAME`

* `DOCKERHUB_PASSWORD`

* `TOKEN` (Producer token)

* `TF_STATE_BUCKET_NAME`

* `TF_LOCK_TABLE_NAME`

### 3. Microservices Local Setup

Navigate to `./Producer` and `./Consumer` and run:
`pip install -r requirements.txt`

### 4. Initiate Deployment

Push your code to the `master` branch:

```bash
git add .
git commit -m "Initial setup"
git push origin master
```

This triggers the **CI/CD pipeline** (`build-and-push.yaml` then `deploy.yaml`).

## 🚀 CI/CD Workflow (GitHub Actions)

This project uses two GitHub Actions workflows located in the `.github/workflows/` directory:

### 1. `build-and-push.yaml` (Continuous Integration Workflow)

This workflow **builds Docker images for both microservices and pushes them to Docker Hub, tagged with the Git commit SHA.**

* **Trigger:** Automatically runs on every `push` to the `master` branch.
* **Jobs:**
    * **`build-producer`:** Builds and pushes the Producer's image.
    * **`build-consumer`:** Builds and pushes the Consumer's image.

### 2. `deploy.yaml` (Continuous Deployment Workflow)

This workflow **deploys the AWS infrastructure using Terraform, injecting the newly tagged Docker image versions.**

* **Trigger:** Automatically runs when the `build-and-push.yaml` workflow completes successfully (`workflow_run` event with `conclusion == 'success'`).
* **Job:**
    * **`deploy`:** Checks out code, sets up Terraform, updates image tags in `Terraform/main.tf` with the Git SHA, initializes Terraform, generates a plan, and applies changes to deploy/update AWS infrastructure and ECS services.

## ✅ Verification

After `deploy.yaml` completes:

1.  **Check GitHub Actions Logs** for successful `terraform apply`.

2.  **Verify AWS Resources** (ECS, SQS, S3, ALB, SSM) in AWS Console.

3.  **Test Producer Microservice:**

    * Get **ALB DNS Name** from EC2 Console.

    * Send a `POST` request to `http://<ALB_DNS_NAME>/message`.

    ```bash
    curl -X POST "http://YOUR_ALB_DNS_NAME/message" \
         -H "Content-Type: application/json" \
         -d '{ "data": { "email_sender": "...", "email_timestamp": 1678886400 }, "token": "YOUR_SSM_TOKEN" }'
    ```

    * Expect `200 OK`.

4.  **Verify SQS & S3:** Check messages in SQS and objects in S3.

## 🧹 Cleanup

To destroy all AWS resources:

* Add a temporary step to `deploy.yaml` (or a new workflow):

    ```yaml
    # ...
          - name: Terraform Destroy
            run: terraform destroy --auto-approve
    ```

    ***WARNING:*** `--auto-approve` destroys without confirmation. Use with extreme caution.


## 🏛️ Infrastructure Components

The `main.tf` file defines the core AWS infrastructure components required for the Producer-Consumer system:

* **VPC and Networking Components (Managed by `vpc` module):**
    * `aws_vpc`: The isolated virtual network (Virtual Private Cloud) in AWS. **Why needed:** Provides a secure and private environment for your resources, separating them from other networks.
    * `aws_internet_gateway`: A horizontally scaled, redundant, and highly available VPC component that allows communication between your VPC and the internet. **Why needed:** Enables public internet access for your ALB and ECS tasks running in public subnets.
    * `aws_subnet` (public_az1, public_az2): Subdivisions of your VPC where you launch AWS resources. Public subnets have direct access to the internet gateway. **Why needed:** Provides network segmentation and allows deploying resources across multiple Availability Zones for high availability.
    * `aws_route_table` & `aws_route_table_association`: Control how network traffic is routed within your VPC and to the internet. **Why needed:** Directs traffic from subnets to the internet gateway.
    * `aws_security_group.alb_sg`: Acts as a virtual firewall for your ALB, controlling inbound and outbound traffic. **Why needed:** Secures the ALB by allowing only necessary traffic (e.g., HTTP on port 80) from the internet.

* **Application Load Balancer (ALB) Components:**
    * `aws_lb.alb`: Distributes incoming application traffic across multiple targets, such as ECS tasks. **Why needed:** Provides a single entry point for external users to access the Producer microservice, ensuring high availability and scalability.
    * `aws_lb_target_group.tg`: A logical grouping of targets (ECS tasks) that the ALB routes traffic to. **Why needed:** Defines how the ALB performs health checks on the Producer tasks and routes requests to healthy instances.
    * `aws_lb_listener.listener`: Checks for connection requests from clients, using the protocol and port that you configure, and forwards requests to a target group. **Why needed:** Defines the entry point for HTTP traffic on the ALB and associates it with the Producer's target group.

* **IAM Roles and Policies:**
    * `aws_iam_role.ecs_task_role`: An IAM role that ECS tasks can assume to gain permissions to access AWS services. **Why needed:** Allows your Producer and Consumer microservices to interact with SQS, S3, and SSM Parameter Store securely, without hardcoding credentials.
    * `aws_iam_role_policy.ecs_policy`: Defines the specific permissions granted to the `ecs_task_role`. **Why needed:** Grants granular access to SQS (send/receive/delete messages), S3 (put/get objects), and SSM (get parameters), ensuring least privilege.

* **ECS Cluster and Service Components:**
    * `aws_ecs_cluster.cluster`: A logical grouping of ECS tasks or services. **Why needed:** Provides the environment where your Fargate tasks run and are managed.
    * `aws_ecs_task_definition.microservice1` & `aws_ecs_task_definition.microservice2`: Blueprints for running Docker containers on ECS, specifying image, CPU, memory, environment variables, and networking. **Why needed:** Defines the configuration for deploying each microservice (Producer and Consumer) as a container.
    * `aws_ecs_service.microservice1` & `aws_ecs_service.microservice2`: Maintains the desired number of running tasks for a specified task definition. **Why needed:** Ensures that your Producer and Consumer microservices are always running and automatically replaces unhealthy tasks.

* **Messaging and Storage:**
    * `aws_sqs_queue.queue`: A fully managed message queuing service. **Why needed:** Decouples the Producer and Consumer, allowing asynchronous communication and buffering messages, improving fault tolerance and scalability.
    * `aws_s3_bucket.bucket`: Object storage for storing data. **Why needed:** Provides durable and scalable storage for the data processed by the Consumer microservice.

* **Parameter Store:**
    * `aws_ssm_parameter.auth_token`: Securely stores configuration data or secrets. **Why needed:** Provides a secure way for the Producer microservice to retrieve its authentication token at runtime.

