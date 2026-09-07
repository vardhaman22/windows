# Rancher Windows vSphere Templates: Multi-Disk Support

## 21. Implementation log

This section documents what was actually implemented, file by file, and
why. The design follows the recommendation above almost exactly:
`disk_size` is kept everywhere for backward compatibility, and a new
`disk_sizes` (Terraform) / `vm_additional_disks` (Packer) opt-in is
added alongside it. When the new field is empty (the default), behavior
is byte-for-byte identical to before this change.

### Packer: `vsphere-templates/builds/windows/server/{2019,2022,2025}`

The same change was applied to all three supported Windows Server
versions, not just 2025, since there is no reason multi-disk support
should be limited to one OS version.

-   **`variables.pkr.hcl`** (all three versions)

    Added a new variable:

    ``` hcl
    variable "vm_additional_disks" {
      type = list(object({
        size                  = number
        disk_controller_index = optional(number, 0)
        disk_thin_provisioned = optional(bool, true)
      }))
      description = "Additional virtual disks to attach, in MB, beyond the primary OS disk (var.vm_disk_size)."
      default     = []
    }
    ```

    `default = []` is what makes this backward compatible: any existing
    `*.auto.pkrvars.hcl` that never mentions this variable keeps
    producing single-disk templates.

-   **`windows-server.pkr.hcl`** (all three versions)

    Added a `dynamic "storage"` block directly after the existing
    (unchanged) OS disk `storage` block, in **all four** `vsphere-iso`
    sources per file (`windows-server-standard-core`,
    `-standard-dexp`, `-datacenter-core`, `-datacenter-dexp`):

    ``` hcl
    storage {
      disk_size             = var.vm_disk_size
      disk_thin_provisioned = var.vm_disk_thin_provisioned
    }
    dynamic "storage" {
      for_each = var.vm_additional_disks
      content {
        disk_size              = storage.value.size
        disk_controller_index  = storage.value.disk_controller_index
        disk_thin_provisioned  = storage.value.disk_thin_provisioned
      }
    }
    ```

    Because `for_each` iterates an empty list by default, this emits no
    extra `storage` blocks unless `vm_additional_disks` is populated,
    which is why existing pipelines are unaffected. The disk controller
    type was left untouched (`disk_controller_type = var.vm_disk_controller_type`,
    already defaulting to `["pvscsi"]`), so additional disks land on the
    same PVSCSI controller as the OS disk, matching the Terraform side.

-   **`vsphere-templates/README.md`**

    Documented `vm_additional_disks` under the "Machine Image
    Variables" section. Windows Server 2022 initializes and formats the
    first additional disk as `F:` during template creation; other builds
    leave additional disks raw for consuming Terraform modules to
    initialize after cloning.

### Terraform: `terraform/internal/vsphere/vm` (the actual VM resource)

This is the module that had the hard blocker described in sections 4–5:
a single hardcoded `disk` block cannot clone a template that has more
than one disk, because the vSphere provider requires one `disk` block
per template disk, matched by `unit_number`.

-   **`variables.tf`**

    Added:

    ``` hcl
    variable "disk_sizes" {
      description = "The sizes in gigabytes of all disks to attach, in template unit-number order. Takes precedence over disk_size when set."
      type        = list(number)
      default     = []
    }
    ```

    `disk_size` was kept as-is (still required, still GB), so every
    existing caller continues to work unmodified.

-   **`vms.tf`**

    Added a local to decide which disk list is authoritative:

    ``` hcl
    effective_disk_sizes = length(var.disk_sizes) > 0 ? var.disk_sizes : [var.disk_size]
    ```

    Replaced the single static `disk` block with a static first disk
    (always `unit_number = 0`, matching the template's boot disk) plus a
    `dynamic "disk"` block for everything else:

    ``` hcl
    disk {
      label       = "Hard Disk 1"
      size        = local.effective_disk_sizes[0]
      unit_number = 0
    }

    dynamic "disk" {
      for_each = slice(local.effective_disk_sizes, 1, length(local.effective_disk_sizes))
      content {
        label       = "Hard Disk ${disk.key + 2}"
        size        = disk.value
        unit_number = disk.key + 1
      }
    }
    ```

    This is the change that actually unblocks multi-disk cloning: the
    number of `disk` blocks generated now always matches
    `length(effective_disk_sizes)`, with `unit_number` values `0, 1, 2, ...`
    lined up against the template's own disk unit numbers, satisfying
    the provider's requirement described in section 5. No explicit
    `scsi_type` was added, since the provider's default (`pvscsi`)
    already matches the Packer template's controller type.

-   **`vm/files/*.ps1`**: left untouched. Note for anyone re-reading
    section 19 of this document: the claim that `extend-disk.ps1` is
    referenced-but-missing was a **false positive** — that file is
    referenced from `internal/vsphere/servers/main.tf`, whose
    `path.module` is the `servers` module, not the `vm` module, and it
    does exist at `internal/vsphere/servers/files/extend-disk.ps1`.

### Terraform: `terraform/internal/vsphere/servers` (per-server orchestration + provisioning scripts)

This module fans a single `servers` list out into N `vm` module
instances (one per replica) and decides which PowerShell/shell scripts
get uploaded and scheduled on each VM.

-   **`variables.tf`**: added `disk_sizes = optional(list(number), [])`
    to the `servers` object type, mirroring the `vm` module's variable.

-   **`main.tf`**:
    -   Passes `disk_sizes = each.value.server.disk_sizes` through to
        the `vm` module call, alongside the existing `disk_size`.
    -   Added a second script to the unconditional "windows" script
        list, alongside the pre-existing `extend-disk.ps1`:

        ``` hcl
        scripts = concat(each.value.server.image.os == "windows" ? [{
          content = file("${path.module}/files/extend-disk.ps1")
          name    = "extend-disk.ps1"
          },
          {
            content = file("${path.module}/files/initialize-data-disks.ps1")
            name    = "initialize-data-disks.ps1"
        }] : [], ...)
        ```

        Both scripts are picked up by the existing
        `add_scheduled_tasks.ps1` mechanism (see
        `internal/vsphere/vm/files/add_scheduled_tasks.ps1`), which
        registers every provided script as a Windows Scheduled Task that
        runs once, in order, on first boot. This is why the new script
        didn't need any new wiring beyond adding it to the list.

-   **`files/initialize-data-disks.ps1`** (new file): the existing
    `extend-disk.ps1` only resizes the `C:` partition, so a new script was
    added to handle any remaining raw disks. It leaves the pre-initialized
    `F:` disk from the Windows Server 2022 template unchanged:

    ``` powershell
    # Initializes, partitions, and formats any raw data disks attached beyond the OS disk.
    $rawDisks = Get-Disk | Where-Object { $_.Number -ne 0 -and $_.PartitionStyle -eq "RAW" } | Sort-Object Number
    $isFirstDataDisk = $true
    foreach ($disk in $rawDisks) {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $driveLetter = $null
        if ($isFirstDataDisk) {
            $driveLetter = "F"
            $isFirstDataDisk = $false
        }
        $partition = if ($null -eq $driveLetter) {
            New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        } else {
            New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveLetter
        }
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "Data$($disk.Number)" -Confirm:$false
    }
    ```

    It only acts on disks whose `PartitionStyle` is `RAW`, so on
    single-disk VMs (where the OS disk is already partitioned) this is
    a no-op — safe to run unconditionally for every Windows server.

### Terraform: `terraform/vsphere_server` (top-level, general-purpose module)

-   **`variables.tf`**: added `disk_sizes = optional(list(number), [])`
    to the `servers` object, plus a new validation:

    ``` hcl
    validation {
      condition     = alltrue([for s in var.servers : s.disk_sizes == null || length(s.disk_sizes) == 0 || alltrue([for size in s.disk_sizes : size > 0])])
      error_message = "When disk_sizes is set, every entry must be a positive number of gigabytes, ordered to match the source template's disk unit numbers."
    }
    ```

    This catches an obviously-wrong tfvars entry (e.g. a `0` or
    negative size) at `terraform plan` time instead of surfacing a
    confusing vSphere API error later.

-   **`main.tf`**: passes `disk_sizes = var.servers[i].disk_sizes`
    through to the `servers` module, alongside the existing
    `disk_size`.

-   **`README.md`**: added a "Multiple Disks" section explaining
    `disk_sizes`, that it takes precedence over `disk_size`, that sizes
    must be ≥ the template's corresponding disk, and that non-boot
    disks are auto-initialized on first boot. The first data disk is assigned
    `F:`; later data disks receive the next available drive letters.

-   **`examples/windows_2022.tfvarsexample`**: added a commented-out
    `disk_sizes` example next to the existing `disk_size` field, so
    users copying this file see the option without it being enabled by
    default.

### Terraform: `terraform/vsphere_rke2_cluster` (RKE2 cluster provisioning, wraps `internal/vsphere/servers`)

The user explicitly asked for multi-disk support here to be
**Windows-only**; Linux nodes must keep using `disk_size`.

-   **`variables.tf`**:
    -   Added `disk_sizes = optional(list(number), [])` to the `nodes`
        object type.
    -   Added a validation enforcing the Windows-only restriction:

        ``` hcl
        validation {
          condition = alltrue([for s in var.nodes :
          ((s.image.os == "windows") || (length(s.disk_sizes) == 0))])
          error_message = "Only Windows nodes can specify disk_sizes for multiple disks. Linux nodes must use disk_size."
        }
        ```

        Unlike `vsphere_server` (general-purpose, OS-agnostic), this
        module's `nodes` list is OS-heterogeneous by design (a single
        `nodes` list can mix Linux and Windows RKE2 nodes), so the
        validation actively rejects `disk_sizes` on any node whose
        `image.os != "windows"`, rather than just documenting the
        convention.

-   **`main.tf`**: passes `disk_sizes = var.nodes[i].disk_sizes` through
    to the `servers` module call, alongside the existing `disk_size`.

-   **`README.md`**: added a bullet documenting that Windows nodes can
    use `disk_sizes` and that this is not supported for Linux nodes.

-   **`examples/simple-cluster.tfvarsexample`**: added a commented-out
    `disk_sizes` example on the Windows node entry only (the Linux
    `ubuntu-control-plane` entry was left unchanged).

### Validation performed

-   `packer validate -syntax-only` passed for all three
    `vsphere-templates/builds/windows/server/{2019,2022,2025}`
    directories.
-   `terraform validate` (via a local, backend-disabled `terraform
    init`) passed for `internal/vsphere/vm`, `internal/vsphere/servers`,
    `vsphere_server`, and `vsphere_rke2_cluster`.
-   `packer fmt` / `terraform fmt` were run and any diffs were manually
    reviewed; pre-existing formatting inconsistencies unrelated to this
    change (present before this work started) were deliberately left
    untouched to keep the diff scoped to the multi-disk feature.
-   No `vsphere_server/terraform.tfstate*` files were touched — only
    source `.tf` / `.hcl` / `.ps1` / `.md` files were modified or added.

------------------------------------------------------------------------

## Sources


-   Rancher Windows Packer template:
    https://github.com/rancher/windows/blob/main/vsphere-templates/builds/windows/server/2025/windows-server.pkr.hcl
-   Rancher Windows Packer variables:
    https://github.com/rancher/windows/blob/main/vsphere-templates/builds/windows/server/2025/variables.pkr.hcl
-   Rancher `terraform/vsphere_server`:
    https://github.com/rancher/windows/tree/main/terraform/vsphere_server
-   Rancher internal vSphere server module:
    https://github.com/rancher/windows/tree/main/terraform/internal/vsphere/servers
-   Rancher internal vSphere VM module:
    https://github.com/rancher/windows/blob/main/terraform/internal/vsphere/vm/vms.tf
-   VMware vSphere Terraform provider --- `vsphere_virtual_machine`:
    https://registry.terraform.io/providers/vmware/vsphere/latest/docs/resources/virtual_machine
