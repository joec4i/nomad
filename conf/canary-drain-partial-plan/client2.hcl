# Nomad client. A fixed, small memory_total_mb so free capacity is easy to make
# exact with ballast jobs; cpu_total_compute is set because CPU fingerprinting is
# unreliable in containers.
data_dir   = "/var/lib/nomad/data"
name       = "nomad-client2"
log_level  = "INFO"
bind_addr  = "0.0.0.0"
datacenter = "dc1"

client {
  enabled           = true
  cpu_total_compute = 4000
  memory_total_mb   = 1000

  server_join {
    retry_join = ["nomad-server:4647"]
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}
