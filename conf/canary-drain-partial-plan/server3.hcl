# One of 3 Nomad servers (bootstrap_expect = 3).
# DEBUG so the reconcile, plan and worker lines are visible. Several servers because
# the leader pauses 3/4 of its scheduler workers (so with a 2 CPU Docker VM it has
# one active worker, and Nomad caps num_schedulers at the VM's CPU count); the
# followers' workers all stay active and pull evals from the leader's broker, so
# evals of different jobs really run in parallel.
data_dir   = "/var/lib/nomad/data"
name       = "nomad-server3"
log_level  = "DEBUG"
bind_addr  = "0.0.0.0"
datacenter = "dc1"

server {
  enabled          = true
  bootstrap_expect = 3
  num_schedulers   = 2

  server_join {
    retry_join = ["nomad-server:4648", "nomad-server2:4648", "nomad-server3:4648"]
  }
}
