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

# --- PROJECT SETTINGS ---
# TODO: Do not hardcode Project ID. Set this via terraform.tfvars or TF_VAR_project_id environment variable.
variable "project_id" {
  description = "The GCP Project ID where resources will be deployed"
  type        = string
}

# Change this to your preferred GCP region (e.g., us-east1, europe-west1)
variable "region" {
  description = "The GCP region for all resources"
  type        = string
  default     = "us-west1"
}

# --- BIGQUERY SETTINGS ---
# The name of the dataset that will contain your flight data
variable "bq_dataset_id" {
  description = "The BigQuery dataset ID"
  type        = string
  default     = "flight_plan"
}

# The table where the primary flight plan history will be stored
variable "bq_table_id" {
  description = "The BigQuery table ID for history"
  type        = string
  default     = "contrails_impact_history"
}

# The table for failed records (Dead Letter Queue)
variable "bq_dead_letter_table_id" {
  description = "The BigQuery table ID for dead letter records"
  type        = string
  default     = "contrails_impact_dead_letter"
}

# The ID for the BigQuery view that deduplicates records
variable "bq_view_id" {
  description = "The BigQuery view ID"
  type        = string
  default     = "contrails_impact"
}

# --- MONITORING SETTINGS ---
# The email address that will receive alerts if the pipeline fails
variable "alert_email" {
  description = "The email address for monitoring alerts"
  type        = string
}

# --- PUBSUB SETTINGS ---
# The name of the topic that will trigger the processing pipeline
variable "pubsub_topic_name" {
  description = "The Pub/Sub topic name"
  type        = string
  default     = "flight-plan-xml-topic"
}
