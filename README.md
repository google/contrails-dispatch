# Flight Plan Climate Impact Pipeline

Copyright 2026 Google LLC

This project helps airlines and climate analysts understand the climate impact of flights by automating the ingestion of flight plans and calculating their Effective Energy Forcing. It integrates with `pycontrails` and Google Forecast data, storing results in BigQuery for analysis.

This project is intended for demonstration purposes only. It is not
intended for use in a production environment.

## Architecture

1.  **Ingestion:** Flight plans are published as XML messages to a **GCP Pub/Sub** topic.
2.  **Processing:** A **Cloud Function (v2)** is triggered by Pub/Sub. Code located in [contrails_dispatch/flight_plan_processor/](contrails_dispatch/flight_plan_processor/). It:
    *   Parses the XML using `pycontrails`.
    *   Calls the Google [Contrails API GetGrid](https://developers.google.com/contrails/reference/v2/grids/getGrids) method to get the contrails forecast data.
    *   Calculates the *total expected effective energy forcing* for the flight path given the grid forecast data.
3.  **Storage:** Results are stored in a **BigQuery** history table, with a deduplicated View for business reporting.
4.  **Monitoring:** A **Cloud Monitoring Dashboard** tracks pipeline health, and an **Alert Policy** notifies engineers of failures.

---

## Deployment

### Prerequisites
*   Google Cloud Project with Billing enabled.
*   `gcloud` CLI installed and authenticated (`gcloud auth application-default login`).
*   Terraform installed.
*   GCS Bucket for Terraform state (configured in `main.tf`).

### Steps
1.  **Configure State Backend (Optional):**
    By default, Terraform uses local state. For production, it is recommended to use remote state. Open `infrastructure/terraform/main.tf`, uncomment the `backend "gcs"` block, and replace `TFSTATE_BUCKET_NAME` with your actual GCS bucket name (which must be created beforehand).
2.  **Customize Variables:**
    Navigate to the terraform directory:
    ```bash
    cd infrastructure/terraform
    ```
    Copy `terraform.tfvars.example` to `terraform.tfvars` and uncomment/update the minimum required variables:
    *   `project_id`: Your Google Cloud Project ID.
    *   `alert_email`: The email address to receive alerts.
    You can also override other variables as needed.
3.  **Initialize Terraform:**
    ```bash
    terraform init
    ```
4.  **Validate and Apply Infrastructure:**
    ```bash
    terraform validate
    terraform plan
    terraform apply
    ```

---

## Usage & Testing

### Sending Test Data
You can use the provided Python script to trigger the pipeline:
```bash
# Set up environment
python3 -m venv venv
source venv/bin/activate
pip install google-cloud-pubsub

# Publish a flight plan
GCP_PROJECT_ID="your-gcp-project-id" python3 tests/publish_test.py
```

### Local Testing
You can test the Cloud Function logic locally using `functions-framework`.

1. Install dependencies in your virtual environment.
2. Run the function locally (mocking external dependencies if necessary, or using real credentials):
   ```bash
   cd contrails_dispatch/flight_plan_processor
   functions-framework --target=process_flight_plan --signature-type=cloudevent
   ```
3. You can send test payloads to `http://localhost:8080`.

### Stackranking Flights
To get a stackranked list of air journeys for a specific day based on their climate impact:

#### Option A: BigQuery SQL
Run this query in the BigQuery Console (uses the deduplicated View):
```sql
SELECT
  flight_identifier,
  departure_airport_icao,
  arrival_airport_icao,
  total_forcing_joules
FROM `YOUR_GCP_PROJECT_ID.flight_plan.contrails_impact`
WHERE origin_date = CURRENT_DATE()
ORDER BY total_forcing_joules DESC;
```

> [!NOTE]
> The processed flight impact data is stored in the `flight_plan` dataset.
> *   **`contrails_impact` (View):** Use this for clean, deduplicated results with results for newest flight plans.
> *   **`contrails_impact_history` (Table):** Contains all raw audit logs and historical data. See [schema](infrastructure/bigquery/schema/contrails_impact_history.json).
> *   **`contrails_impact_dead_letter` (Table):** Contains records that encountered errors during processing. See [schema](infrastructure/bigquery/schema/contrails_impact_dead_letter.json).

#### Option B: Looker Studio (Recommended)
1.  Connect Looker Studio to the `contrails_impact` BigQuery view.
2.  Add a **Table** chart with dimensions: `flight_identifier`, `departure_airport_icao`, `arrival_airport_icao`.
3.  Add `total_forcing_joules` as a **Metric** (SUM).
4.  Add a **Date Range Control** to filter for specific days.
5.  Sort the table by `total_forcing_joules` (Descending).

---

## Monitoring & Observability

### Dashboard
The **"Flight Pipeline Health"** dashboard is automatically created by Terraform. It includes:
*   **Invocations & Latency:** Real-time performance of the Cloud Function.
*   **Pub/Sub Backlog:** Tracks if the system is falling behind under load.
*   **Error Panel:** Direct view of recent function logs for troubleshooting.
*   **Ingestion Stats:** Daily count of successful BigQuery inserts.

### Alerts
If the Cloud Function fails consistently within a **30-minute window**, an automated alert is sent to the email address configured in `var.alert_email`.

---

## License

Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

---

## Contributing & Help

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this project, report bugs, or suggest enhancements.
