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

resource "google_logging_metric" "flight_plan_inserts" {
  name   = "flight-plan-insert-count"
  filter = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"process-flight-plan\" jsonPayload.event=\"flight_plan_insert_success\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_dashboard" "flight_pipeline_dashboard" {
  dashboard_json = jsonencode({
    displayName = "Flight Pipeline Health"
    mosaicLayout = {
      columns = 12
      tiles = [
        # Chart 1: Cloud Function Invocations
        {
          xPos = 0, yPos = 0, width = 6, height = 4
          widget = {
            title = "Function Invocations (per min)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" resource.type=\"cloud_function\" resource.label.\"function_name\"=\"process-flight-plan\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_RATE"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Chart 2: Cloud Function Latency
        {
          xPos = 6, yPos = 0, width = 6, height = 4
          widget = {
            title = "Function Latency (p99)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"cloudfunctions.googleapis.com/function/execution_times\" resource.type=\"cloud_function\" resource.label.\"function_name\"=\"process-flight-plan\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_PERCENTILE_99"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Chart 3: Pub/Sub Backlog
        {
          xPos = 0, yPos = 4, width = 6, height = 4
          widget = {
            title = "Pub/Sub Backlog (Unacked Messages)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" resource.type=\"pubsub_subscription\" resource.label.\"subscription_id\"=\"${var.pubsub_topic_name}-sub\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_MEAN"
                    }
                  }
                }
                plotType = "LINE"
              }]
            }
          }
        },
        # Chart 4: Error Count
        {
          xPos = 6, yPos = 4, width = 6, height = 4
          widget = {
            title = "Error Invocations"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" resource.type=\"cloud_function\" resource.label.\"function_name\"=\"process-flight-plan\" metric.label.\"status\"!=\"ok\""
                    aggregation = {
                      alignmentPeriod    = "60s"
                      perSeriesAligner   = "ALIGN_SUM"
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
            }
          }
        },
        # Widget 5: Cloud Function Logs
        {
          xPos = 0, yPos = 8, width = 12, height = 6
          widget = {
            title = "Recent Function Logs"
            logsPanel = {
              filter = "resource.type=\"cloud_run_revision\" resource.labels.service_name=\"process-flight-plan\""
              resourceNames = ["projects/${var.project_id}"]
            }
          }
        },
        # Chart 6: New Rows in BigQuery (via Log-based Metric)
        {
          xPos = 0, yPos = 14, width = 12, height = 4
          widget = {
            title = "New Rows in BigQuery (Processed per day)"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter = "metric.type=\"logging.googleapis.com/user/flight-plan-insert-count\""
                    aggregation = {
                      alignmentPeriod    = "86400s" # 1 day
                      perSeriesAligner   = "ALIGN_SUM"
                    }
                  }
                }
                plotType = "STACKED_BAR"
              }]
            }
          }
        }
      ]
    }
  })

  depends_on = [google_project_service.enabled_services, google_logging_metric.flight_plan_inserts]
}

# 7. Notification Channel (Email)
resource "google_monitoring_notification_channel" "email" {
  display_name = "Cloud Function Error Alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

# 8. Alert Policy for Cloud Function Errors
resource "google_monitoring_alert_policy" "cf_error_alert" {
  display_name = "Cloud Function Errors - 30min Window"
  combiner     = "OR"
  conditions {
    display_name = "Cloud Function Execution Errors"
    condition_threshold {
      filter          = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" resource.type=\"cloud_function\" resource.label.\"function_name\"=\"process-flight-plan\" metric.label.\"status\"!=\"ok\""
      duration        = "1800s" # 30 minutes window
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  alert_strategy {
    auto_close = "604800s" # 7 days
  }
}
