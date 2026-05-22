terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

provider "google" {
  project               = var.project_id
  user_project_override = true
  billing_project       = var.project_id
}

# Enable Service Usage API first (required to enable other APIs)
resource "google_project_service" "service_usage" {
  project            = var.project_id
  service            = "serviceusage.googleapis.com"
  disable_on_destroy = false
}

# Enable Spanner API
resource "google_project_service" "spanner" {
  depends_on         = [google_project_service.service_usage]
  project            = var.project_id
  service            = "spanner.googleapis.com"
  disable_on_destroy = false
}

# Spanner Instance Configuration
resource "google_spanner_instance" "network-graph-demo" {
  depends_on = [google_project_service.spanner]
  project                      = var.project_id
  name                         = "network-graph-demo"
  config                       = "regional-europe-southwest1"
  display_name                 = "network-graph-demo"
  processing_units             = 100
  edition                      = "ENTERPRISE"
  default_backup_schedule_type = "NONE"
}

# Spanner Database and DDL (Schema + Graph Model)
resource "google_spanner_database" "network-db" {
  project          = var.project_id
  instance         = google_spanner_instance.network-graph-demo.name
  name             = "network-db"
  database_dialect = "GOOGLE_STANDARD_SQL"

  # Table and Graph schemas
  ddl = [
    "CREATE TABLE Device (Device_ID STRING(100) NOT NULL, Device_Type STRING(100)) PRIMARY KEY(Device_ID)",
    "CREATE TABLE Inventory (Serial_Number STRING(100) NOT NULL, Part_Type STRING(100)) PRIMARY KEY(Serial_Number)",
    "CREATE TABLE Nodes (Node_ID STRING(100) NOT NULL, Location STRING(100), Risk_Score FLOAT64) PRIMARY KEY(Node_ID)",
    "CREATE TABLE RFO (RFO_ID STRING(100) NOT NULL, Severity STRING(50)) PRIMARY KEY(RFO_ID)",
    
    # Interleaved / Edge Tables
    "CREATE TABLE InventoryIssueRFO (Serial_Number STRING(100) NOT NULL, RFO_ID STRING(100) NOT NULL) PRIMARY KEY(Serial_Number, RFO_ID), INTERLEAVE IN PARENT Inventory ON DELETE NO ACTION",
    "CREATE TABLE NodeConnectsDevice (Node_ID STRING(100) NOT NULL, Device_ID STRING(100) NOT NULL) PRIMARY KEY(Node_ID, Device_ID), INTERLEAVE IN PARENT Nodes ON DELETE NO ACTION",
    "CREATE TABLE NodeHasInventory (Node_ID STRING(100) NOT NULL, Serial_Number STRING(100) NOT NULL) PRIMARY KEY(Node_ID, Serial_Number), INTERLEAVE IN PARENT Nodes ON DELETE NO ACTION",
    
    # Property Graph Definition
    <<EOT
CREATE OR REPLACE PROPERTY GRAPH NetworkTopology
  NODE TABLES(
    Device KEY(Device_ID) LABEL Device PROPERTIES(Device_ID, Device_Type),
    Inventory KEY(Serial_Number) LABEL Inventory PROPERTIES(Part_Type, Serial_Number),
    Nodes KEY(Node_ID) LABEL Nodes PROPERTIES(Location, Node_ID, Risk_Score),
    RFO KEY(RFO_ID) LABEL RFO PROPERTIES(RFO_ID, Severity)
  )
  EDGE TABLES(
    InventoryIssueRFO KEY(Serial_Number, RFO_ID) SOURCE KEY(Serial_Number) REFERENCES Inventory(Serial_Number) DESTINATION KEY(RFO_ID) REFERENCES RFO(RFO_ID) LABEL NodeComponentHasIssue PROPERTIES(RFO_ID, Serial_Number),
    NodeConnectsDevice KEY(Node_ID, Device_ID) SOURCE KEY(Node_ID) REFERENCES Nodes(Node_ID) DESTINATION KEY(Device_ID) REFERENCES Device(Device_ID) LABEL DeviceConnectedtoNode PROPERTIES(Device_ID, Node_ID),
    NodeHasInventory KEY(Node_ID, Serial_Number) SOURCE KEY(Node_ID) REFERENCES Nodes(Node_ID) DESTINATION KEY(Serial_Number) REFERENCES Inventory(Serial_Number) LABEL NodeConsistsOf PROPERTIES(Node_ID, Serial_Number)
  )
EOT
  ]
}

# Data Population via gcloud
# Terraform is an Infrastructure-as-Code tool, so inserting data natively isn't supported. 
# We use a null_resource to execute gcloud insert statements securely.
resource "null_resource" "populate_data" {
  depends_on = [google_spanner_database.network-db]

  provisioner "local-exec" {
    command = <<EOT
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO Device (Device_ID, Device_Type) VALUES ('AP-Floor1-North', 'Access Point'), ('AP-Floor2-South', 'Access Point'), ('IoT-Sensor-01', 'Gateway'), ('IoT-Sensor-02', 'Gateway'), ('IoT-Sensor-03', 'Gateway'), ('Mobile-Exec-1', 'Mobile'), ('Mobile-FieldTech-2', 'Mobile'), ('POS-Terminal-1', 'Point of Sale'), ('POS-Terminal-2', 'Point of Sale'), ('User-Laptop-Alpha', 'Workstation'), ('User-Laptop-Beta', 'Workstation'), ('User-Laptop-Gamma', 'Workstation');"
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO Inventory (Serial_Number, Part_Type) VALUES ('CPU-H1', 'Processor'), ('CPU-J2', 'Processor'), ('CPU-K3', 'Processor'), ('FAN-120MM-1', 'Cooling Fan'), ('FAN-80MM-2', 'Cooling Fan'), ('FW-APPLIANCE-X1', 'Firewall'), ('NIC-10A', 'Network Card'), ('NIC-10B', 'Network Card'), ('NIC-99X', 'Network Card'), ('PSU-400W', 'Power Supply'), ('PSU-500W', 'Power Supply'), ('RAM-DDR4-16G-1', 'Memory'), ('RAM-DDR4-16G-2', 'Memory'), ('ROUTER-20A', 'Router'), ('SSD-1TB-A', 'Storage'), ('SSD-2TB-B', 'Storage'), ('SWITCH-G48', 'Switch');"
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO Nodes (Node_ID, Location, Risk_Score) VALUES ('Srv-Amsterdam-01', 'Amsterdam', 0), ('Srv-Amsterdam-02', 'Amsterdam', 0), ('Srv-Copenhagen-01', 'Copenhagen', 0), ('Srv-Dublin-01', 'Dublin', 0), ('Srv-Dublin-02', 'Dublin', 0), ('Srv-Helsinki-01', 'Helsinki', 0), ('Srv-London-01', 'London', 0), ('Srv-Manchester-02', 'Manchester', 0), ('Srv-Oslo-01', 'Oslo', 0), ('Srv-Paris-01', 'Paris', 0), ('Srv-Paris-02', 'Paris', 0), ('Srv-Stockholm-01', 'Stockholm', 0);"
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO RFO (RFO_ID, Severity) VALUES ('CPU-Throttling', 'WARNING'), ('Configuration-Mismatch', 'WARNING'), ('Disk-Read-Error', 'WARNING'), ('Firmware-Bug-A1', 'WARNING'), ('Hardware-Failure: Port Flapping', 'CRITICAL'), ('Latency-Spike', 'WARNING'), ('Overheating', 'WARNING'), ('PSU-Failure', 'CRITICAL'), ('Packet-Loss-High', 'CRITICAL'), ('Security-Threat-Detected', 'CRITICAL');"
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO InventoryIssueRFO (Serial_Number, RFO_ID) VALUES ('CPU-K3', 'CPU-Throttling'), ('FW-APPLIANCE-X1', 'Security-Threat-Detected'), ('NIC-10A', 'Packet-Loss-High'), ('NIC-99X', 'Hardware-Failure: Port Flapping'), ('PSU-400W', 'PSU-Failure'), ('ROUTER-20A', 'Firmware-Bug-A1'), ('SSD-1TB-A', 'Disk-Read-Error'), ('SWITCH-G48', 'Latency-Spike');"
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO NodeConnectsDevice (Node_ID, Device_ID) VALUES ('Srv-Amsterdam-01', 'POS-Terminal-1'), ('Srv-Amsterdam-01', 'POS-Terminal-2'), ('Srv-Copenhagen-01', 'Mobile-FieldTech-2'), ('Srv-Dublin-01', 'AP-Floor1-North'), ('Srv-Dublin-01', 'User-Laptop-Beta'), ('Srv-Dublin-02', 'IoT-Sensor-02'), ('Srv-Helsinki-01', 'AP-Floor2-South'), ('Srv-London-01', 'User-Laptop-Alpha'), ('Srv-Manchester-02', 'User-Laptop-Alpha'), ('Srv-Oslo-01', 'Mobile-Exec-1'), ('Srv-Paris-01', 'User-Laptop-Gamma'), ('Srv-Stockholm-01', 'IoT-Sensor-03');"
gcloud spanner databases execute-sql network-db --project=${var.project_id} --instance=network-graph-demo --sql="INSERT INTO NodeHasInventory (Node_ID, Serial_Number) VALUES ('Srv-Amsterdam-01', 'RAM-DDR4-16G-1'), ('Srv-Amsterdam-01', 'SWITCH-G48'), ('Srv-Copenhagen-01', 'SSD-2TB-B'), ('Srv-Dublin-01', 'CPU-J2'), ('Srv-Dublin-01', 'NIC-10A'), ('Srv-Dublin-01', 'PSU-400W'), ('Srv-Dublin-02', 'CPU-K3'), ('Srv-Dublin-02', 'NIC-10B'), ('Srv-Helsinki-01', 'FAN-80MM-2'), ('Srv-Helsinki-01', 'RAM-DDR4-16G-2'), ('Srv-London-01', 'NIC-99X'), ('Srv-Manchester-02', 'CPU-H1'), ('Srv-Manchester-02', 'PSU-500W'), ('Srv-Oslo-01', 'FW-APPLIANCE-X1'), ('Srv-Paris-01', 'ROUTER-20A'), ('Srv-Stockholm-01', 'FAN-120MM-1'), ('Srv-Stockholm-01', 'SSD-1TB-A');"
EOT
  }
}
