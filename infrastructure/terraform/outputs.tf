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

output "pubsub_topic_name" {
  description = "The name of the Pub/Sub topic"
  value       = google_pubsub_topic.flight_plans.name
}

output "pubsub_subscription_name" {
  description = "The name of the Pub/Sub subscription"
  value       = google_pubsub_subscription.flight_plans_sub.name
}

output "bq_dataset_id" {
  description = "The BigQuery dataset ID"
  value       = google_bigquery_dataset.flight_plan_dataset.dataset_id
}

output "bq_table_id" {
  description = "The BigQuery historical table ID"
  value       = google_bigquery_table.flight_plan_table.table_id
}

output "function_url" {
  description = "The URL of the Cloud Function"
  value       = google_cloudfunctions2_function.flight_plan_function.service_config[0].uri
}

output "function_service_account_email" {
  description = "The email of the Cloud Function service account"
  value       = google_service_account.function_sa.email
}
