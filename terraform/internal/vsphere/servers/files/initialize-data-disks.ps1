# Initializes, partitions, and formats raw data disks attached beyond the OS disk.
$rawDisks = Get-Disk | Where-Object { $_.Number -ne 0 -and $_.PartitionStyle -eq "RAW" } | Sort-Object Number
foreach ($disk in $rawDisks) {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "Data$($disk.Number)" -Confirm:$false
}
