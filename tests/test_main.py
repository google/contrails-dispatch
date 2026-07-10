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

import os
import base64
import json
import pytest
import sys
import numpy as np
from unittest.mock import MagicMock, patch

# Add the src directory to sys.path
sys.path.append(
    os.path.join(os.path.dirname(__file__), "../contrails_dispatch/flight_plan_processor")
)

# Patch Google Cloud Clients before importing main
patch('google.cloud.bigquery.Client').start()
patch('google.cloud.logging.Client').start()

# Ensure decorator returns the function
mock_ff = MagicMock()
mock_ff.cloud_event = lambda f: f
sys.modules["functions_framework"] = mock_ff

# Set environment variables required at import time
os.environ["PROJECT_ID"] = "test-project"
os.environ["BQ_DATASET_ID"] = "test-dataset"
os.environ["BQ_TABLE_ID"] = "test-table"
os.environ["BQ_DEAD_LETTER_TABLE_ID"] = "test-dlq"

import main


@pytest.fixture
def mock_env():
    os.environ["PROJECT_ID"] = "test-project"
    os.environ["BQ_DATASET_ID"] = "test-dataset"
    os.environ["BQ_TABLE_ID"] = "test-table"
    os.environ["BQ_DEAD_LETTER_TABLE_ID"] = "test-dlq"


@patch("main.google_forecast.GoogleForecast")
@patch("main.logging.getLogger")
@patch("main._write_to_dlq")
def test_process_flight_plan_success(
    mock_dlq, mock_get_logger, mock_forecast, mock_env
):
    # Mock GoogleForecast and open_metdataset
    mock_mda = MagicMock()
    def fake_interpolate(lon, lat, lvl, time, **kwargs):
        return np.ones(len(lon)) * 0.5
    mock_mda.interpolate.side_effect = fake_interpolate

    mock_mds = MagicMock()
    mock_mds.__getitem__.return_value = mock_mda
    mock_forecast.return_value.open_metdataset.return_value = mock_mds

    # Mock BigQuery insert success (no errors)
    main.bq_client.insert_rows_json.return_value = []

    # Read real test XML
    xml_path = os.path.join(os.path.dirname(__file__), "data/test_flight_plan.xml")
    with open(xml_path, "rb") as f:
        xml_content = f.read()

    # Mock Cloud Event with real XML
    encoded_xml = base64.b64encode(xml_content).decode()
    cloud_event = MagicMock()
    cloud_event.data = {"message": {"data": encoded_xml}}
    cloud_event.get.side_effect = lambda k, d=None: {
        "id": "test_id",
        "source": "//pubsub.googleapis.com/projects/p/topics/test-topic",
    }.get(k, d)

    # Call the function
    main.process_flight_plan(cloud_event)

    # Assertions
    main.bq_client.insert_rows_json.assert_called_once()
    args, _ = main.bq_client.insert_rows_json.call_args
    row = args[1][0]

    assert row["flight_commercial_number"] == "XX000"
    assert row["departure_airport_icao"] == "AAAA"
    assert row["last_updated_at"] == "2025-01-01T00:00:00+00:00"
    assert isinstance(row["total_forcing_joules"], float)
