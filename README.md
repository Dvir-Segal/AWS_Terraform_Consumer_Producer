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

* Create an **S3 bucket** (e.g., `my-tf-state-bucket`) with **versioning**.

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
