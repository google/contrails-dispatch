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
import sys
from google.cloud import pubsub_v1

# Use environment variable or manually set Project id.
project_id = os.environ.get("GCP_PROJECT_ID", "")
if not project_id:
    print("Error: GCP_PROJECT_ID environment variable is not set.", file=sys.stderr)
    print("Usage: GCP_PROJECT_ID=your-project-id [PUBSUB_TOPIC_NAME=your-topic] python3 tests/publish_test.py", file=sys.stderr)
    sys.exit(1)
topic_id = os.environ.get("PUBSUB_TOPIC_NAME", "flight-plan-xml-topic")
file_path = "tests/data/test_flight_plan.xml"

publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(project_id, topic_id)

with open(file_path, "rb") as f:
    data = f.read()

future = publisher.publish(topic_path, data)
print(f"Published message ID: {future.result()}")
