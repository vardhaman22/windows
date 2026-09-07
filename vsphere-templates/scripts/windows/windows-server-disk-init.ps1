$ErrorActionPreference = "Stop"

# Initialize raw additional disks while building a Windows Server image.
$rawDisks = Get-Disk | Where-Object {
    $_.Number -ne 0 -and $_.PartitionStyle -eq "RAW"
} | Sort-Object Number

foreach ($disk in $rawDisks) {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "Data$($disk.Number)" -Confirm:$false
}