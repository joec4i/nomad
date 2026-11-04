# Template for the ballast and rival jobs.
# The script replaces __ID__ with the job id and __PRIORITY__ with the priority
# (job labels and priority can't be variables). -var node=<name> pins the job to one
# node; the default ".*" matches any node.
#
# Ballast: fills a node so exactly the wanted memory is left free.
# Rival: one alloc the size of the migrated alloc, registered at the same moment as
# the drain so its plan competes for the same free slot.
variable "memory" {
  type    = number
  default = 100
}

variable "node" {
  type    = string
  default = ".*"
}

job "__ID__" {
  datacenters = ["dc1"]
  type        = "service"
  priority    = __PRIORITY__

  group "filler" {
    count = 1

    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = var.node
    }

    task "sleep" {
      driver = "raw_exec"

      config {
        command = "/bin/sleep"
        args    = ["100000"]
      }

      resources {
        cpu    = 50
        memory = var.memory
      }
    }
  }
}
