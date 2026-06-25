# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

terraform {
  # --- REMOTE STATE BACKEND ---
  # NOTE: Variables cannot be used in backend configuration (loaded before variables).
  # Uncomment and replace with your actual GCS bucket name to use remote state (recommended for production).
  # backend "gcs" {
  #   bucket = "TFSTATE_BUCKET_NAME"
  #   prefix = "terraform/state"
  # }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 0. Enable Required APIs
locals {
  services = [
    "cloudresourcemanager.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
    "contrails.googleapis.com"
  ]
}

resource "google_project_service" "enabled_services" {
  for_each = toset(local.services)
  project  = var.project_id
  service  = each.key

  disable_on_destroy = false
}

# 1. Pub/Sub Infrastructure
resource "google_pubsub_topic" "flight_plans" {
  name       = var.pubsub_topic_name
  depends_on = [google_project_service.enabled_services]
}

resource "google_pubsub_subscription" "flight_plans_sub" {
  name  = "${var.pubsub_topic_name}-sub"
  topic = google_pubsub_topic.flight_plans.id

  message_retention_duration = "604800s"
  retain_acked_messages      = false
  ack_deadline_seconds       = 180
}

# 2. Storage Bucket for Cloud Function Source
resource "google_storage_bucket" "function_source_bucket" {
  name                        = "${var.project_id}-function-source"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../contrails_dispatch/flight_plan_processor"
  output_path = "${path.module}/function.zip"
}

resource "google_storage_bucket_object" "function_source_zip" {
  name   = "source.zip#${data.archive_file.function_zip.output_md5}"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.function_zip.output_path
}

# 3. BigQuery Dataset & Tables
resource "google_bigquery_dataset" "flight_plan_dataset" {
  dataset_id  = var.bq_dataset_id
  description = "Dataset for Flight Plans & CO2 Emissions"
  location    = var.region
  depends_on  = [google_project_service.enabled_services]
}

resource "google_bigquery_table" "flight_plan_table" {
  dataset_id = google_bigquery_dataset.flight_plan_dataset.dataset_id
  table_id   = var.bq_table_id

  time_partitioning {
    type  = "DAY"
    field = "origin_date"
  }
  schema              = file("${path.module}/../bigquery/schema/contrails_impact_history.json")
  deletion_protection = false
}

resource "google_bigquery_table" "flight_plan_dead_letter" {
  dataset_id          = google_bigquery_dataset.flight_plan_dataset.dataset_id
  table_id            = var.bq_dead_letter_table_id
  schema              = file("${path.module}/../bigquery/schema/contrails_impact_dead_letter.json")
  deletion_protection = false
}

resource "google_bigquery_table" "flight_plan_view" {
  depends_on = [google_bigquery_table.flight_plan_table]
  dataset_id = google_bigquery_dataset.flight_plan_dataset.dataset_id
  table_id   = var.bq_view_id
  view {
    query = templatefile("${path.module}/../bigquery/views/contrails_impact.sql", {
      source_table = "${google_bigquery_table.flight_plan_table.project}.${google_bigquery_table.flight_plan_table.dataset_id}.${google_bigquery_table.flight_plan_table.table_id}"
    })
    use_legacy_sql = false
  }
  deletion_protection = false
}

# 4. Service Account for Cloud Function
data "google_project" "project" {}

resource "google_service_account" "function_sa" {
  account_id   = "flight-plan-processor-sa"
  display_name = "Cloud Function Flight Plan Processor SA"
  depends_on   = [google_project_service.enabled_services]
}

resource "google_service_account" "trigger_sa" {
  account_id   = "flight-plan-trigger-sa"
  display_name = "Cloud Function Flight Plan Trigger SA"
  depends_on   = [google_project_service.enabled_services]
}

# 4.1 Build Permissions for GCF 2nd Gen
# GCF 2nd gen uses the Compute Engine default service account for builds by default.
resource "google_project_iam_member" "build_service_account_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "build_service_account_artifact_registry_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "build_service_account_storage_object_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "build_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# 5. Cloud Function (2nd gen)
resource "google_cloudfunctions2_function" "flight_plan_function" {
  name        = "process-flight-plan"
  location    = var.region
  description = "Processes flight plan XMLs from Pub/Sub using pycontrails"

  build_config {
    runtime     = "python311"
    entry_point = "process_flight_plan"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.function_source_zip.name
      }
    }
  }

  service_config {
    max_instance_count    = 10
    available_memory      = "8Gi"
    available_cpu         = "2"
    timeout_seconds       = 540
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.function_sa.email

    environment_variables = {
      PROJECT_ID              = var.project_id
      BQ_DATASET_ID           = var.bq_dataset_id
      BQ_TABLE_ID             = var.bq_table_id
      BQ_DEAD_LETTER_TABLE_ID = var.bq_dead_letter_table_id
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.flight_plans.id
    retry_policy   = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.trigger_sa.email
  }

  depends_on = [
    google_project_iam_member.build_service_account_log_writer,
    google_project_iam_member.build_service_account_artifact_registry_writer,
    google_project_iam_member.build_service_account_storage_object_viewer,
    google_project_iam_member.build_service_account_user
  ]
}

# 6. IAM Roles for the Service Account
resource "google_bigquery_dataset_iam_member" "bq_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.flight_plan_dataset.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_pubsub_subscription_iam_member" "pubsub_subscriber" {
  subscription = google_pubsub_subscription.flight_plans_sub.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.trigger_sa.email}"
}

resource "google_project_iam_member" "eventarc_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.trigger_sa.email}"
}

resource "google_cloud_run_service_iam_member" "run_invoker" {
  location = google_cloudfunctions2_function.flight_plan_function.location
  service  = google_cloudfunctions2_function.flight_plan_function.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.trigger_sa.email}"
}

