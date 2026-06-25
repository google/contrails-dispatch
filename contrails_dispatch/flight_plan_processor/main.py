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

import base64
import os
import json
import logging
from datetime import datetime, timezone
import xml.etree.ElementTree as ET
import functions_framework
import numpy as np
from pycontrails.core import flightplan
from pycontrails.datalib import google_forecast
from google.cloud import bigquery
import google.cloud.logging

# Initialize Google Cloud Logging
logging_client = google.cloud.logging.Client()
logging_client.setup_logging()

# Initialize BigQuery client
bq_client = bigquery.Client()

# Environment variables
PROJECT_ID = os.environ.get("PROJECT_ID")
DATASET_ID = os.environ.get("BQ_DATASET_ID")
TABLE_ID = os.environ.get("BQ_TABLE_ID")
DLQ_TABLE_ID = os.environ.get("BQ_DEAD_LETTER_TABLE_ID")

# Basic validation
if not all([PROJECT_ID, DATASET_ID, TABLE_ID, DLQ_TABLE_ID]):
    raise RuntimeError(
        "Missing one or more required environment variables: PROJECT_ID, BQ_DATASET_ID, BQ_TABLE_ID, BQ_DEAD_LETTER_TABLE_ID"
    )

FULL_TABLE_ID = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"
FULL_DLQ_TABLE_ID = f"{PROJECT_ID}.{DATASET_ID}.{DLQ_TABLE_ID}"


@functions_framework.cloud_event
def process_flight_plan(cloud_event):
    """Processes a flight plan XML from Pub/Sub and stores forcing data in BigQuery."""

    # Extract topic ID from cloud_event source
    # Format: //pubsub.googleapis.com/projects/{project}/topics/{topic}
    source = cloud_event.get("source", "unknown")
    topic_id = source.split("/")[-1] if "/" in source else "unknown"

    logger = logging.getLogger(f"topic:{topic_id}")
    now_utc = datetime.now(timezone.utc).isoformat()

    logger.info("Cloud Event received: %s", cloud_event['id'])

    # 1. Load XML from Pub/Sub
    try:
        pubsub_message = base64.b64decode(cloud_event.data["message"]["data"]).decode(
            "utf-8"
        )
        logger.info("Decoded message length: %s", len(pubsub_message))
    except Exception as e:
        logger.error("Error decoding Pub/Sub message: %s", e)
        _write_to_dlq(_build_dlq_payload(cloud_event), f"Decoding Error: {str(e)}", logger)
        return

    # 2. Parse with pycontrails
    try:
        logger.info("Parsing flight plan...")
        flight = flightplan.parse_ofp_xml(pubsub_message)
        logger.info("Parsed flight: %s", flight.attrs.get('flight_number'))

        # Extract computedTime from XML
        # NOTE: This causes double XML parsing. Currently required because pycontrails'
        # parse_ofp_xml does not return the computedTime attribute.
        # TODO: Remove this manual parsing once pycontrails supports extracting this attribute.
        computed_time_str = _get_computed_time(pubsub_message, logger)

        if not computed_time_str:
            raise ValueError("Missing or invalid computedTime in flight plan XML")
    except Exception as e:
        logger.error("Permanent error during parsing: %s", e)
        _write_to_dlq(_build_dlq_payload(cloud_event, pubsub_message), f"Parsing Error: {str(e)}", logger)
        return

    try:
        logger.info("Resampling and filling flight...")
        flight = flight.resample_and_fill()

        # 3. Get Contrails Forecast Data
        logger.info(
            "Fetching Google Forecast for period: %s to %s", flight.time_start, flight.time_end
        )
        forecast_mds = google_forecast.GoogleForecast(
            time=(flight.time_start.floor("h"), flight.time_end.ceil("h")),
            variables=google_forecast.ExpectedEffectiveEnergyForcing,
        ).open_metdataset()
        logger.info("Forecast data loaded.")

        # 4. Intersect Flight plan with Grid Forecast Data
        # and compute Contrails impact
        logger.info("Intersecting flight with forecast data...")
        flight["expected_effective_energy_forcing"] = flight.intersect_met(
            forecast_mds["expected_effective_energy_forcing"]
        )
        logger.info("Computing forcing...")
        flight["segment_length"] = flight.segment_length()
        flight["segment_forcing_j"] = (
            flight["expected_effective_energy_forcing"] * flight["segment_length"]
        )

        if np.all(np.isnan(flight["segment_forcing_j"])):
            total_forcing_j = None
            logger.warning("All forcing segments are NaN. Setting total forcing to NULL.")
        else:
            total_forcing_j = float(np.nansum(flight["segment_forcing_j"]))
            logger.info("Total forcing calculated: %s", total_forcing_j)

        # Serialize the parsed flight plan to JSON for storage
        # Replace NaNs with None to ensure strict JSON compatibility (null instead of NaN)
        flight_df_clean = flight.dataframe.replace({np.nan: None})
        flight_data = {
            "attrs": flight.attrs,
            "data": flight_df_clean.to_dict(orient="records"),
        }
        flight_plan_json = json.dumps(flight_data, default=str)

        # 5. Save to BigQuery
        logger.info("Inserting into BigQuery table: %s", FULL_TABLE_ID)

        # Map attributes to the requested schema
        row_to_insert = [
            {
                "flight_identifier": flight.attrs.get("flight_number"),
                "departure_airport_icao": flight.attrs.get("departure_airport"),
                "arrival_airport_icao": flight.attrs.get("arrival_airport"),
                "aircraft_type": flight.attrs.get("aircraft_type"),
                "aircraft_registration": flight.attrs.get("tail_number"),
                "origin_date": (
                    flight.time_start.date().isoformat() if flight.time_start else None
                ),
                "departure_planned_at": (
                    flight.time_start.isoformat() if flight.time_start else None
                ),
                "arrival_planned_at": (
                    flight.time_end.isoformat() if flight.time_end else None
                ),
                "last_updated_at": computed_time_str,
                "total_forcing_joules": total_forcing_j,
                "flight_plan_json": flight_plan_json,
                "bq_last_update_timestamp": now_utc,
            }
        ]

        errors = bq_client.insert_rows_json(FULL_TABLE_ID, row_to_insert)

        if errors:
            logger.error("Errors occurred during BigQuery insert: %s", errors)
            _write_to_dlq(
                _build_dlq_payload(cloud_event, pubsub_message), f"BigQuery Insert Errors: {json.dumps(errors)}", logger
            )
            return
        else:
            logger.info({"event": "flight_plan_insert_success", "message": "Successfully inserted into BigQuery."})

    except ValueError as e:
        logger.error("Permanent processing error (ValueError): %s", e)
        _write_to_dlq(_build_dlq_payload(cloud_event, pubsub_message), f"Processing Error: {str(e)}", logger)
        return
    except Exception as e:
        logger.exception("Transient or unexpected error during flight plan processing: %s", e)
        raise # Bubble up to trigger Pub/Sub retry


def _get_computed_time(xml_str, logger) -> str | None:
    """Extracts computedTime attribute from the root of the FlightPlan XML."""
    try:
        root = ET.fromstring(xml_str)
        computed_time_str = root.get('computedTime')
        if not computed_time_str:
            return None

        dt = datetime.fromisoformat(computed_time_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat()
    except Exception as e:
        logger.warning("Could not extract or parse computedTime from XML: %s", e)
        return None


def _build_dlq_payload(cloud_event, xml_payload="N/A") -> dict[str, any]:
    """Builds rich DLQ payload from cloud_event and xml_payload."""
    message = cloud_event.data.get("message", {})
    return {
        "message_id": message.get("messageId", "unknown"),
        "attributes": message.get("attributes", {}),
        "xml_payload": xml_payload
    }


def _write_to_dlq(payload_dict, error_message, logger) -> None:
    """Writes failed payload and error details to the Dead Letter Queue table."""
    dlq_row = [
        {
            "failed_at": datetime.now(timezone.utc).isoformat(),
            "error_message": error_message,
            "payload": json.dumps(payload_dict),
        }
    ]
    try:
        bq_client.insert_rows_json(FULL_DLQ_TABLE_ID, dlq_row)
    except Exception as dlq_err:
        logger.error("Critical: Failed to write to DLQ: %s", dlq_err)
        raise
