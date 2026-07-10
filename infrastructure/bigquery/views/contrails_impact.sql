-- Copyright 2026 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

SELECT
  flight_commercial_number,
  departure_airport_icao,
  arrival_airport_icao,
  aircraft_type,
  aircraft_registration,
  origin_date,
  departure_planned_at,
  arrival_planned_at,
  last_updated_at,
  total_forcing_joules,
  flight_plan_json,
  bq_last_update_timestamp
FROM `${source_table}`
QUALIFY
  ROW_NUMBER()
    OVER (
      PARTITION BY
        flight_commercial_number, departure_airport_icao, arrival_airport_icao, origin_date
      ORDER BY last_updated_at DESC, bq_last_update_timestamp DESC
    )
  = 1
ORDER BY last_updated_at DESC;
