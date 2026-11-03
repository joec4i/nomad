# The service job under test. Its update stanza (canary = 1, auto_promote = false,
# max_parallel = 1) is what makes a canary deployment wait for promotion.
# Register it once as v0, then again with a different marker to start a canary
# deployment. Driven by scripts/canary-drain-partial-plan.sh.
#
# Uses raw_exec and no Consul service, so allocs go healthy 3s after the task
# starts. resources.memory is what the scheduler and the plan applier account
# for; raw_exec does not enforce it.
variable "marker" {
  type    = string
  default = "v0"
}

variable "count" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 300
}

job "canary-drain" {
  datacenters = ["dc1"]
  type        = "service"

  update {
    canary            = 1
    auto_promote      = false
    max_parallel      = 1
    auto_revert       = false
    health_check      = "task_states"
    min_healthy_time  = "3s"
    healthy_deadline  = "2m"
    progress_deadline = "10m"
  }

  migrate {
    max_parallel     = 1
    health_check     = "task_states"
    min_healthy_time = "3s"
    healthy_deadline = "2m"
  }

  group "app" {
    count = var.count

    # Keeps the allocs (and the canary) on different nodes, so the layout is
    # predictable on 3 clients.
    spread {
      attribute = "${node.unique.name}"
    }

    task "app" {
      driver = "raw_exec"

      config {
        command = "/bin/sleep"
        args    = ["100000"]
      }

      env {
        MARKER = var.marker
      }

      resources {
        cpu    = 50
        memory = var.memory
      }
    }
  }
}
